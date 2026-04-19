"""AppraisalEmbeddingManager — per-NPC appraisal-neuron embedding state.

Phase 0 of docs/perception_implementation_plan.md, spec §3.5.

Responsibilities:
- Initialize an appraisal embedding from a weighted seed-concept mean (called
  by the GDScript Hebbian network when a new appraisal neuron spawns).
- Drift the embedding toward generated thought vectors (cortical feedback).
- Apply slow gravity back toward the birth embedding (slow forgetting).
- Decode an embedding to nearest tokens for prompt injection / trace logging.
- Persist long-standing neurons to disk; load on session start (spec §3.7).
- Merge neurons across entity_id changes (per data/entity_id_protocol.md, F9).

The token decode matrix is loaded once from data/token_embeddings_layer0.safetensors
(produced by tools/extract_token_embeddings.py). Decode rows are unit-normalized;
cosine similarity = dot product.

All vectors are float32, unit-normalized, shape (hidden_dim,). The hidden_dim is
inferred from the EmbeddingSource and asserted equal to the decode matrix's dim.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

import numpy as np
import safetensors.torch
import torch

from embedding_source import EmbeddingSource

log = logging.getLogger("appraisal_embeddings")


@dataclass
class AppraisalState:
    neuron_id: str
    embedding: np.ndarray              # current, unit-norm
    birth_embedding: np.ndarray        # where it started
    drift_count: int = 0               # cycles that fed cortical feedback
    last_decoded_tokens: list[str] | None = None
    last_decoded_at: float = 0.0
    seed_concepts: dict[str, float] = field(default_factory=dict)


class AppraisalEmbeddingManager:
    def __init__(
        self,
        source: EmbeddingSource,
        token_decode_path: str | Path,
        tokenizer=None,
        drift_rate: float = 0.01,
        gravity_rate: float = 0.001,
        decode_top_k: int = 3,
        persist_drift_threshold: int = 10,
    ):
        self._source = source
        self._drift_rate = drift_rate
        self._gravity_rate = gravity_rate
        self._decode_top_k = decode_top_k
        self._persist_drift_threshold = persist_drift_threshold
        self._tokenizer = tokenizer
        self._lock = threading.Lock()
        self._states: dict[str, dict[str, AppraisalState]] = {}

        self._token_ids, self._token_decode_matrix = self._load_decode_matrix(token_decode_path)
        if self._token_decode_matrix.shape[1] != source.hidden_dim:
            raise ValueError(
                f"Decode matrix hidden_dim {self._token_decode_matrix.shape[1]} "
                f"!= source hidden_dim {source.hidden_dim}. "
                "Re-extract token embeddings against the current model."
            )
        log.info(
            "AppraisalEmbeddingManager: loaded decode matrix shape=%s from %s",
            self._token_decode_matrix.shape, token_decode_path,
        )

    # --- Persistence ----------------------------------------------------------

    def initialize(self, npc: str, neuron_id: str, seed_concepts: dict[str, float]) -> None:
        """Initialize an appraisal embedding from a weighted mean of seed-concept embeddings.

        seed_concepts: e.g. {"tight": 0.8, "pounding": 0.7, "prickling": 0.6}
        Empty / all-zero-weight seed → random unit vector (still functional, just
        starts in a meaningless place; cortical feedback will move it).
        """
        emb = self._compute_seed_embedding(seed_concepts)
        with self._lock:
            self._states.setdefault(npc, {})[neuron_id] = AppraisalState(
                neuron_id=neuron_id,
                embedding=emb,
                birth_embedding=emb.copy(),
                drift_count=0,
                seed_concepts=dict(seed_concepts),
            )

    def initialize_from_thoughts(
        self,
        npc: str,
        neuron_id: str,
        thought_embeddings: list[np.ndarray],
        fallback_seed_concepts: dict[str, float] | None = None,
    ) -> None:
        """Initialize an identity-appraisal embedding from accumulated thought
        vectors (Phase 5 of perception_implementation_plan.md).

        Initial embedding = unit-normalized mean of the provided thought
        embeddings. If the thought list is empty or all zero, falls back to
        weighted seed-concept mean (same mechanism as `initialize`); if that
        too is empty, a random unit vector (the existing final fallback).

        In normal operation the tracker only emits a spawn request when its
        deque reaches encounter_threshold, so the fallback branches are
        defensive — they keep the substrate from crashing if something
        upstream produced a sparse spawn.
        """
        emb = self._mean_embedding(thought_embeddings)
        if emb is None:
            emb = self._compute_seed_embedding(fallback_seed_concepts or {})
        with self._lock:
            self._states.setdefault(npc, {})[neuron_id] = AppraisalState(
                neuron_id=neuron_id,
                embedding=emb,
                birth_embedding=emb.copy(),
                drift_count=0,
                seed_concepts=dict(fallback_seed_concepts or {}),
            )

    def _mean_embedding(self, embs: list[np.ndarray]) -> np.ndarray | None:
        """Unit-norm mean of a list of vectors. Returns None if the list is
        empty or the resulting mean is effectively zero."""
        if not embs:
            return None
        stack = np.stack([np.asarray(e, dtype=np.float32) for e in embs], axis=0)
        if stack.shape[1] != self._source.hidden_dim:
            return None
        mean = stack.mean(axis=0)
        n = float(np.linalg.norm(mean))
        if n < 1e-9:
            return None
        return (mean / n).astype(np.float32, copy=False)

    def _compute_seed_embedding(self, seed_concepts: dict[str, float]) -> np.ndarray:
        vectors: list[np.ndarray] = []
        weights: list[float] = []
        for concept, w in seed_concepts.items():
            if w <= 0 or not concept:
                continue
            v = self._source.embed(concept)
            if np.linalg.norm(v) < 1e-9:
                continue
            vectors.append(v)
            weights.append(float(w))
        if not vectors:
            v = np.random.randn(self._source.hidden_dim).astype(np.float32)
            return v / (np.linalg.norm(v) + 1e-9)
        ws = np.asarray(weights, dtype=np.float32)
        ws /= ws.sum()
        emb = np.zeros(self._source.hidden_dim, dtype=np.float32)
        for w, v in zip(ws, vectors):
            emb += w * v
        emb /= np.linalg.norm(emb) + 1e-9
        return emb

    def has_neuron(self, npc: str, neuron_id: str) -> bool:
        with self._lock:
            return neuron_id in self._states.get(npc, {})

    def get_drift_counts(self, npc: str) -> dict[str, int]:
        """Phase 8 F5 — per-neuron drift_count snapshot for the NPC. Used by
        the maturity classifier and the v3 training-data generator: a being's
        `mean_drift_count_per_appraisal` must meet `training_maturity.
        min_mean_drift_per_appraisal` before its thoughts are harvest-eligible.
        """
        with self._lock:
            return {
                nid: int(st.drift_count)
                for nid, st in self._states.get(npc, {}).items()
            }

    def remove_neuron(self, npc: str, neuron_id: str) -> None:
        with self._lock:
            self._states.get(npc, {}).pop(neuron_id, None)

    # --- Drift ----------------------------------------------------------------

    def drift(
        self,
        npc: str,
        neuron_id: str,
        activation: float,
        thought_embedding: np.ndarray,
    ) -> None:
        """Pull the appraisal embedding toward a thought vector + gravity to birth."""
        with self._lock:
            st = self._states.get(npc, {}).get(neuron_id)
            if st is None:
                return
            r = self._drift_rate * (max(0.0, min(100.0, activation)) / 100.0)
            new_emb = (1.0 - r) * st.embedding + r * thought_embedding
            new_emb = (1.0 - self._gravity_rate) * new_emb + self._gravity_rate * st.birth_embedding
            n = np.linalg.norm(new_emb)
            if n < 1e-9:
                return
            st.embedding = (new_emb / n).astype(np.float32, copy=False)
            st.drift_count += 1
            st.last_decoded_tokens = None  # invalidate decode cache

    # --- Decode ---------------------------------------------------------------

    def decode(self, npc: str, neuron_id: str, top_k: int | None = None) -> list[str]:
        """Decode an appraisal embedding to its top-K nearest tokens by cosine."""
        k = top_k if top_k is not None else self._decode_top_k
        with self._lock:
            st = self._states.get(npc, {}).get(neuron_id)
            if st is None:
                return []
            if st.last_decoded_tokens is not None and len(st.last_decoded_tokens) >= k:
                return st.last_decoded_tokens[:k]
            sims = self._token_decode_matrix @ st.embedding  # [N]
            top_idx = np.argpartition(-sims, k * 4 if k * 4 < sims.size else sims.size - 1)[: k * 4]
            top_idx = top_idx[np.argsort(-sims[top_idx])]
            tokens: list[str] = []
            for idx in top_idx:
                tid = int(self._token_ids[idx])
                if self._tokenizer is not None:
                    tok = self._tokenizer.decode([tid]).strip()
                else:
                    tok = str(tid)
                if len(tok) > 1 and any(c.isalpha() for c in tok):
                    tokens.append(tok)
                if len(tokens) >= k:
                    break
            st.last_decoded_tokens = tokens
            st.last_decoded_at = time.time()
            return tokens

    def get_active_decoded(
        self,
        npc: str,
        active_appraisals: dict[str, float],
        top_k_per_neuron: int | None = None,
    ) -> dict[str, list[str]]:
        """Decode every currently-active appraisal. {neuron_id: [tokens]}."""
        out: dict[str, list[str]] = {}
        for nid in active_appraisals.keys():
            out[nid] = self.decode(npc, nid, top_k=top_k_per_neuron)
        return out

    # --- Persistence ----------------------------------------------------------

    def persist(self, npc: str, path: str | Path) -> None:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with self._lock:
            states = self._states.get(npc, {})
            data = {
                "version": 1,
                "hidden_dim": self._source.hidden_dim,
                "neurons": {
                    nid: {
                        "embedding": st.embedding.tolist(),
                        "birth_embedding": st.birth_embedding.tolist(),
                        "drift_count": st.drift_count,
                        "seed_concepts": st.seed_concepts,
                    }
                    for nid, st in states.items()
                    if st.drift_count >= self._persist_drift_threshold
                },
            }
        with path.open("w") as f:
            json.dump(data, f)
        log.info("persist(%s) → %d neurons → %s", npc, len(data["neurons"]), path)

    def load(self, npc: str, path: str | Path) -> int:
        """Load persisted appraisals for an NPC. Returns count loaded (0 if missing)."""
        path = Path(path)
        if not path.exists():
            return 0
        with path.open() as f:
            data = json.load(f)
        if data.get("hidden_dim") != self._source.hidden_dim:
            log.warning(
                "load(%s) skipped: persisted hidden_dim=%s != current=%s",
                npc, data.get("hidden_dim"), self._source.hidden_dim,
            )
            return 0
        loaded = 0
        with self._lock:
            self._states.setdefault(npc, {})
            for nid, d in data.get("neurons", {}).items():
                emb = np.asarray(d["embedding"], dtype=np.float32)
                birth = np.asarray(d["birth_embedding"], dtype=np.float32)
                if emb.shape != (self._source.hidden_dim,):
                    continue
                self._states[npc][nid] = AppraisalState(
                    neuron_id=nid,
                    embedding=emb,
                    birth_embedding=birth,
                    drift_count=int(d.get("drift_count", 0)),
                    seed_concepts=d.get("seed_concepts", {}),
                )
                loaded += 1
        log.info("load(%s) ← %d neurons ← %s", npc, loaded, path)
        return loaded

    # --- Entity-id merge protocol (F9, data/entity_id_protocol.md) -----------

    def merge_entity_ids(self, npc: str, canonical_id: str, deprecated_id: str) -> bool:
        """Merge an appraisal neuron's drift state into the canonical neuron.

        Used when stranger-to-named binding triggers reconciliation. The merged
        embedding is the drift-count-weighted mean; canonical's birth wins.
        Returns True if a merge occurred.
        """
        with self._lock:
            states = self._states.get(npc, {})
            dep = states.pop(deprecated_id, None)
            if dep is None:
                return False
            can = states.get(canonical_id)
            if can is None:
                # No canonical exists yet → just rename.
                dep.neuron_id = canonical_id
                states[canonical_id] = dep
                return True
            total = max(1, can.drift_count + dep.drift_count)
            new_emb = (
                (can.drift_count / total) * can.embedding
                + (dep.drift_count / total) * dep.embedding
            )
            n = np.linalg.norm(new_emb)
            if n > 1e-9:
                can.embedding = (new_emb / n).astype(np.float32, copy=False)
            can.drift_count += dep.drift_count
            can.last_decoded_tokens = None
            return True

    # --- Internal ------------------------------------------------------------

    def _load_decode_matrix(self, path: str | Path) -> tuple[np.ndarray, np.ndarray]:
        path = Path(path)
        if not path.exists():
            raise FileNotFoundError(
                f"Token decode matrix missing: {path}. "
                "Run: python tools/extract_token_embeddings.py"
            )
        tensors = safetensors.torch.load_file(str(path))
        token_ids = tensors["token_ids"].numpy().astype(np.int64)
        embeddings = tensors["embeddings"].to(torch.float32).numpy()
        # Re-normalize defensively (saved as fp16; small drift on round-trip).
        norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
        norms = np.where(norms < 1e-9, 1.0, norms)
        embeddings = embeddings / norms
        return token_ids, embeddings.astype(np.float32, copy=False)
