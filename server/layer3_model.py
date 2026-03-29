"""
Layer 3 — Executive / Planning Model

Uses SmolLM2-1.7B-Instruct for:
- Daily agenda generation
- Short-horizon plan chunking
- Reflection over memory summaries
- Dialogue intent generation
- Social reasoning (bounded)

Uses outlines for guaranteed structured JSON output.
This model runs at slow cadence and outputs structured JSON.
"""

import torch
from pydantic import BaseModel
from transformers import AutoModelForCausalLM, AutoTokenizer
import outlines

# Town locations for structured planning
TOWN_LOCATIONS = {
    "bakery": {"tile": [53, 14], "type": "work", "public": False},
    "guard_post": {"tile": [86, 18], "type": "work", "public": True},
    "herbalist_shop": {"tile": [123, 57], "type": "work", "public": False},
    "courier_office": {"tile": [65, 19], "type": "work", "public": False},
    "blacksmith": {"tile": [20, 65], "type": "work", "public": True},
    "town_square": {"tile": [70, 50], "type": "public", "public": True},
    "market": {"tile": [57, 74], "type": "public", "public": True},
    "farm": {"tile": [36, 65], "type": "work", "public": False},
    "inn": {"tile": [93, 74], "type": "work", "public": True},
    "home_north": {"tile": [16, 18], "type": "home", "public": False},
    "home_east": {"tile": [16, 32], "type": "home", "public": False},
    "home_south": {"tile": [75, 74], "type": "home", "public": False},
    "home_west": {"tile": [25, 18], "type": "home", "public": False},
    "well": {"tile": [60, 45], "type": "public", "public": True},
    "road_east": {"tile": [130, 50], "type": "transit", "public": True},
    "road_south": {"tile": [70, 90], "type": "transit", "public": True},
}

