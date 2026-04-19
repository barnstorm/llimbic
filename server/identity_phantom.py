"""Phase 7 §7.2 — Somatic phantom activation driven by identity-appraisal
decoded tokens.

Per docs/perception_spec.md §7.2: "Remove uniform phantom activation. Replace
with appr_identity_{entity_id} activation driving somatic nudges based on
the decoded-token profile — high-threat-decode entities nudge prickling;
high-warmth-decode nudge warmth. This moves phantom activation from
authored threat-memory lookup to emergent appraisal-decoded state."

The mechanism is substrate-native and has zero authored valence rules. We do
NOT say "if decoded contains 'prickling' then nudge q_prickling" — that would
be another pile of fixed mapping. Instead, we observe that the embedding
decode vocabulary IS the quality-neuron vocabulary (both come from Tier-2
`bootstrap_concepts`), so the decoded tokens naturally name which quality
neurons to nudge. "threat" is not mapped onto qualities by hand — it's
already IN the embedding space alongside "prickling" and "tight", and when
an identity-appraisal drifts toward threat-semantic thoughts, its decoded
top-k includes those tokens, which then directly name `q_{tok}` neurons to
nudge.

Returns a list of `nudge_quality` push commands the client applies in the
Hebbian graph during the next brain tick.
"""

from __future__ import annotations

from typing import Iterable


def build_phantom_nudges(
    identity_decoded: dict[str, list[str]],
    active_identity_activations: dict[str, float],
    visible_eids: Iterable[str],
    *,
    activation_floor: float = 30.0,
    nudge_strength: float = 4.0,
) -> list[dict]:
    """Compute phantom-quality nudges from the identity-appraisals currently
    active for visible entities.

    - For each visible eid whose `appr_identity_{eid}` is active (activation
      >= activation_floor), read its decoded tokens (Phase 5 trace field).
    - For each decoded token T, emit a nudge for the quality neuron named
      `q_{T}`. The client's Hebbian graph has exactly the bootstrap_concepts
      as named q_* neurons (`q_tight`, `q_warm`, `q_prickling`, etc.), so
      the names match without a mapping.
    - Strength = nudge_strength × (activation / 100) × (1 / rank). First
      decoded token nudges full strength; second at half; third at third.
      This mirrors how the existing memory-driven phantom path weighted
      by threat magnitude, but the magnitude is now appraisal-activation
      (not hand-authored threat level).

    Returns push commands in the form {"cmd": "nudge_quality", "quality_id":
    "q_...", "amount": float}. Deduplicates across multiple appraisals by
    summing amounts per quality — a being with several identity-appraisals
    all decoding to "tight" gets a stronger tight-nudge.
    """
    accumulated: dict[str, float] = {}
    for eid in visible_eids:
        if not eid:
            continue
        nid = f"appr_identity_{eid}"
        act = float(active_identity_activations.get(nid, 0.0))
        if act < activation_floor:
            continue
        tokens = identity_decoded.get(eid) or []
        for rank, tok in enumerate(tokens[:3], start=1):
            if not tok:
                continue
            quality_id = f"q_{tok}"
            amount = nudge_strength * (act / 100.0) * (1.0 / rank)
            accumulated[quality_id] = accumulated.get(quality_id, 0.0) + amount

    cmds: list[dict] = []
    for qid, amt in accumulated.items():
        cmds.append({"cmd": "nudge_quality", "quality_id": qid, "amount": float(amt)})
    return cmds
