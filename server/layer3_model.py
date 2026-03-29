"""
Layer 3 — Executive / Planning Model

Uses SmolLM2-135M-Instruct for:
- Daily agenda generation
- Short-horizon plan chunking
- Reflection over memory summaries
- Dialogue intent generation
- Social reasoning (bounded)

This model must NOT be used for continuous control, per-frame decisions,
or low-level behavior. It runs at slow cadence and outputs structured JSON.
"""

import torch
import json
import re
from transformers import AutoModelForCausalLM, AutoTokenizer

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

# Role-based default schedules (fallback when model output is poor)
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


class Layer3Model:
    """Executive planning model using SmolLM2-135M-Instruct."""

    def __init__(self, model_name: str = "HuggingFaceTB/SmolLM2-135M-Instruct",
                 device: str = "cuda"):
        self.device = device
        self.model_name = model_name
        print(f"Layer3: Loading {model_name}...")
        self.tokenizer = AutoTokenizer.from_pretrained(model_name)
        self.model = AutoModelForCausalLM.from_pretrained(
            model_name,
            torch_dtype=torch.float16,
            device_map=device
        )
        self.model.eval()
        param_count = sum(p.numel() for p in self.model.parameters())
        print(f"Layer3: Model loaded ({param_count / 1e6:.1f}M params)")

    def _generate(self, prompt: str, max_new_tokens: int = 300,
                  temperature: float = 0.3) -> str:
        """Generate structured text from prompt."""
        messages = [
            {"role": "user", "content": prompt}
        ]
        text = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self.tokenizer(text, return_tensors="pt").to(self.device)
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_new_tokens,
                temperature=max(temperature, 0.01),
                do_sample=temperature > 0.05,
                top_p=0.9,
                repetition_penalty=1.1,
                pad_token_id=self.tokenizer.eos_token_id,
            )
        generated = outputs[0][inputs["input_ids"].shape[1]:]
        return self.tokenizer.decode(generated, skip_special_tokens=True).strip()

    def plan(self, role: str, memory_summary: str, current_context: str,
             emotion_summary: str) -> dict:
        """
        Generate a daily agenda: list of plan chunks.
        Falls back to role-based default schedule if model output is unparseable.
        """
        locations_list = ", ".join(TOWN_LOCATIONS.keys())

        prompt = (
            f"You are a {role} NPC planning your day in a small medieval town.\n"
            f"Available locations: {locations_list}\n"
            f"Memory: {memory_summary}\n"
            f"Current state: {current_context}\n"
            f"Emotional state: {emotion_summary}\n\n"
            f"Create a daily plan as a JSON array of objects. Each object has:\n"
            f'- "location": one of the available locations\n'
            f'- "duration": hours (0.5-5.0)\n'
            f'- "priority": 0.0-1.0\n'
            f'- "purpose": short description\n\n'
            f"Output 4-6 plan chunks. Output ONLY the JSON array."
        )

        raw = self._generate(prompt, max_new_tokens=400, temperature=0.3)

        # Try to parse model output
        try:
            # Find JSON array in output
            array_match = re.search(r'\[[\s\S]*?\]', raw)
            if array_match:
                chunks = json.loads(array_match.group())
                # Validate chunks
                valid_chunks = []
                for chunk in chunks:
                    if isinstance(chunk, dict) and "location" in chunk:
                        loc = chunk["location"]
                        if loc in TOWN_LOCATIONS:
                            valid_chunks.append({
                                "location": loc,
                                "duration": max(0.5, min(5.0, float(chunk.get("duration", 1.0)))),
                                "priority": max(0.0, min(1.0, float(chunk.get("priority", 0.5)))),
                                "purpose": str(chunk.get("purpose", ""))[:80],
                            })
                if len(valid_chunks) >= 3:
                    return {"agenda": valid_chunks, "source": "model"}
        except (json.JSONDecodeError, ValueError, TypeError):
            pass

        # Fallback to role-based default
        default = DEFAULT_SCHEDULES.get(role, DEFAULT_SCHEDULES["Farmer"])
        return {"agenda": list(default), "source": "default"}

    def reflect(self, memory_events: list[str]) -> dict:
        """
        Compress memory events into reflections and surface concerns.
        """
        if not memory_events:
            return {"reflections": [], "concerns": []}

        events_str = "\n".join(f"- {e}" for e in memory_events[-10:])
        prompt = (
            f"You are an NPC reflecting on recent events.\n"
            f"Events:\n{events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "reflections": array of 1-3 short summary sentences\n'
            f'- "concerns": array of 0-2 unresolved issues\n\n'
            f"Output ONLY valid JSON."
        )

        raw = self._generate(prompt, max_new_tokens=200, temperature=0.3)

        try:
            json_match = re.search(r'\{[\s\S]*\}', raw)
            if json_match:
                data = json.loads(json_match.group())
                return {
                    "reflections": [str(r)[:100] for r in data.get("reflections", [])],
                    "concerns": [str(c)[:100] for c in data.get("concerns", [])],
                }
        except (json.JSONDecodeError, ValueError):
            pass

        return {"reflections": ["Things have been uneventful."], "concerns": []}

    def dialogue(self, role: str, emotion_summary: str,
                 relationship_context: str, recent_events: list[str]) -> dict:
        """
        Generate dialogue intent and utterance for player interaction.
        """
        events_str = "; ".join(recent_events[-3:]) if recent_events else "nothing notable"

        prompt = (
            f"You are a {role} NPC in a medieval town. A player approaches you.\n"
            f"Your emotional state: {emotion_summary}\n"
            f"Relationship with player: {relationship_context}\n"
            f"Recent events: {events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "intent": one word (greet, warn, complain, thank, refuse, ask, inform, dismiss)\n'
            f'- "utterance": one short sentence (max 15 words) in character\n\n'
            f"Output ONLY valid JSON."
        )

        raw = self._generate(prompt, max_new_tokens=60, temperature=0.4)

        try:
            json_match = re.search(r'\{[^{}]*\}', raw)
            if json_match:
                data = json.loads(json_match.group())
                return {
                    "intent": str(data.get("intent", "greet"))[:20],
                    "utterance": str(data.get("utterance", "Hello there."))[:100],
                }
        except (json.JSONDecodeError, ValueError):
            pass

        # Role-based fallback
        fallbacks = {
            "Baker": {"intent": "greet", "utterance": "Fresh bread today! What can I get you?"},
            "Guard": {"intent": "inform", "utterance": "All quiet on the roads today."},
            "Herbalist": {"intent": "greet", "utterance": "Looking for remedies? I have some fresh herbs."},
            "Courier": {"intent": "greet", "utterance": "Can't stop long, deliveries to make!"},
            "Blacksmith": {"intent": "greet", "utterance": "Need something repaired? I'm your smith."},
            "Gossip": {"intent": "inform", "utterance": "Oh, have you heard the latest?"},
            "Farmer": {"intent": "greet", "utterance": "Good day! The crops are coming in well."},
            "Innkeeper": {"intent": "greet", "utterance": "Welcome! Pull up a chair."},
        }
        return fallbacks.get(role, {"intent": "greet", "utterance": "Hello there."})

    def get_location_tile(self, location_name: str) -> list[int] | None:
        """Get tile coordinates for a named location."""
        loc = TOWN_LOCATIONS.get(location_name)
        return loc["tile"] if loc else None