# Role-based default schedules (fallback when model output has invalid locations)
DEFAULT_SCHEDULES = {
    "Baker": [
        {"location": "home_north", "duration": 1.0, "priority": 0.5, "purpose": "wake up and prepare"},
        {"location": "bakery", "duration": 4.0, "priority": 0.9, "purpose": "bake and sell bread"},
        {"location": "town_square", "duration": 1.0, "priority": 0.4, "purpose": "take a break"},
        {"location": "bakery", "duration": 3.0, "priority": 0.8, "purpose": "afternoon baking"},
        {"location": "market", "duration": 1.0, "priority": 0.5, "purpose": "buy supplies"},
        {"location": "home_north", "duration": 2.0, "priority": 0.7, "purpose": "rest at home"},
    ],
    "Guard": [
        {"location": "guard_post", "duration": 2.0, "priority": 0.9, "purpose": "morning patrol briefing"},
        {"location": "road_east", "duration": 2.0, "priority": 0.8, "purpose": "patrol east road"},
        {"location": "town_square", "duration": 1.0, "priority": 0.6, "purpose": "check town square"},
        {"location": "market", "duration": 1.0, "priority": 0.7, "purpose": "patrol market area"},
        {"location": "road_south", "duration": 2.0, "priority": 0.8, "purpose": "patrol south road"},
        {"location": "guard_post", "duration": 3.0, "priority": 0.9, "purpose": "evening watch"},
    ],
    "Herbalist": [
        {"location": "home_east", "duration": 1.0, "priority": 0.5, "purpose": "morning preparation"},
        {"location": "herbalist_shop", "duration": 4.0, "priority": 0.9, "purpose": "tend herbs and serve customers"},
        {"location": "farm", "duration": 1.5, "priority": 0.6, "purpose": "gather ingredients"},
        {"location": "herbalist_shop", "duration": 2.0, "priority": 0.8, "purpose": "prepare remedies"},
        {"location": "home_east", "duration": 2.0, "priority": 0.7, "purpose": "rest and study"},
    ],
    "Courier": [
        {"location": "courier_office", "duration": 1.0, "priority": 0.9, "purpose": "pick up deliveries"},
        {"location": "bakery", "duration": 0.5, "priority": 0.7, "purpose": "deliver to baker"},
        {"location": "blacksmith", "duration": 0.5, "priority": 0.7, "purpose": "deliver to blacksmith"},
        {"location": "inn", "duration": 0.5, "priority": 0.7, "purpose": "deliver to inn"},
        {"location": "town_square", "duration": 1.0, "priority": 0.4, "purpose": "rest in square"},
        {"location": "courier_office", "duration": 1.0, "priority": 0.8, "purpose": "afternoon pickups"},
        {"location": "herbalist_shop", "duration": 0.5, "priority": 0.7, "purpose": "deliver to herbalist"},
        {"location": "home_west", "duration": 2.0, "priority": 0.6, "purpose": "rest at home"},
    ],
    "Blacksmith": [
        {"location": "home_south", "duration": 1.0, "priority": 0.5, "purpose": "morning preparation"},
        {"location": "blacksmith", "duration": 5.0, "priority": 0.9, "purpose": "forge and repair"},
        {"location": "market", "duration": 1.0, "priority": 0.6, "purpose": "sell wares at market"},
        {"location": "inn", "duration": 1.5, "priority": 0.5, "purpose": "evening meal at inn"},
        {"location": "home_south", "duration": 2.0, "priority": 0.7, "purpose": "rest at home"},
    ],
    "Gossip": [
        {"location": "town_square", "duration": 2.0, "priority": 0.8, "purpose": "catch morning gossip"},
        {"location": "market", "duration": 2.0, "priority": 0.8, "purpose": "chat with merchants"},
        {"location": "bakery", "duration": 1.0, "priority": 0.6, "purpose": "visit baker for news"},
        {"location": "inn", "duration": 2.0, "priority": 0.7, "purpose": "lunch and rumors at inn"},
        {"location": "well", "duration": 1.5, "priority": 0.7, "purpose": "afternoon chat at well"},
        {"location": "home_west", "duration": 2.0, "priority": 0.6, "purpose": "rest at home"},
    ],
    "Farmer": [
        {"location": "farm", "duration": 4.0, "priority": 0.9, "purpose": "morning farm work"},
        {"location": "well", "duration": 0.5, "priority": 0.6, "purpose": "fetch water"},
        {"location": "farm", "duration": 3.0, "priority": 0.8, "purpose": "afternoon farm work"},
        {"location": "market", "duration": 1.0, "priority": 0.6, "purpose": "sell produce"},
        {"location": "inn", "duration": 1.0, "priority": 0.5, "purpose": "evening meal"},
        {"location": "home_south", "duration": 2.0, "priority": 0.7, "purpose": "rest at home"},
    ],
    "Innkeeper": [
        {"location": "inn", "duration": 2.0, "priority": 0.8, "purpose": "prepare inn for the day"},
        {"location": "market", "duration": 1.0, "priority": 0.6, "purpose": "buy supplies"},
        {"location": "inn", "duration": 6.0, "priority": 0.9, "purpose": "serve guests and manage inn"},
        {"location": "town_square", "duration": 1.0, "priority": 0.4, "purpose": "evening stroll"},
        {"location": "inn", "duration": 3.0, "priority": 0.9, "purpose": "evening service until late"},
    ],
}


# --- Output schemas for outlines structured generation ---

class PlanChunk(BaseModel):
    location: str
    duration: float
    priority: float
    purpose: str

class PlanOutput(BaseModel):
    agenda: list[PlanChunk]

class ReflectOutput(BaseModel):
    reflections: list[str]
    concerns: list[str]

class DialogueOutput(BaseModel):
    intent: str
    utterance: str

class ChatOutput(BaseModel):
    utterance: str
    mood_shift: str

class ConverseOutput(BaseModel):
    intent: str
    utterance: str
    topic: str


