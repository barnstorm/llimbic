"""
Persona loader for Python inference servers.
Reads NPC persona JSON files from data/npcs/ directory.
"""
import json
from pathlib import Path

_DATA_DIR = Path(__file__).parent.parent / "data"
_NPC_DIR = _DATA_DIR / "npcs"

_personas: dict[str, dict] = {}
_locations: dict = {}


def load_persona(name: str) -> dict:
    path = _NPC_DIR / f"{name.lower()}.json"
    if not path.exists():
        return {}
    with open(path) as f:
        return json.load(f)


def load_all_personas() -> dict[str, dict]:
    global _personas
    if _personas:
        return _personas
    if not _NPC_DIR.exists():
        return {}
    for path in sorted(_NPC_DIR.glob("*.json")):
        data = json.loads(path.read_text())
        _personas[data.get("name", path.stem)] = data
    return _personas


def get_persona_by_role(role: str) -> dict:
    personas = load_all_personas()
    for p in personas.values():
        if p.get("role") == role:
            return p
    return {}


def get_persona_by_name(name: str) -> dict:
    personas = load_all_personas()
    return personas.get(name, {})


def load_locations() -> dict:
    global _locations
    if _locations:
        return _locations
    path = _DATA_DIR / "locations.json"
    if not path.exists():
        return {}
    with open(path) as f:
        _locations = json.load(f)
    return _locations


def get_schedule_for_role(role: str) -> list[dict]:
    persona = get_persona_by_role(role)
    return persona.get("schedule", [])


def get_fallback_dialogue(role: str) -> dict:
    persona = get_persona_by_role(role)
    return persona.get("fallback_dialogue", {
        "greeting": "Hello.",
        "complaint": "Things are tough.",
        "gossip": "Heard anything?",
        "busy": "I'm busy.",
    })
