"""Propagation-weight top-K percept ranking — Phase 6.

Per docs/perception_spec.md §5.3 and docs/perception_implementation_plan.md
Phase 6: "The being pays attention to percept X proportionally to the outgoing
propagation weight of sense_X. High propagation = lots of downstream
influence = 'salient.'" There is no separate salience function. The weights
live in the Hebbian graph and emerge from reward-gated learning.

Responsibilities:
- Merge visible + visible_objects into one flat list of percept candidates.
- Score each by `perception_salience[entity_id]` (from the snapshot, computed
  GDScript-side from the Hebbian graph).
- Select the top K (K from `capacity.prompt_top_k_percepts`) with a stable,
  NON-AUTHORED tiebreak so all-zero weights (cold-start) don't produce
  entity-vs-object bias.
- Partition the top-K back into visible/visible_objects so the existing
  two-block prompt format can consume them (Phase 7 will collapse those blocks
  into a single flat `You see:` list).

This module adds **zero new tuning constants**. Every score it reads is
Hebbian-learned. The tiebreak is input-order-preserving — the substrate's
own registry order, not an authored salience rule.

Returns a PerceptRanking dataclass with:
- `visible`: subset of input visible, top-K members, ranked by score desc
- `visible_objects`: subset of input visible_objects, top-K members
- `weights`: ordered list of top-K scores (for F6 entropy computation)
- `total_considered`: len(visible) + len(visible_objects)
- `fallback`: True when every score was effectively zero (cold-start —
  ranking collapses to input order); reported so diagnostics can see it.

The total cap is K across both categories combined, matching the spec's
"Entity vs. object is not categorically distinguished" (§6.3-6.4). If K=8
and there are 10 entities + 2 objects, the entities may take all 8 slots.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class PerceptRanking:
    visible: list[dict]
    visible_objects: list[dict]
    heard: list[dict] = field(default_factory=list)
    weights: list[float] = field(default_factory=list)
    total_considered: int = 0
    fallback: bool = False


def rank_percepts(
    visible: list[dict],
    visible_objects: list[dict],
    perception_salience: dict[str, float],
    top_k: int,
    heard: list[dict] | None = None,
) -> PerceptRanking:
    """Select the top-K percepts across all three lists by propagation weight.

    Phase 9 brings `heard` into the unified rank: heard entries with an
    `emitter_eid` contribute `sense_heard_{eid}` + `sense_visible_{eid}`
    outgoing weight to a combined propagation score. Entries without eid
    (ambient sounds — wind, generic impact) score 0 and fall through to the
    stable tiebreak.

    Tiebreak: within equal-score groups, preserve the combined input order
    (visible first, then visible_objects, then heard, each in snapshot
    order). Cold-start (all zero scores) degrades gracefully to input order.
    """
    heard = list(heard or [])
    if top_k <= 0:
        return PerceptRanking(
            visible=[], visible_objects=[], heard=[],
            weights=[], total_considered=len(visible) + len(visible_objects) + len(heard),
            fallback=True,
        )

    candidates: list[tuple[int, str, dict, float]] = []
    for i, v in enumerate(visible):
        eid = str(v.get("id", ""))
        score = float(perception_salience.get(eid, 0.0)) if eid else 0.0
        candidates.append((i, "visible", v, score))
    offset = len(visible)
    for j, v in enumerate(visible_objects):
        eid = str(v.get("id", ""))
        score = float(perception_salience.get(eid, 0.0)) if eid else 0.0
        candidates.append((offset + j, "objects", v, score))
    offset += len(visible_objects)
    for k, h in enumerate(heard):
        eid = str(h.get("emitter_eid", ""))
        score = float(perception_salience.get(eid, 0.0)) if eid else 0.0
        candidates.append((offset + k, "heard", h, score))

    total = len(candidates)
    max_score = max((c[3] for c in candidates), default=0.0)
    fallback = max_score <= 1e-12

    candidates.sort(key=lambda c: (-c[3], c[0]))
    top = candidates[:top_k]

    ranked_visible: list[dict] = []
    ranked_objects: list[dict] = []
    ranked_heard: list[dict] = []
    weights: list[float] = []
    for (_orig_i, source, percept, score) in top:
        weights.append(score)
        if source == "visible":
            ranked_visible.append(percept)
        elif source == "objects":
            ranked_objects.append(percept)
        else:
            ranked_heard.append(percept)

    return PerceptRanking(
        visible=ranked_visible,
        visible_objects=ranked_objects,
        heard=ranked_heard,
        weights=weights,
        total_considered=total,
        fallback=fallback,
    )


def attention_entropy(weights: list[float]) -> float:
    """Normalized Shannon entropy (natural log) over the top-K propagation
    weights. Per plan F6: `H = -Σ p_i log p_i` after softmax-style normalize.

    Returns 0.0 if all weights are zero/negative (degenerate — cold-start).
    When all weights equal (maximally undifferentiated attention), H == log(K);
    when one weight dominates (tunnel vision), H → 0.

    The plan's gate is: rolling 10-min mean ≥ `factor * log(K)` with factor
    seeded at 0.6. That is: the being must spread attention across at least
    ~exp(0.6·log(K)) = K^0.6 percepts on average (e.g. K=8 → ≥3.5 percepts).
    """
    import math

    positives = [float(w) for w in weights if w > 0]
    if len(positives) < 2:
        return 0.0
    total = sum(positives)
    if total <= 1e-12:
        return 0.0
    h = 0.0
    for w in positives:
        p = w / total
        h -= p * math.log(p)
    return h


def h_floor(top_k: int, factor: float) -> float:
    """F6 H_MIN = factor * log(K). Zero for K≤1."""
    import math

    if top_k <= 1:
        return 0.0
    return float(factor) * math.log(top_k)
