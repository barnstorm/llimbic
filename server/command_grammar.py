"""Phase 7 — compound-neuron-gated GBNF grammar + F4 fallback decay.

Per docs/perception_spec.md §7.3 and docs/perception_implementation_plan.md
Phase 7: verbs are gated on active compound neurons, not hand-authored
presence rules. The being can TOUCH only when the substrate says a touch is
affordable — `q_touchable` fires when visible distance has co-occurred with
action_success_TOUCH enough times to have spawned and activated that
compound quality.

Fallback (F4, from the spec §7.3 "Fallback for being's first hours"): until
compound neurons exist, crude distance activation gates proximity verbs.
This fallback decays automatically:

    fallback_coefficient = max(0, 1 - compound_count / N_FALLBACK_RETIRE)

At compound_count ≥ N_FALLBACK_RETIRE (8 in constants), the fallback
contributes zero — only emergent compounds decide verbs. The per-tick
`fallback_contribution` metric (returned alongside the grammar) is the
fraction of verbs made available by the fallback path, weighted by the
decay coefficient. Mature beings (count ≥ N) MUST show <0.01 rolling mean
or the F4 gate fails.

The verb→compound mapping is:
  TOUCH        → q_touchable
  TAKE         → q_touchable (proximity to inventoriable object)
  APPROACH     → requires target visible AND q_touchable NOT active
                 (already close → no approach; this is the §7.3 negation rule)
  INTERACT     → q_interactable
  OFFER / GIVE / SHOW → q_offerable
  EXAMINE / LOOK AT / FLEE / WATCH / FOLLOW / SAY / WAIT / WANDER
  / GO TO / REST / HIDE / POINT AT / LISTEN TO / EXPLORE / DROP / CONSUME
  → autonomic; verb availability follows only from target presence (no
    compound gate). These are either always-available or obvious from
    inventory/visibility; spec §7.3 does not list compounds for them.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path


# Fixed location names from data/locations.json (Tier-1 world vocabulary).
LOCATIONS = [
    "bakery", "guard_post", "herbalist_shop", "courier_office",
    "blacksmith", "town_square", "market", "farm", "inn",
    "home_north", "home_east", "home_south", "home_west",
    "well", "road_east", "road_south",
]

# Constant-file read. F4 retire threshold + fallback-proximity distance.
_CONSTS_PATH = Path(__file__).resolve().parent.parent / "data" / "perception_constants.json"
try:
    with _CONSTS_PATH.open() as _f:
        _CONSTS = json.load(_f)
    _N_FALLBACK_RETIRE = int(_CONSTS.get("n_fallback_retire", 8))
except Exception:
    _N_FALLBACK_RETIRE = 8


# Per-verb compound map. Only entries listed here are gated; other verbs are
# autonomic (no compound requirement). Spec §7.3 lists TOUCH/TAKE/APPROACH/
# SAY as examples; we extend to the verbs this substrate has actually spawned
# q_*able neurons for in Phase 4. If a verb has no compound yet, its entry
# here says "fallback from distance" and the F4 decay keeps it honest.
_VERB_COMPOUND_MAP: dict[str, str] = {
    "TOUCH": "q_touchable",
    "TAKE": "q_touchable",
    "INTERACT": "q_interactable",
    "OFFER": "q_offerable",
    "GIVE": "q_offerable",
    "SHOW": "q_offerable",
}

# Verbs that are NEGATED by a compound (spec §7.3: APPROACH requires q_touchable
# NOT firing — "already close → no approach"). Different semantics from the
# positive-gate map.
_VERB_NEGATION_MAP: dict[str, str] = {
    "APPROACH": "q_touchable",
}


def _gbnf_literal(s: str) -> str:
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _gbnf_alternatives(items: list[str]) -> str:
    if not items:
        return '""'
    return " | ".join(_gbnf_literal(s) for s in items)


def _any_visible_in_proximity(visible: list[dict], visible_objects: list[dict],
                              proximity_tiles: float = 2.0) -> bool:
    """Fallback proximity test per spec §7.3: `sense_dist_X > 50` corresponds
    to being very close. `sense_dist = 100 * exp(-d/TAU)` with TAU=4, so
    `sense_dist > 50` ⇔ d < TAU * ln(2) ≈ 2.77 tiles. Using 2 tiles here for
    a slightly tighter crude-proximity threshold; this is the cold-start
    proxy for `q_touchable` before the compound spawns."""
    for v in (visible or []) + (visible_objects or []):
        try:
            d = float(v.get("distance", 9999))
        except (TypeError, ValueError):
            continue
        if d <= proximity_tiles:
            return True
    return False


@dataclass
class GrammarResult:
    """Grammar + per-tick F4 fallback contribution for trace / CI."""
    gbnf: str
    fallback_coefficient: float  # max(0, 1 - compound_count/N)
    fallback_contribution: float  # in [0, 1]: fraction of verbs admitted via fallback × coefficient
    verbs_available: list[str] = field(default_factory=list)
    verbs_via_compound: list[str] = field(default_factory=list)
    verbs_via_fallback: list[str] = field(default_factory=list)
    verbs_blocked: list[str] = field(default_factory=list)


def _fallback_coefficient(compound_count: int) -> float:
    """F4 decay. Count ≥ N → 0. Monotonically decreasing in count."""
    if _N_FALLBACK_RETIRE <= 0:
        return 0.0
    return max(0.0, 1.0 - float(compound_count) / float(_N_FALLBACK_RETIRE))


def _verb_admitted(verb: str, active_compounds: set[str], in_proximity: bool,
                   fallback_coef: float) -> tuple[bool, str]:
    """Decide whether a compound-gated verb is admitted this tick.
    Returns (admitted, via_path) where via_path is "compound" | "fallback" | "blocked".

    The fallback path only contributes when `fallback_coef > 0` AND crude
    distance says the verb would make sense. Once fallback_coef reaches 0
    (mature being), the verb either has its compound or it's blocked."""
    required = _VERB_COMPOUND_MAP.get(verb)
    negated = _VERB_NEGATION_MAP.get(verb)

    if negated:
        # Negation verbs (APPROACH): admitted iff its negating compound is NOT
        # active. Fallback: admitted if NOT in proximity (and coef > 0).
        if negated not in active_compounds:
            return (True, "compound")
        if fallback_coef > 0.0 and not in_proximity:
            return (True, "fallback")
        return (False, "blocked")

    if required is None:
        # Autonomic — no compound gate, always admitted.
        return (True, "compound")

    if required in active_compounds:
        return (True, "compound")
    if fallback_coef > 0.0 and in_proximity:
        return (True, "fallback")
    return (False, "blocked")


