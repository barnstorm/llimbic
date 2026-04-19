"""Phase 7 — Flat Percept rendering per docs/perception_spec.md §6.3-6.4.

Replaces the two-block "visible entities" / "visible objects" scaffolding with
a single `You see:` list whose ordering is emergent top-K propagation-weight
salience (Phase 6) and whose inline tokens come from decoded identity-appraisal
embeddings (Phase 5). Entity vs. object is not categorically distinguished —
"a brick oven and a person both render as entities; their inline tokens
differentiate them via appraisal decoding."

This module intentionally adds zero new structure or authored taxonomy. Every
decision it makes (ordering, token selection, render shape) is driven by the
substrate's own emergent state:
- Ordering: Phase 6 ranking already happened in NPCState.build_thought_context.
- Inline tokens: Phase 5 identity-appraisal decoded tokens in context.
- Kind-agnostic: the renderer does not look at `type`/`category` fields.

Heard percepts retain the spec §6.4 rendering of "unbound_source, direction:
text" and still use the input order (no sense_heard_* substrate exists until
Phase 9; ranking heard by propagation weight would be authoring).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class Percept:
    """One rendered line of the `You see:` block. Kept as a record so trace
    and prompt can share one source of truth."""
    name: str
    direction_text: str
    distance_tiles: float
    inline_tokens: list[str]
    speech: str
    kind: str  # "entity" or "object" — recorded for trace only, NOT for rendering


def _render_direction(percept: dict) -> str:
    """Spec §6.4 direction_text. Uses the (distance, direction) fields already
    on the snapshot without reformatting them as prose; the decoded tokens
    carry meaning, the prompt carries facts."""
    direction = percept.get("direction", "")
    distance = percept.get("distance", 0)
    try:
        d = f"{float(distance):.0f} tiles"
    except (TypeError, ValueError):
        d = "unknown distance"
    if direction:
        return f"{d} {direction}"
    return d


def _inline_tokens_for(
    eid: str,
    identity_decoded: dict[str, list[str]],
    temporal_active: dict[str, dict[str, float]] | None = None,
    max_tokens: int = 3,
) -> list[str]:
    """Decoded tokens attached to this entity on the prompt line. Phase 5
    supplies identity-appraisal decoded tokens; Phase 10 prepends temporal-
    texture tags ("lingering", "approaching_fast") for any q_{kind}_{eid}
    firing above the active floor. Spec §5.5: "decoded tokens reflect
    temporal character" — the tag names themselves ARE the decoded tokens
    for temporal compounds, same mechanism as Phase 4's q_*able.

    Temporal tokens lead identity decode because they describe what the
    entity is DOING right now (time-urgent) while identity decode describes
    who they ARE (persistent). The combined list is capped at max_tokens.
    """
    tokens: list[str] = []
    temporal_active = temporal_active or {}
    temporal_entry = temporal_active.get(eid) or {}
    # Deterministic order inside temporal entry so traces are reproducible.
    for kind in sorted(temporal_entry.keys()):
        tokens.append(str(kind))
    for t in (identity_decoded.get(eid) or []):
        if t not in tokens:
            tokens.append(str(t))
    return tokens[:max_tokens]


def build_percepts(context: dict) -> list[Percept]:
    """Assemble the flat Percept list for one thought cycle. Consumes the
    pre-ranked context from Phase 6's build_thought_context (visible + objects
    already top-K by propagation weight), Phase 5 identity-appraisal decoded
    tokens, and Phase 10 temporal-texture activations.
    """
    identity_decoded = dict(context.get("identity_appraisal_decoded") or {})
    temporal_active = dict((context.get("temporal") or {}).get("active") or {})

    percepts: list[Percept] = []
    for v in context.get("visible", []) or []:
        eid = str(v.get("id", ""))
        percepts.append(Percept(
            name=str(v.get("name", "someone")),
            direction_text=_render_direction(v),
            distance_tiles=float(v.get("distance", 0.0) or 0.0),
            inline_tokens=_inline_tokens_for(eid, identity_decoded, temporal_active),
            speech=str(v.get("speech", "") or ""),
            kind="entity",
        ))
    for v in context.get("visible_objects", []) or []:
        eid = str(v.get("id", ""))
        percepts.append(Percept(
            name=str(v.get("name", "something")),
            direction_text=_render_direction(v),
            distance_tiles=float(v.get("distance", 0.0) or 0.0),
            inline_tokens=_inline_tokens_for(eid, identity_decoded, temporal_active),
            speech="",
            kind="object",
        ))
    return percepts


def render_see_block(percepts: list[Percept]) -> str:
    """Spec §6.4 You see: block. Entity vs object rendered identically.

    Shape:
      You see:
        - {name}, {direction_text}[; feels: {tok}, {tok}, {tok}][; "{speech}"]
        - ...
    """
    if not percepts:
        return "You see:\n  - nothing."
    lines = ["You see:"]
    for p in percepts:
        parts = [f"{p.name}, {p.direction_text}"]
        if p.inline_tokens:
            parts.append("feels: " + ", ".join(p.inline_tokens))
        if p.speech:
            parts.append(f"\"{p.speech}\"")
        lines.append("  - " + "; ".join(parts))
    return "\n".join(lines)


def render_hear_block(heard: list[dict]) -> str:
    """Spec §6.4 You hear: block. Phase 9: heard percepts are now pre-ranked
    in the same top-K pass as visible/objects, keyed on emitter_eid and
    scored by sense_heard_{eid} + sense_visible_{eid} outgoing-weight sum.
    The 3-cap from Phase 6's deferral period is gone — what's in this list
    is what the top-K ranker picked for the "heard" modality this tick."""
    if not heard:
        return "You hear:\n  - silence"
    lines = ["You hear:"]
    for h in heard:
        src = str(h.get("source", "unknown"))
        text = str(h.get("text", ""))
        dist = h.get("distance", 0)
        try:
            d = f"{float(dist):.0f} tiles {h.get('direction', 'away')}"
        except (TypeError, ValueError):
            d = h.get("direction", "away")
        if text:
            lines.append(f"  - {src}, {d}: \"{text}\"")
        else:
            lines.append(f"  - {src}, {d}: (indistinct)")
    return "\n".join(lines)


def render(context: dict) -> tuple[str, list[Percept]]:
    """Top-level: build percepts + render both blocks. Returns (text, percepts)
    so callers can paste the text into the prompt and record the Percept list
    in the trace."""
    percepts = build_percepts(context)
    see = render_see_block(percepts)
    hear = render_hear_block(context.get("heard", []) or [])
    return f"{see}\n{hear}", percepts
