"""Phase 11 — Active perception via intention-attention coupling.

Per docs/perception_spec.md §5.6 and docs/perception_implementation_plan.md
Phase 11: L3's `Goal:` field drives which concept neurons activate as
"intention context". Those neurons, via learned I→S weights, amplify the
propagation of goal-relevant sense neurons — attention becomes active
(goal-shaped) rather than passive (purely bottom-up).

This module is the Python side of the coupling: embed the goal, find the
top-K nearest concept neurons in embedding space (bootstrap concepts ARE
quality neurons; active appraisals carry drifted embeddings), return the
list of neuron IDs to activate on the GDScript side.

Authored surface is minimal:
- Bootstrap concepts (14 seeds) live in `embedding_bridge.bootstrap_concepts`.
  Their names match q_{concept} quality neuron IDs 1:1.
- Appraisal embeddings come from the existing AppraisalEmbeddingManager.
- Top-K cutoff is `neurogenesis_thresholds.intention_top_k_concepts` (Tier-2).

No new decision rules beyond "nearest concept by cosine" — which is the
same mechanism Phase 5's identity decode uses. The goal-to-concept
mapping is embedding-driven, not a fixed table.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Iterable

import numpy as np

log = logging.getLogger("intention_attention")


@dataclass
class IntentionContext:
    """Result of select_intention_context. Carries enough data that trace
    can record which neurons the goal activated and why."""
    goal_text: str
    neuron_ids: list[str] = field(default_factory=list)
    scores: list[float] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)  # "bootstrap" | "appraisal"


class IntentionAttention:
    """Per-NPC-agnostic selector. Caches concept-name embeddings so the
    hot-path cost is one embed() per goal + cosine against the cache."""

    def __init__(self, source, appraisal_manager,
                 bootstrap_concepts: list[str], top_k: int):
        self._source = source
        self._manager = appraisal_manager
        self._bootstrap_concepts = list(bootstrap_concepts)
        self._top_k = int(top_k)
        self._concept_cache: dict[str, np.ndarray] = {}

    def _ensure_concept_embedding(self, concept: str) -> np.ndarray:
        if concept in self._concept_cache:
            return self._concept_cache[concept]
        v = self._source.embed(concept)
        n = np.linalg.norm(v)
        if n < 1e-9:
            v = np.zeros_like(v)
        else:
            v = v / n
        self._concept_cache[concept] = v.astype(np.float32)
        return self._concept_cache[concept]

    def select_intention_context(
        self,
        npc: str,
        goal_text: str,
        active_appraisal_ids: Iterable[str] | None = None,
    ) -> IntentionContext:
        """Return the top-K nearest concept neurons for `goal_text`.

        - Ranks both bootstrap-concept quality neurons (q_{concept}) and
          currently-active appraisal neurons (drifted embeddings).
        - Discards negative-cosine hits (anti-correlated concepts aren't
          intention context — they're the opposite of what the being wants).
        - Returns neuron IDs ready to pulse on the GDScript side.
        """
        ctx = IntentionContext(goal_text=goal_text or "")
        if not goal_text:
            return ctx

        try:
            goal = self._source.embed(goal_text)
        except Exception as e:
            log.warning("intention embed failed for %s: %s", goal_text[:40], e)
            return ctx
        gn = np.linalg.norm(goal)
        if gn < 1e-9:
            return ctx
        goal = (goal / gn).astype(np.float32)

        scored: list[tuple[float, str, str]] = []  # (score, neuron_id, source)

        # Bootstrap concepts → q_{concept} quality neurons.
        for concept in self._bootstrap_concepts:
            v = self._ensure_concept_embedding(concept)
            if float(np.linalg.norm(v)) < 1e-9:
                continue
            s = float(np.dot(goal, v))
            if s > 0.0:
                scored.append((s, f"q_{concept}", "bootstrap"))

        # Active appraisals (identity + quality-constellation) → their
        # drifted embeddings. The appraisal ID is already the neuron ID on
        # the GDScript side.
        if self._manager is not None and active_appraisal_ids:
            with self._manager._lock:  # noqa: SLF001 — same process
                states = self._manager._states.get(npc, {})  # noqa: SLF001
                for nid in active_appraisal_ids:
                    st = states.get(str(nid))
                    if st is None:
                        continue
                    v = st.embedding
                    s = float(np.dot(goal, v))
                    if s > 0.0:
                        scored.append((s, str(nid), "appraisal"))

        scored.sort(key=lambda x: -x[0])
        top = scored[: self._top_k]
        ctx.neuron_ids = [nid for (_, nid, _) in top]
        ctx.scores = [round(float(s), 4) for (s, _, _) in top]
        ctx.sources = [src for (_, _, src) in top]
        return ctx