def build_gbnf(
    visible_entities: list[str],
    visible_objects: list[str],
    *,
    locations: list[str] | None = None,
    carried_items: list[str] | None = None,
    available_items: list[str] | None = None,
    glimpsed_directions: list[str] | None = None,
    active_compounds: set[str] | None = None,
    compound_count: int = 0,
    in_proximity: bool = False,
) -> GrammarResult:
    """Build a GBNF grammar + F4 metrics.

    Phase 7 signature additions:
      active_compounds: the compound-quality neuron ids currently firing.
      compound_count:   total compounds the being has emerged (drives F4 decay).
      in_proximity:     crude fallback signal — whether any target is close.
    """
    active_compounds = set(active_compounds or set())
    locs = locations or LOCATIONS
    carried = carried_items or []
    available = available_items or []
    glimpsed_dirs = glimpsed_directions or []

    fallback_coef = _fallback_coefficient(compound_count)

    has_entities = len(visible_entities) > 0
    has_objects = len(visible_objects) > 0
    has_carried = len(carried) > 0
    has_available = len(available) > 0
    has_locations = len(locs) > 0
    has_glimpsed = len(glimpsed_dirs) > 0

    entity_rule = _gbnf_alternatives(visible_entities) if has_entities else None
    object_rule = _gbnf_alternatives(visible_objects) if has_objects else None
    location_rule = _gbnf_alternatives(locs) if has_locations else None

    noun_parts: list[str] = []
    if has_entities:
        noun_parts.append("entity")
    if has_objects:
        noun_parts.append("object")
    if has_locations:
        noun_parts.append("location")
    if not noun_parts:
        noun_parts.append("entity")
    noun_rule = " | ".join(noun_parts)

    # Verb admission decisions with compound gating + fallback decay.
    commands: list[str] = []
    verbs_via_compound: list[str] = []
    verbs_via_fallback: list[str] = []
    verbs_blocked: list[str] = []

    def _decide(verb_token: str, rule_name: str, precondition: bool = True) -> None:
        if not precondition:
            verbs_blocked.append(verb_token)
            return
        admitted, via = _verb_admitted(verb_token, active_compounds, in_proximity, fallback_coef)
        if not admitted:
            verbs_blocked.append(verb_token)
            return
        commands.append(rule_name)
        if via == "compound":
            verbs_via_compound.append(verb_token)
        else:
            verbs_via_fallback.append(verb_token)

    # Autonomic verbs — no compound gate.
    if has_locations:
        _decide("GO TO", "go-cmd")
    _decide("LOOK AT", "look-cmd")
    if has_objects:
        _decide("EXAMINE", "examine-cmd")
    if has_entities:
        _decide("FLEE FROM", "flee-cmd")
        _decide("WATCH", "watch-cmd")
        _decide("FOLLOW", "follow-cmd")
    _decide("WAIT", "wait-cmd")
    _decide("WANDER", "wander-cmd")
    _decide("SAY", "say-cmd")
    _decide("REST", "rest-cmd")
    _decide("HIDE", "hide-cmd")
    if has_glimpsed:
        _decide("EXPLORE", "explore-cmd")

    # Compound-gated: INTERACT (objects present + q_interactable or fallback)
    if has_objects:
        _decide("INTERACT", "interact-cmd")

    # Compound-gated: TOUCH (targets + q_touchable or fallback)
    touchable_parts: list[str] = []
    if has_entities:
        touchable_parts.append("entity")
    if has_objects:
        touchable_parts.append("object")
    if has_available:
        touchable_parts.append("available-item")
    if touchable_parts:
        _decide("TOUCH", "touch-cmd")

    # Compound-NEGATED: APPROACH (target visible AND q_touchable NOT firing)
    if has_entities:
        _decide("APPROACH", "approach-cmd")

    # POINT AT — autonomic, kept for reference
    pointable_parts: list[str] = []
    if has_entities:
        pointable_parts.append("entity")
    if has_objects:
        pointable_parts.append("object")
    if pointable_parts:
        _decide("POINT AT", "point-cmd")

    # LISTEN TO — autonomic; Phase 9 may gate on a future heard compound
    listen_parts: list[str] = []
    if has_entities:
        listen_parts.append("entity")
    if has_locations:
        listen_parts.append("location")
    if listen_parts:
        _decide("LISTEN TO", "listen-cmd")

    # Inventory verbs. TAKE compound-gated on q_touchable (need to reach item).
    if has_available:
        _decide("TAKE", "take-cmd")
    if has_carried:
        _decide("CONSUME", "consume-cmd")
        _decide("DROP", "drop-cmd")
    if has_carried and has_entities:
        _decide("GIVE", "give-cmd")
        _decide("OFFER", "offer-cmd")
        _decide("SHOW", "show-cmd")

    # F4 contribution: fraction of admitted verbs that came through the
    # fallback path, scaled by the decay coefficient. At count ≥ N, coef = 0
    # and this is always 0 regardless of what went through fallback.
    n_admitted = max(1, len(commands))
    fallback_contribution = fallback_coef * (len(verbs_via_fallback) / n_admitted)

    # Must have at least one command for the grammar to parse; if every verb
    # was blocked, emit WAIT as a last-resort autonomic.
    if not commands:
        commands.append("wait-cmd")

    command_rule = " | ".join(commands)

    # --- Assemble GBNF lines ---
    lines = [
        f'root ::= command "\\n"',
        "",
        f"command ::= {command_rule}",
        "",
    ]
    if has_locations:
        lines.append('go-cmd ::= "GO TO " noun')
    lines.append('look-cmd ::= "LOOK AT " noun')
    lines.append('wait-cmd ::= "WAIT"')
    lines.append(
        'wander-cmd ::= "WANDER" (" AT " location)?'
        if has_locations
        else 'wander-cmd ::= "WANDER"'
    )
    lines.append(
        'say-cmd ::= "SAY \\"" utterance "\\"" (" TO " entity)?'
        if has_entities
        else 'say-cmd ::= "SAY \\"" utterance "\\""'
    )
    if "examine-cmd" in commands:
        lines.append('examine-cmd ::= "EXAMINE " object')
    if "interact-cmd" in commands:
        lines.append('interact-cmd ::= "INTERACT WITH " object')
    if "flee-cmd" in commands:
        lines.append('flee-cmd ::= "FLEE FROM " entity')
    if "approach-cmd" in commands:
        lines.append('approach-cmd ::= "APPROACH " entity')
    if "watch-cmd" in commands:
        lines.append('watch-cmd ::= "WATCH " entity')
    if "follow-cmd" in commands:
        lines.append('follow-cmd ::= "FOLLOW " entity')
    if "explore-cmd" in commands:
        lines.append('explore-cmd ::= "EXPLORE " compass')
    lines.append('rest-cmd ::= "REST"')
    lines.append('hide-cmd ::= "HIDE"')
    if "touch-cmd" in commands:
        lines.append('touch-cmd ::= "TOUCH " touchable')
        lines.append("touchable ::= " + " | ".join(touchable_parts))
    if "point-cmd" in commands:
        lines.append('point-cmd ::= "POINT AT " pointable')
        lines.append("pointable ::= " + " | ".join(pointable_parts))
    if "listen-cmd" in commands:
        lines.append('listen-cmd ::= "LISTEN TO " listenable')
        lines.append("listenable ::= " + " | ".join(listen_parts))
    if "take-cmd" in commands:
        lines.append('take-cmd ::= "TAKE " available-item')
    if "consume-cmd" in commands:
        lines.append('consume-cmd ::= "CONSUME " carried-item')
    if "drop-cmd" in commands:
        lines.append('drop-cmd ::= "DROP " carried-item')
    if "give-cmd" in commands:
        lines.append('give-cmd ::= "GIVE " carried-item " TO " entity')
    if "offer-cmd" in commands:
        lines.append('offer-cmd ::= "OFFER " carried-item " TO " entity')
    if "show-cmd" in commands:
        lines.append('show-cmd ::= "SHOW " carried-item " TO " entity')

    lines.append("")
    lines.append(f"noun ::= {noun_rule}")
    if has_entities:
        lines.append(f"entity ::= {entity_rule}")
    if has_objects:
        lines.append(f"object ::= {object_rule}")
    if has_locations:
        lines.append(f"location ::= {location_rule}")
    if has_glimpsed:
        unique_dirs = list(dict.fromkeys(glimpsed_dirs))
        lines.append(f"compass ::= {_gbnf_alternatives(unique_dirs)}")
    if has_carried:
        lines.append(f"carried-item ::= {_gbnf_alternatives(carried)}")
    if has_available:
        lines.append(f"available-item ::= {_gbnf_alternatives(available)}")

    lines.append("")
    lines.append('utterance ::= [^"]{1,80}')

    verbs_available = verbs_via_compound + verbs_via_fallback
    return GrammarResult(
        gbnf="\n".join(lines),
        fallback_coefficient=fallback_coef,
        fallback_contribution=fallback_contribution,
        verbs_available=verbs_available,
        verbs_via_compound=verbs_via_compound,
        verbs_via_fallback=verbs_via_fallback,
        verbs_blocked=verbs_blocked,
    )


