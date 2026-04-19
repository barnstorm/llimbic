"""Phase 8 §15.2-style synthetic scenario generator.

Per docs/perception_implementation_plan.md Phase 8:
"Synthetic scenario generation (§15.2-style) is weighted 2:1 vs. organic
replay to ensure verb-coverage targets are met without overfitting to
whatever the cold-start beings happened to do."

This module produces scene CONFIGURATIONS (not completions). A configuration
is a minimal trace-compatible `context` dict — entity at distance D, object
at distance E, reward_context R, etc. The mature being's response to the
configuration is generated downstream by the training-data generator
(which pipes the config through the Phase 7 perception renderer, asks a
large model to produce a completion, and records it).

The scenarios are programmatic. There is no pile of fixed scene strings —
only a small parameter space over:
- distance bands (proximity / medium / far)
- target kinds (entity / object / both)
- reward contexts (satisfaction / threat / novelty / none)

These parameters are scenario SCAFFOLDING, not substrate tuning; they cover
the verb space so the large-model completions cover it too. The being's
emergent response to each scenario is what gets trained on, not the scene.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

# Distance bands — chosen to span the q_*able receptive fields that Phase 4's
# distance-action compound neurons typically learn (touchable ~0.5 tiles,
# approachable ~5 tiles per test_distance_action_compound). These are
# COVERAGE POINTS, not substrate constants — if the compound fields migrate
# (two beings develop different fields for q_touchable), the scenario generator
# still runs; the completions will just reflect each being's own fields.
_DISTANCE_BANDS = [
    ("proximity", 0.5),
    ("close", 2.0),
    ("medium", 5.0),
    ("far", 9.0),
]

# Target kinds the being can encounter. "both" means a scenario where both
# an entity and an object are present — exercises Phase 6's rank-across-
# categories without a fixed category bias.
_TARGET_KINDS = ["entity_only", "object_only", "both"]

# Reward contexts. Each corresponds to a real Phase 1 reward-event category
# (see `reward_magnitudes` in perception_constants.json). At generate time
# we don't fire rewards — we just tag the scenario so downstream harvesting
# knows which verb-class the scene is probing.
_REWARD_CONTEXTS = [
    "reward_drive_satisfaction",
    "reward_threat_avoided",
    "reward_social_accepted",
    "reward_explore_discovered",
    "none",
]


@dataclass
class Scenario:
    """One synthetic scene. `context` is the Phase 6-shaped dict the
    perception renderer consumes; `probe_verb` names the verb class this
    scenario is intended to exercise (TOUCH at proximity, APPROACH at medium
    distance, EXAMINE on an object, etc.)."""
    scenario_id: str
    probe_verb: str
    reward_context: str
    distance_band: str
    target_kind: str
    context: dict
    metadata: dict = field(default_factory=dict)


def _entity(eid: str, name: str, distance: float) -> dict:
    return {
        "id": eid,
        "name": name,
        "distance": distance,
        "direction": "north",
        "exposure": 0.9,
    }


def _object(eid: str, name: str, distance: float, state: str = "") -> dict:
    return {
        "id": eid,
        "name": name,
        "distance": distance,
        "direction": "east",
        "state": state,
        "exposure": 0.9,
    }


def _verb_for(distance_band: str, target_kind: str) -> str:
    """Map (distance_band, target_kind) to the verb class the scene exercises.
    These mappings are NOT the grammar's verb gate — the being's own
    compound neurons decide grammar. This is just which verb-class the
    scenario is PROBING for coverage-target accounting."""
    if distance_band == "proximity":
        if target_kind == "object_only":
            return "INTERACT"
        return "TOUCH"
    if distance_band in ("close", "medium"):
        if target_kind == "entity_only":
            return "APPROACH"
        if target_kind == "object_only":
            return "EXAMINE"
        return "APPROACH"
    # Far
    if target_kind == "entity_only":
        return "WATCH"
    if target_kind == "object_only":
        return "LOOK AT"
    return "LOOK AT"


def _base_context(persona_name: str, role: str) -> dict:
    """Minimal context skeleton; per-scenario overrides add visible/objects."""
    return {
        "npc_name": persona_name,
        "role": role,
        "location": "town_square",
        "current_action": "idle",
        "drives": {"energy": 70, "hunger": 30, "social_need": 40,
                   "safety": 70, "frustration": 0.0},
        "somatic_tags": [],
        "body_narrative": "You feel steady.",
        "visible": [],
        "visible_objects": [],
        "heard": [],
        "recent_events": [],
        "intentions_summary": "idle",
        "beliefs_summary": "none",
        "recent_thoughts": [],
        "carried_items": [],
        "available_items": [],
        "known_locations": ["town_square", "bakery", "market"],
        "glimpsed_buildings": [],
        "identity_appraisal_decoded": {},
        "compounds": {"active": {}, "count": 8},  # mature default
    }


def generate(persona_name: str = "probe_being", role: str = "villager",
             entity_names: list[str] | None = None,
             object_names: list[str] | None = None) -> Iterator[Scenario]:
    """Produce every (band × kind × reward) triple. With 4 bands × 3 kinds ×
    5 reward contexts the generator yields 60 scenarios — small enough to
    hand to a large-model generator without dominating run time, large
    enough to cover the verb space per spec §15.2.

    `entity_names` / `object_names` are provided by the caller (e.g. the
    real town roster + a few real objects); the generator just fills slots.
    If omitted, fallback names are used.
    """
    ents = entity_names or ["Mabel", "Hugo", "Roland"]
    objs = object_names or ["well", "oven", "ledger"]

    scenario_idx = 0
    for band_name, dist in _DISTANCE_BANDS:
        for kind in _TARGET_KINDS:
            for reward in _REWARD_CONTEXTS:
                ctx = _base_context(persona_name, role)
                entity_name = ents[scenario_idx % len(ents)]
                object_name = objs[scenario_idx % len(objs)]
                entity_eid = f"ent_{entity_name.lower()}_probe{scenario_idx}"
                object_eid = f"obj_{object_name.lower()}_probe{scenario_idx}"
                if kind in ("entity_only", "both"):
                    ctx["visible"].append(_entity(entity_eid, entity_name, dist))
                if kind in ("object_only", "both"):
                    ctx["visible_objects"].append(_object(object_eid, object_name, dist))
                probe_verb = _verb_for(band_name, kind)
                yield Scenario(
                    scenario_id=f"synth_{scenario_idx:04d}_{band_name}_{kind}_{reward}",
                    probe_verb=probe_verb,
                    reward_context=reward,
                    distance_band=band_name,
                    target_kind=kind,
                    context=ctx,
                    metadata={
                        "persona_name": persona_name,
                        "role": role,
                        "distance_tiles": dist,
                    },
                )
                scenario_idx += 1


def verb_coverage(scenarios: list[Scenario]) -> dict[str, int]:
    """Count probe_verb frequencies across a scenario set — used by the
    generator's coverage audit + tests. Verb-class balance per spec §15.2."""
    counts: dict[str, int] = {}
    for s in scenarios:
        counts[s.probe_verb] = counts.get(s.probe_verb, 0) + 1
    return counts
