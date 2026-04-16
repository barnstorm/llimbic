"""
Prompt builder — constructs persona preambles for Layer 3 LLM calls.
Every L3 prompt gets a consistent character grounding.
"""


def build_preamble(persona: dict, emotion_state: str = "",
                   current_activity: str = "", location: str = "",
                   recent_events: list[str] | None = None,
                   object_context: str = "") -> str:
    """Build a persona preamble string for an LLM prompt."""
    name = persona.get("name", "Unknown")
    role = persona.get("role", "Villager")
    p = persona.get("personality", {})
    traits = ", ".join(p.get("traits", ["quiet"]))
    speech = p.get("speech_style", "neutral")
    backstory = p.get("backstory", "A resident of the town.")

    lines = [
        f"You are {name}, the {role} of a small medieval town.",
        f"Personality: {traits}.",
        f"Speech: {speech}.",
        f"Background: {backstory}",
    ]

    if emotion_state:
        lines.append(f"\nRight now you feel: {emotion_state}.")
    if current_activity:
        lines.append(f"You are currently: {current_activity}.")
    if location:
        lines.append(f"Location: {location}.")
    if object_context:
        lines.append(f"Notable objects: {object_context}.")
    if recent_events:
        event_lines = "\n".join(f"- {e}" for e in recent_events[-5:])
        lines.append(f"\nRecent events you remember:\n{event_lines}")

    lines.append(
        "\nRules: Reference specific details from your situation and memories. "
        "No generic pleasantries like 'How are you?' or 'Good to see you'. "
        "Stay in character. You are a real person, not an AI."
    )

    return "\n".join(lines)


def _build_townsfolk_line(persona: dict, packet: dict) -> str:
    """Build a compact line listing who this NPC knows in town."""
    from persona_loader import load_all_personas
    all_personas = load_all_personas()
    name = persona.get("name", "")

    # Build role lookup from all personas (dict: name -> persona_dict)
    role_by_name = {}
    for pname, pdata in all_personas.items():
        role_by_name[pname] = pdata.get("role", "villager")

    # Known people from packet (with trust) + all townspeople they'd know
    known = packet.get("known_people", [])
    known_names = {p.get("name", "") for p in known}

    parts = []
    for p in known:
        pname = p.get("name", "")
        if pname == "Player":
            continue  # handled separately in the prompt
        trust = p.get("trust", 0.5)
        prole = role_by_name.get(pname, "")
        rel = "close" if trust > 0.6 else "friendly" if trust > 0.4 else "wary of"
        if prole:
            parts.append(f"{pname} the {prole} ({rel})")
        else:
            parts.append(f"{pname} ({rel})")

    # Add other townspeople they'd know by sight (small town)
    for pname, pdata in all_personas.items():
        if pname and pname != name and pname not in known_names:
            prole = pdata.get("role", "")
            parts.append(f"{pname} the {prole}")

    return "Townsfolk you know: " + ", ".join(parts) + "." if parts else ""


def build_preamble_from_packet(persona: dict, packet: dict) -> str:
    """Build a compact preamble from a structured packet instead of prose strings."""
    name = persona.get("name", "Unknown")
    role = persona.get("role", "Villager")
    p = persona.get("personality", {})
    traits = ", ".join(p.get("traits", ["quiet"]))
    speech = p.get("speech_style", "neutral")
    backstory = p.get("backstory", "A resident of the town.")

    lines = [
        f"You are {name}, the {role} of a small medieval town.",
        f"Personality: {traits}. Speech: {speech}.",
        f"Background: {backstory}",
    ]

    # Townsfolk — who this NPC knows
    townsfolk = _build_townsfolk_line(persona, packet)
    if townsfolk:
        lines.append(townsfolk)

    # Emotions — compact format from top_emotions list
    emotions = packet.get("top_emotions", [])
    if emotions:
        emo_str = ", ".join(f"{e['name']} ({e['value']:.1f})" for e in emotions[:3])
        lines.append(f"Feeling: {emo_str}.")

    # Location
    loc = packet.get("current_location", "")
    if loc:
        lines.append(f"Location: {loc}.")

    # Current activity from chunk
    chunk = packet.get("current_chunk", {})
    if chunk:
        purpose = chunk.get("purpose", "")
        if purpose:
            lines.append(f"Currently: {purpose}.")

    # Concerns — already capped by packet builder
    concerns = packet.get("concerns", [])
    if concerns:
        lines.append(f"Worried about: {'; '.join(concerns)}.")

    # Problem objects — already capped
    problems = packet.get("problem_objects", [])
    if problems:
        prob_strs = [f"{p['name']} at {p['location']} is {p['state']}" for p in problems]
        lines.append(f"Problems: {'; '.join(prob_strs)}.")

    # Notable objects for dialogue
    notable = packet.get("notable_objects", [])
    if notable:
        obj_strs = [f"{o['name']} at {o['location']} is {o['state']}" for o in notable]
        lines.append(f"Notable: {'; '.join(obj_strs)}.")

    # Events — already capped and ranked
    events = packet.get("salient_events", packet.get("recent_relevant_events", []))
    if events:
        lines.append("Recent:")
        for e in events[:4]:
            text = e.get("text", "")
            if text:
                lines.append(f"- {text}")

    # Perception — what the NPC can actually see right now
    perception = packet.get("perception", "")
    if perception:
        lines.append(f"\n{perception}")

    # Current thought from thought loop
    current_thought = packet.get("current_thought", "")
    if current_thought:
        lines.append(f"You were just thinking: \"{current_thought}\"")

    lines.append(
        "\nRules: Only describe what you can actually see and hear. "
        "Do not invent furniture, weather, smells, or scenery not mentioned above. "
        "No generic pleasantries. Stay in character. You are a real person, not an AI."
    )

    return "\n".join(lines)


def build_listener_context(persona: dict) -> str:
    """Short description of a listener NPC for conversation prompts."""
    name = persona.get("name", "someone")
    role = persona.get("role", "villager")
    p = persona.get("personality", {})
    traits = ", ".join(p.get("traits", [])[:2]) or "quiet"
    return f"{name}, a {traits} {role}"
