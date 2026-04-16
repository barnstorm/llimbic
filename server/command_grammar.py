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
) -> str:
    """
    Build a GBNF grammar string for the command output.

    Args:
        visible_entities: Names of currently visible NPCs/player
                          e.g. ["Edith", "Roland", "Player"]
        visible_objects:  Names of currently visible world objects
                          e.g. ["Brick Oven", "Flour Sacks"]
        locations:        Override location list (default: all 16)

    Returns:
        GBNF grammar string ready for llama.cpp --grammar flag.
    """
    locs = locations or LOCATIONS

    # --- Build noun rules ---
    has_entities = len(visible_entities) > 0
    has_objects = len(visible_objects) > 0

    entity_rule = _gbnf_alternatives(visible_entities) if has_entities else None
    object_rule = _gbnf_alternatives(visible_objects) if has_objects else None
    location_rule = _gbnf_alternatives(locs)

    # noun = anything the model can target (entity, object, or location)
    noun_parts = []
    if has_entities:
        noun_parts.append("entity")
    if has_objects:
        noun_parts.append("object")
    noun_parts.append("location")
    noun_rule = " | ".join(noun_parts)

    # --- Build command rules ---
    # Only include commands whose noun types are available
    commands = []

    # GO TO — always available (can always go to a location)
    commands.append("go-cmd")

    # LOOK AT — needs at least one visible noun
    commands.append("look-cmd")

    # EXAMINE — only if objects are visible
    if has_objects:
        commands.append("examine-cmd")

    # FLEE FROM — only if entities are visible
    if has_entities:
        commands.append("flee-cmd")

    # WAIT — always available
    commands.append("wait-cmd")

    # WANDER — always available
    commands.append("wander-cmd")

    # SAY — always available (can say things even with no one around)
    commands.append("say-cmd")

    # APPROACH — only if entities are visible
    if has_entities:
        commands.append("approach-cmd")

    command_rule = " | ".join(commands)

    # --- Assemble grammar ---
    lines = [
        f'root ::= command "\\n"',
        "",
        f"command ::= {command_rule}",
        "",
        # Verb rules
        'go-cmd ::= "GO TO " noun',
        'look-cmd ::= "LOOK AT " noun',
        'wait-cmd ::= "WAIT"',
        f'wander-cmd ::= "WANDER" (" AT " location)?',
        'say-cmd ::= "SAY \\"" utterance "\\"" (" TO " entity)?'
        if has_entities
        else 'say-cmd ::= "SAY \\"" utterance "\\""',
    ]

    if has_objects:
        lines.append('examine-cmd ::= "EXAMINE " object')
    if has_entities:
        lines.append('flee-cmd ::= "FLEE FROM " entity')
        lines.append('approach-cmd ::= "APPROACH " entity')

    lines.append("")

    # Noun rules
    lines.append(f"noun ::= {noun_rule}")
    if has_entities:
        lines.append(f"entity ::= {entity_rule}")
    if has_objects:
        lines.append(f"object ::= {object_rule}")
    lines.append(f"location ::= {location_rule}")

    lines.append("")

    # Utterance: up to 80 chars, no double-quotes
    lines.append('utterance ::= [^"]{1,80}')

    return "\n".join(lines)


def build_gbnf_from_context(context: dict) -> str:
    """
    Build GBNF grammar from a thought context dict (as produced by
    NPCState.build_thought_context()).

    Extracts entity names from context["visible"] and object names from
    context.get("visible_objects", []).
    """
    entities = [v["name"] for v in context.get("visible", []) if v.get("name")]
    objects = [v["name"] for v in context.get("visible_objects", []) if v.get("name")]
    return build_gbnf(entities, objects)
