"""
Dynamic GBNF grammar builder for adventure-game NPC commands.

Builds a grammar per-inference from the NPC's current perception snapshot,
ensuring the model can only reference entities, objects, and locations
it can actually perceive.

The grammar enforces: VERB NOUN [PREP NOUN] structure.
Applied only to the post-</think> command output (second inference pass).
"""

import re

# Fixed location names from data/locations.json
LOCATIONS = [
    "bakery", "guard_post", "herbalist_shop", "courier_office",
    "blacksmith", "town_square", "market", "farm", "inn",
    "home_north", "home_east", "home_south", "home_west",
    "well", "road_east", "road_south",
]


def _gbnf_literal(s: str) -> str:
    """Escape a string as a GBNF double-quoted literal."""
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _gbnf_alternatives(items: list[str]) -> str:
    """Build a GBNF alternation rule from a list of literal strings."""
    if not items:
        return '""'  # empty match — should be guarded against before calling
    return " | ".join(_gbnf_literal(s) for s in items)


def build_gbnf(
    visible_entities: list[str],
    visible_objects: list[str],
    locations: list[str] | None = None,
    carried_items: list[str] | None = None,
    available_items: list[str] | None = None,
    glimpsed_directions: list[str] | None = None,
) -> str:
    """
    Build a GBNF grammar string for the command output.

    Args:
        visible_entities: Names of currently visible NPCs/player
        visible_objects:  Names of currently visible world objects
        locations:        Known location list (discovered only, default: all 16)
        carried_items:    Items in NPC's inventory (for CONSUME/DROP/GIVE)
        available_items:  Items available at current location (for TAKE)
        glimpsed_directions: Compass directions of visible but unknown buildings

    Returns:
        GBNF grammar string ready for llama.cpp --grammar flag.
    """
    locs = locations or LOCATIONS
    carried = carried_items or []
    available = available_items or []
    glimpsed_dirs = glimpsed_directions or []

    # --- Build noun rules ---
    has_entities = len(visible_entities) > 0
    has_objects = len(visible_objects) > 0
    has_carried = len(carried) > 0
    has_available = len(available) > 0
    has_locations = len(locs) > 0
    has_glimpsed = len(glimpsed_dirs) > 0

    entity_rule = _gbnf_alternatives(visible_entities) if has_entities else None
    object_rule = _gbnf_alternatives(visible_objects) if has_objects else None
    location_rule = _gbnf_alternatives(locs) if has_locations else None

    # noun = anything the model can target (entity, object, or location)
    noun_parts = []
    if has_entities:
        noun_parts.append("entity")
    if has_objects:
        noun_parts.append("object")
    if has_locations:
        noun_parts.append("location")
    if not noun_parts:
        noun_parts.append("entity")  # fallback — grammar needs at least one noun
    noun_rule = " | ".join(noun_parts)

    # --- Build command rules ---
    commands = []

    if has_locations:
        commands.append("go-cmd")
    commands.append("look-cmd")

    if has_objects:
        commands.append("examine-cmd")
    if has_entities:
        commands.append("flee-cmd")

    commands.append("wait-cmd")
    commands.append("wander-cmd")
    commands.append("say-cmd")

    if has_entities:
        commands.append("approach-cmd")

    # EXPLORE — approach a visible but unknown building
    if has_glimpsed:
        commands.append("explore-cmd")

    # Inventory commands — only when relevant items exist
    if has_available:
        commands.append("take-cmd")
    if has_carried:
        commands.append("consume-cmd")
        commands.append("drop-cmd")
    if has_carried and has_entities:
        commands.append("give-cmd")

    command_rule = " | ".join(commands)

    # --- Assemble grammar ---
    lines = [
        f'root ::= command "\\n"',
        "",
        f"command ::= {command_rule}",
        "",
        # Verb rules
        *(['go-cmd ::= "GO TO " noun'] if has_locations else []),
        'look-cmd ::= "LOOK AT " noun',
        'wait-cmd ::= "WAIT"',
        f'wander-cmd ::= "WANDER" (" AT " location)?' if has_locations else 'wander-cmd ::= "WANDER"',
        'say-cmd ::= "SAY \\"" utterance "\\"" (" TO " entity)?'
        if has_entities
        else 'say-cmd ::= "SAY \\"" utterance "\\""',
    ]

    if has_objects:
        lines.append('examine-cmd ::= "EXAMINE " object')
    if has_entities:
        lines.append('flee-cmd ::= "FLEE FROM " entity')
        lines.append('approach-cmd ::= "APPROACH " entity')
    if has_glimpsed:
        lines.append('explore-cmd ::= "EXPLORE " compass')

    # Inventory commands
    if has_available:
        lines.append('take-cmd ::= "TAKE " available-item')
    if has_carried:
        lines.append('consume-cmd ::= "CONSUME " carried-item')
        lines.append('drop-cmd ::= "DROP " carried-item')
    if has_carried and has_entities:
        lines.append('give-cmd ::= "GIVE " carried-item " TO " entity')

    lines.append("")

    # Noun rules
    lines.append(f"noun ::= {noun_rule}")
    if has_entities:
        lines.append(f"entity ::= {entity_rule}")
    if has_objects:
        lines.append(f"object ::= {object_rule}")
    if has_locations:
        lines.append(f"location ::= {location_rule}")
    if has_glimpsed:
        # Deduplicate directions
        unique_dirs = list(dict.fromkeys(glimpsed_dirs))
        lines.append(f"compass ::= {_gbnf_alternatives(unique_dirs)}")

    # Item rules
    if has_carried:
        lines.append(f"carried-item ::= {_gbnf_alternatives(carried)}")
    if has_available:
        lines.append(f"available-item ::= {_gbnf_alternatives(available)}")

    lines.append("")

    # Utterance: up to 80 chars, no double-quotes
    lines.append('utterance ::= [^"]{1,80}')

    return "\n".join(lines)


def build_gbnf_from_context(context: dict) -> str:
    """
    Build GBNF grammar from a thought context dict (as produced by
    NPCState.build_thought_context()).

    Extracts entity names, object names, inventory items, and discovered locations.
    """
    entities = [v["name"] for v in context.get("visible", []) if v.get("name")]
    objects = [v["name"] for v in context.get("visible_objects", []) if v.get("name")]
    carried = context.get("carried_items", [])
    available = context.get("available_items", [])
    # Location discovery: only known locations appear in grammar
    known_locations = context.get("known_locations", None)
    # Glimpsed building directions for EXPLORE command
    glimpsed = context.get("glimpsed_buildings", [])
    glimpsed_dirs = [g["direction"] for g in glimpsed if g.get("direction")]
    return build_gbnf(
        entities, objects,
        locations=known_locations if known_locations else None,
        carried_items=carried,
        available_items=available,
        glimpsed_directions=glimpsed_dirs if glimpsed_dirs else None,
    )
