"""
Parser for adventure-game NPC command output.

Handles the two-part model output:
  1. <think>...</think> block — inner monologue (extracted for display + L2 coloring)
  2. COMMAND line — parsed into push protocol commands (intentions, biases, triggers)

Commands become biases, not overrides. The L1 Hebbian network retains
authority via softmax competition.
"""

import re
import logging

log = logging.getLogger("layer3")

# Regex for the think block
_THINK_RE = re.compile(r"<think>(.*?)</think>", re.DOTALL)

# Command patterns — order matters (longest match first)
_CMD_PATTERNS = [
    # SAY "text" TO entity
    (re.compile(r'^SAY\s+"([^"]{1,80})"\s+TO\s+(.+)$'), "say_to"),
    # SAY "text"
    (re.compile(r'^SAY\s+"([^"]{1,80})"$'), "say"),
    # GO TO noun
    (re.compile(r"^GO\s+TO\s+(.+)$"), "go_to"),
    # LOOK AT noun
    (re.compile(r"^LOOK\s+AT\s+(.+)$"), "look_at"),
    # EXAMINE noun
    (re.compile(r"^EXAMINE\s+(.+)$"), "examine"),
    # FLEE FROM entity
    (re.compile(r"^FLEE\s+FROM\s+(.+)$"), "flee_from"),
    # APPROACH entity
    (re.compile(r"^APPROACH\s+(.+)$"), "approach"),
    # WANDER AT location
    (re.compile(r"^WANDER\s+AT\s+(.+)$"), "wander_at"),
    # WANDER (no target)
    (re.compile(r"^WANDER$"), "wander"),
    # WAIT
    (re.compile(r"^WAIT$"), "wait"),
]


def _resolve_noun(noun: str, context: dict) -> dict | None:
    """
    Resolve a noun string to a target dict with type and position.

    Returns:
        {"type": "entity"|"object"|"location", "name": str, "position": [x,y]}
        or None if unresolvable.
    """
    # Check visible entities
    for v in context.get("visible", []):
        if v.get("name") == noun:
            return {
                "type": "entity",
                "name": noun,
                "position": v.get("position"),
            }

    # Check visible objects
    for v in context.get("visible_objects", []):
        if v.get("name") == noun:
            return {
                "type": "object",
                "name": noun,
                "id": v.get("id", noun),
                "position": v.get("position"),
            }

    # Check locations (resolved by caller via locations dict)
    # Return without position — caller resolves from locations.json
    return {"type": "location", "name": noun, "position": None}


def _parse_command_line(cmd_line: str, context: dict) -> dict:
    """
    Parse a single command line into push protocol commands.

    Returns dict with keys:
        intentions: list of intention dicts
        action_biases: dict of {action_name: float}
        trigger_actions: list of trigger dicts
        command: str (the raw command for logging)
        target: resolved noun dict or None
    """
    result = {
        "intentions": [],
        "action_biases": {},
        "trigger_actions": [],
        "command": cmd_line,
        "target": None,
    }

    cmd_line = cmd_line.strip()
    if not cmd_line:
        return result

    for pattern, cmd_type in _CMD_PATTERNS:
        m = pattern.match(cmd_line)
        if not m:
            continue

        if cmd_type == "go_to":
            noun = m.group(1)
            target = _resolve_noun(noun, context)
            result["target"] = target
            if target and target["type"] == "location":
                result["intentions"].append({
                    "goal": f"go to {noun}",
                    "location": noun,
                    "priority": 0.6,
                    "reason": "command",
                })
            result["action_biases"]["approach"] = 0.4

        elif cmd_type == "look_at":
            noun = m.group(1)
            target = _resolve_noun(noun, context)
            result["target"] = target
            result["action_biases"]["observe"] = 0.5

        elif cmd_type == "examine":
            noun = m.group(1)
            target = _resolve_noun(noun, context)
            result["target"] = target
            if target:
                result["trigger_actions"].append({
                    "type": "examine",
                    "object_id": target.get("id", noun),
                    "target": target.get("position"),
                })
            result["action_biases"]["observe"] = 0.4

        elif cmd_type == "flee_from":
            noun = m.group(1)
            target = _resolve_noun(noun, context)
            result["target"] = target
            result["action_biases"]["flee"] = 0.6
            result["action_biases"]["avoid"] = 0.3

        elif cmd_type == "approach":
            noun = m.group(1)
            target = _resolve_noun(noun, context)
            result["target"] = target
            result["action_biases"]["approach"] = 0.5

        elif cmd_type == "wander_at":
            loc = m.group(1)
            result["intentions"].append({
                "goal": f"wander at {loc}",
                "location": loc,
                "priority": 0.4,
                "reason": "command",
            })
            result["action_biases"]["approach"] = 0.1

        elif cmd_type == "wander":
            result["action_biases"]["approach"] = 0.1

        elif cmd_type == "wait":
            result["action_biases"]["approach"] = -0.3

        elif cmd_type == "say":
            text = m.group(1)
            result["trigger_actions"].append({
                "type": "speak",
                "text": text,
            })

        elif cmd_type == "say_to":
            text = m.group(1)
            entity = m.group(2)
            target = _resolve_noun(entity, context)
            result["target"] = target
            result["trigger_actions"].append({
                "type": "speak",
                "text": text,
                "target": entity,
            })
            result["action_biases"]["approach"] = 0.3

        return result

    # No pattern matched — log and return empty
    log.warning(f"Unparseable command: {cmd_line!r}")
    return result


def parse_command_output(raw: str, context: dict) -> dict:
    """
    Parse full model output (think block + command) into thought loop result.

    Args:
        raw: Full model output including <think>...</think> and command line
        context: The thought context dict (for noun resolution)

    Returns:
        Dict compatible with thought loop protocol:
        {
            "thoughts": [str],         # inner monologue from think block
            "intentions": [dict],       # from command parsing
            "beliefs": [],              # commands don't generate beliefs
            "action_biases": {str: float},
            "trigger_actions": [dict],  # examine, speak
            "command": str,             # raw command for logging
            "target": dict | None,      # resolved noun
            "raw": str,                 # full raw output
        }
    """
    result = {
        "thoughts": [],
        "intentions": [],
        "beliefs": [],
        "action_biases": {},
        "trigger_actions": [],
        "command": "",
        "target": None,
        "raw": raw,
    }

    # Extract think block
    think_match = _THINK_RE.search(raw)
    if think_match:
        thought = think_match.group(1).strip()
        if thought:
            # Cap at 300 chars for display
            result["thoughts"].append(thought[:300])

    # Extract command — everything after </think>, first non-empty line
    cmd_text = ""
    if think_match:
        after_think = raw[think_match.end():].strip()
        cmd_text = after_think.split("\n")[0].strip() if after_think else ""
    else:
        # No think block — entire output is the command
        cmd_text = raw.strip().split("\n")[0].strip()

    if cmd_text:
        parsed = _parse_command_line(cmd_text, context)
        result["intentions"] = parsed["intentions"]
        result["action_biases"] = parsed["action_biases"]
        result["trigger_actions"] = parsed["trigger_actions"]
        result["command"] = parsed["command"]
        result["target"] = parsed["target"]

    return result
