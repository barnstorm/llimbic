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
        Uses defaults normally; triggers LLM replanning when state warrants it.
        Falls back to role-based default schedule if model output is unparseable.
        """
        default = DEFAULT_SCHEDULES.get(role, DEFAULT_SCHEDULES["Farmer"])

        # Determine if state warrants LLM replanning
        should_replan = False
        mem_lower = memory_summary.lower()
        emo_lower = emotion_summary.lower()
        if "concern" in mem_lower or "worried" in mem_lower:
            should_replan = True
        if "frustrat" in emo_lower or "distress" in emo_lower:
            should_replan = True
        if "frustration is high" in mem_lower:
            should_replan = True
        if "multiple recent failures" in mem_lower:
            should_replan = True

        if not should_replan:
            return {"agenda": list(default), "source": "default"}

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

        raw = self._generate(prompt, max_new_tokens=300, temperature=0.3)

        try:
            json_match = re.search(r'\[[\s\S]*\]', raw)
            if json_match:
                agenda = json.loads(json_match.group())
                # Validate: must be a list of dicts with valid location keys
                valid = True
                for chunk in agenda:
                    if not isinstance(chunk, dict):
                        valid = False
                        break
                    loc = chunk.get("location", "")
                    if loc not in TOWN_LOCATIONS:
                        valid = False
                        break
                    # Ensure required fields exist with sane defaults
                    chunk.setdefault("duration", 1.0)
                    chunk.setdefault("priority", 0.5)
                    chunk.setdefault("purpose", "task")
                    chunk["duration"] = max(0.5, min(5.0, float(chunk["duration"])))
                    chunk["priority"] = max(0.0, min(1.0, float(chunk["priority"])))
                if valid and len(agenda) >= 3:
                    return {"agenda": agenda, "source": "llm"}
        except (json.JSONDecodeError, ValueError):
            pass

        return {"agenda": list(default), "source": "default"}

    def reflect(self, memory_events: list[str]) -> dict:
        """
        Compress memory events into reflections and surface concerns.
        """
        if not memory_events:
            return {"reflections": [], "concerns": []}

        events_str = "\n".join(f"- {e}" for e in memory_events[-10:])
        prompt = (
            f"Summarize these events from a townsperson's perspective.\n"
            f"Events:\n{events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "reflections": array of 1-3 short summary sentences about what happened\n'
            f'- "concerns": array of 0-2 unresolved issues that would worry someone\n\n'
            f"Output ONLY valid JSON."
        )

        raw = self._generate(prompt, max_new_tokens=80, temperature=0.3)

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
            f"Write one line of dialogue for a {role} in a medieval fantasy town. "
            f"A traveler just approached them.\n"
            f"The {role} feels: {emotion_summary}\n"
            f"Relationship with traveler: {relationship_context}\n"
            f"Recent events: {events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "intent": one word (greet, warn, complain, thank, refuse, ask, inform, dismiss)\n'
            f'- "utterance": one short sentence (max 15 words) spoken in character as the {role}\n\n'
            f"Never mention AI or break character. Output ONLY valid JSON."
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

    def chat(self, role: str, npc_name: str, emotion_summary: str,
             relationship_context: str, recent_events: list[str],
             conversation_history: list[dict], player_message: str) -> dict:
        """
        Generate NPC reply to player's typed message in a back-and-forth conversation.
        Uses proper multi-turn chat template instead of single-message prompt.
        """
        events_str = "; ".join(recent_events[-3:]) if recent_events else "nothing notable"

        # Build the full context as a single prompt with embedded dialogue,
        # so the model never sees raw "user" messages that trigger assistant mode.
        dialogue_lines = []
        for msg in conversation_history[-4:]:
            if msg["speaker"] == "Player":
                dialogue_lines.append(f'Traveler: "{msg["text"]}"')
            else:
                dialogue_lines.append(f'{npc_name}: "{msg["text"]}"')
        dialogue_lines.append(f'Traveler: "{player_message}"')
        dialogue_str = "\n".join(dialogue_lines)

        prompt = (
            f"You are writing dialogue for {npc_name}, a {role} in a medieval fantasy town. "
            f"{npc_name} is a real person in this world — not an AI, not a computer program, not a bot. "
            f"{npc_name} has a physical body, lives in the town, and does {role.lower()} work every day.\n\n"
            f"{npc_name} currently feels: {emotion_summary}\n"
            f"{npc_name} knows: {events_str}\n"
            f"Relationship with this traveler: {relationship_context}\n\n"
            f"Conversation so far:\n{dialogue_str}\n\n"
            f"Write {npc_name}'s next reply. Stay in character. One or two sentences max. "
            f"If the traveler asks {npc_name} to do something physical, {npc_name} can agree or refuse as a real person would. "
            f"Never mention AI, models, programs, or break character.\n\n"
            f'Output ONLY a JSON object: {{"utterance": "what {npc_name} says", "mood_shift": "one word"}}'
        )

        messages = [{"role": "user", "content": prompt}]

        # Generate using chat template with multi-turn
        text = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self.tokenizer(text, return_tensors="pt").to(self.device)
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=50,
                temperature=0.5,
                do_sample=True,
                top_p=0.9,
                repetition_penalty=1.2,
                pad_token_id=self.tokenizer.eos_token_id,
            )
        generated = outputs[0][inputs["input_ids"].shape[1]:]
        raw = self.tokenizer.decode(generated, skip_special_tokens=True).strip()

        try:
            json_match = re.search(r'\{[^{}]*\}', raw)
            if json_match:
                data = json.loads(json_match.group())
                return {
                    "utterance": str(data.get("utterance", "Hmm, I see."))[:150],
                    "mood_shift": str(data.get("mood_shift", "neutral"))[:20],
                }
        except (json.JSONDecodeError, ValueError):
            pass

        # Fallback — acknowledge what the player said
        fallbacks = [
            f"I hear you. Things have been busy at the {role.lower()}'s.",
            "Interesting... I'll keep that in mind.",
            f"As a {role.lower()}, I've seen a lot. But go on.",
            "Hmm, is that so?",
        ]
        import random
        return {
            "utterance": random.choice(fallbacks),
            "mood_shift": "neutral",
        }

    def converse(self, speaker_role: str, speaker_emotion: str,
                 listener_role: str, listener_emotion: str,
                 shared_context: str, speaker_recent: list[str]) -> dict:
        """
        Generate NPC-to-NPC conversation: speaker says something to listener.
        Returns intent, utterance, and optional topic (event being shared).
        """
        events_str = "; ".join(speaker_recent[-3:]) if speaker_recent else "nothing notable"

        prompt = (
            f"Write one line of dialogue for a {speaker_role} talking to a {listener_role} in a medieval town.\n"
            f"The {speaker_role} feels: {speaker_emotion}\n"
            f"The {listener_role} seems: {listener_emotion}\n"
            f"Context: {shared_context}\n"
            f"The {speaker_role} knows: {events_str}\n\n"
            f"Output a JSON object with:\n"
            f'"intent": one word (gossip, warn, greet, ask, complain, share, joke, inform)\n'
            f'"utterance": one short sentence (max 15 words) spoken in character as the {speaker_role}\n'
            f'"topic": what they are talking about in 5 words or less\n\n'
            f"Never mention AI or break character. Output ONLY valid JSON."
        )

        raw = self._generate(prompt, max_new_tokens=80, temperature=0.5)

        try:
            json_match = re.search(r'\{[^{}]*\}', raw)
            if json_match:
                data = json.loads(json_match.group())
                return {
                    "intent": str(data.get("intent", "greet"))[:20],
                    "utterance": str(data.get("utterance", "Good day."))[:100],
                    "topic": str(data.get("topic", "small talk"))[:50],
                }
        except (json.JSONDecodeError, ValueError):
            pass

        # Fallback based on role combinations
        fallbacks = {
            "Gossip": f"Did you hear what happened at the {listener_role.lower()}'s place?",
            "Guard": f"Keep your eyes open, {listener_role}.",
            "Baker": f"Want some bread, {listener_role}?",
            "Farmer": "Weather's been good for the crops.",
            "Innkeeper": "Business has been steady lately.",
            "Courier": "I've got news from the road.",
            "Herbalist": "The herbs are growing well this season.",
            "Blacksmith": "I've been busy at the forge.",
        }
        return {
            "intent": "greet",
            "utterance": fallbacks.get(speaker_role, f"Hello, {listener_role}."),
            "topic": "small talk",
        }

    def get_location_tile(self, location_name: str) -> list[int] | None:
        """Get tile coordinates for a named location."""
        loc = TOWN_LOCATIONS.get(location_name)
        return loc["tile"] if loc else None