def build_gbnf_from_context(context: dict) -> GrammarResult:
    """Build GBNF + F4 metrics from a thought context (as produced by
    NPCState.build_thought_context). Reads context["compounds"] for active
    compound neurons + count, context["visible"]/context["visible_objects"]
    for proximity, and the usual location/item fields."""
    entities = [v["name"] for v in context.get("visible", []) if v.get("name")]
    objects = [v["name"] for v in context.get("visible_objects", []) if v.get("name")]
    carried = context.get("carried_items", [])
    available = context.get("available_items", [])
    known_locations = context.get("known_locations", None)
    glimpsed = context.get("glimpsed_buildings", [])
    glimpsed_dirs = [g["direction"] for g in glimpsed if g.get("direction")]

    compounds_payload = context.get("compounds") or {}
    active_compounds = set((compounds_payload.get("active") or {}).keys())
    compound_count = int(compounds_payload.get("count", 0))

    in_prox = _any_visible_in_proximity(
        context.get("visible", []),
        context.get("visible_objects", []),
    )

    return build_gbnf(
        entities, objects,
        locations=known_locations if known_locations else None,
        carried_items=carried,
        available_items=available,
        glimpsed_directions=glimpsed_dirs if glimpsed_dirs else None,
        active_compounds=active_compounds,
        compound_count=compound_count,
        in_proximity=in_prox,
    )