class Layer3Model:
    """Executive planning model using SmolLM2-1.7B-Instruct with outlines structured generation."""

    def __init__(self, model_name: str = "HuggingFaceTB/SmolLM2-1.7B-Instruct",
                 device: str = "cuda"):
        self.device = device
        self.model_name = model_name
        print(f"Layer3: Loading {model_name}...")
        self.tokenizer = AutoTokenizer.from_pretrained(model_name)
        hf_model = AutoModelForCausalLM.from_pretrained(
            model_name,
            torch_dtype=torch.float16,
            device_map=device
        )
        hf_model.eval()
        param_count = sum(p.numel() for p in hf_model.parameters())
        print(f"Layer3: Model loaded ({param_count / 1e6:.1f}M params)")

        # Wrap with outlines
        self._outlines_model = outlines.from_transformers(hf_model, self.tokenizer)

        # Pre-build generators for each output schema
        print("Layer3: Building structured generators...")
        self._plan_gen = outlines.Generator(self._outlines_model, output_type=PlanOutput)
        self._reflect_gen = outlines.Generator(self._outlines_model, output_type=ReflectOutput)
        self._dialogue_gen = outlines.Generator(self._outlines_model, output_type=DialogueOutput)
        self._chat_gen = outlines.Generator(self._outlines_model, output_type=ChatOutput)
        self._converse_gen = outlines.Generator(self._outlines_model, output_type=ConverseOutput)
        print("Layer3: Generators ready.")

    def _format_prompt(self, prompt: str) -> str:
        """Apply chat template to a single-turn prompt."""
        messages = [{"role": "user", "content": prompt}]
        return self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )

    def _format_chat(self, messages: list[dict]) -> str:
        """Apply chat template to multi-turn messages."""
        return self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )

    def plan(self, role: str, memory_summary: str, current_context: str,
             emotion_summary: str) -> dict:
        """
        Generate a daily agenda: list of plan chunks.
        Falls back to role-based default schedule if generated locations are invalid.
        """
        locations_list = ", ".join(TOWN_LOCATIONS.keys())

        prompt = self._format_prompt(
            f"You are a {role} NPC planning your day in a small medieval town.\n"
            f"Available locations: {locations_list}\n"
            f"Memory: {memory_summary}\n"
            f"Current state: {current_context}\n"
            f"Emotional state: {emotion_summary}\n\n"
            f"Create a daily plan as a JSON object with an 'agenda' array. Each item has:\n"
            f'- "location": one of the available locations\n'
            f'- "duration": hours (0.5-5.0)\n'
            f'- "priority": 0.0-1.0\n'
            f'- "purpose": short description\n\n'
            f"Output 4-6 plan chunks. Output ONLY the JSON object."
        )

        result = self._plan_gen(prompt, max_tokens=400, temperature=0.3)

        # Validate locations and clamp numeric ranges
        valid_chunks = []
        for chunk in result.agenda:
            if chunk.location in TOWN_LOCATIONS:
                valid_chunks.append({
                    "location": chunk.location,
                    "duration": max(0.5, min(5.0, chunk.duration)),
                    "priority": max(0.0, min(1.0, chunk.priority)),
                    "purpose": chunk.purpose[:80],
                })

        if len(valid_chunks) >= 3:
            return {"agenda": valid_chunks, "source": "model"}

        # Fallback to role-based default
        default = DEFAULT_SCHEDULES.get(role, DEFAULT_SCHEDULES["Farmer"])
        return {"agenda": list(default), "source": "default"}

    def reflect(self, memory_events: list[str]) -> dict:
        """Compress memory events into reflections and surface concerns."""
        if not memory_events:
            return {"reflections": [], "concerns": []}

        events_str = "\n".join(f"- {e}" for e in memory_events[-10:])
        prompt = self._format_prompt(
            f"You are an NPC reflecting on recent events.\n"
            f"Events:\n{events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "reflections": array of 1-3 short summary sentences\n'
            f'- "concerns": array of 0-2 unresolved issues\n\n'
            f"Output ONLY valid JSON."
        )

        result = self._reflect_gen(prompt, max_tokens=200, temperature=0.3)
        return {
            "reflections": [r[:100] for r in result.reflections],
            "concerns": [c[:100] for c in result.concerns],
        }

    def dialogue(self, role: str, emotion_summary: str,
                 relationship_context: str, recent_events: list[str]) -> dict:
        """Generate dialogue intent and utterance for player interaction."""
        events_str = "; ".join(recent_events[-3:]) if recent_events else "nothing notable"

        prompt = self._format_prompt(
            f"You are a {role} NPC in a medieval town. A player approaches you.\n"
            f"Your emotional state: {emotion_summary}\n"
            f"Relationship with player: {relationship_context}\n"
            f"Recent events: {events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "intent": one word (greet, warn, complain, thank, refuse, ask, inform, dismiss)\n'
            f'- "utterance": one short sentence (max 15 words) in character\n\n'
            f"Output ONLY valid JSON."
        )

        result = self._dialogue_gen(prompt, max_tokens=60, temperature=0.4)
        return {
            "intent": result.intent[:20],
            "utterance": result.utterance[:100],
        }

    def chat(self, role: str, npc_name: str, emotion_summary: str,
             relationship_context: str, recent_events: list[str],
             conversation_history: list[dict], player_message: str) -> dict:
        """
        Generate NPC reply to player's typed message in a back-and-forth conversation.
        Uses proper multi-turn chat template.
        """
        events_str = "; ".join(recent_events[-3:]) if recent_events else "nothing notable"

        system_context = (
            f"You are {npc_name}, a {role} in a medieval town. "
            f"You feel {emotion_summary}. You know: {events_str}. "
            f"Reply in character as {npc_name}. One or two sentences max. "
            f"Output JSON: {{\"utterance\": \"your reply\", \"mood_shift\": \"one word\"}}"
        )

        messages = [{"role": "user", "content": system_context}]
        messages.append({"role": "assistant", "content": f'{{"utterance": "I am {npc_name} the {role}.", "mood_shift": "neutral"}}'})

        for msg in conversation_history[-4:]:
            if msg["speaker"] == "Player":
                messages.append({"role": "user", "content": msg["text"]})
            else:
                messages.append({"role": "assistant", "content": f'{{"utterance": "{msg["text"]}", "mood_shift": "neutral"}}'})

        messages.append({"role": "user", "content": player_message})

        prompt = self._format_chat(messages)
        result = self._chat_gen(prompt, max_tokens=80, temperature=0.5)
        return {
            "utterance": result.utterance[:150],
            "mood_shift": result.mood_shift[:20],
        }

    def converse(self, speaker_role: str, speaker_emotion: str,
                 listener_role: str, listener_emotion: str,
                 shared_context: str, speaker_recent: list[str]) -> dict:
        """
        Generate NPC-to-NPC conversation: speaker says something to listener.
        """
        events_str = "; ".join(speaker_recent[-3:]) if speaker_recent else "nothing notable"

        prompt = self._format_prompt(
            f"You are a {speaker_role} NPC talking to a {listener_role} in a medieval town.\n"
            f"Your emotional state: {speaker_emotion}\n"
            f"The {listener_role} seems: {listener_emotion}\n"
            f"Context: {shared_context}\n"
            f"Things you know: {events_str}\n\n"
            f"Output a JSON object with:\n"
            f'"intent": one word (gossip, warn, greet, ask, complain, share, joke, inform)\n'
            f'"utterance": one short sentence (max 15 words) spoken to the {listener_role}\n'
            f'"topic": what you are talking about in 5 words or less\n\n'
            f"Output ONLY valid JSON."
        )

        result = self._converse_gen(prompt, max_tokens=80, temperature=0.5)
        return {
            "intent": result.intent[:20],
            "utterance": result.utterance[:100],
            "topic": result.topic[:50],
        }

    def get_location_tile(self, location_name: str) -> list[int] | None:
        """Get tile coordinates for a named location."""
        loc = TOWN_LOCATIONS.get(location_name)
        return loc["tile"] if loc else None
