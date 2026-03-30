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


def build_listener_context(persona: dict) -> str:
    """Short description of a listener NPC for conversation prompts."""
    name = persona.get("name", "someone")
    role = persona.get("role", "villager")
    p = persona.get("personality", {})
    traits = ", ".join(p.get("traits", [])[:2]) or "quiet"
    return f"{name}, a {traits} {role}"
