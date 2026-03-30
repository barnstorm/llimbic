"""
Layer 3 — Executive / Planning Model

Uses SmolLM2-1.7B-Instruct for:
- Daily agenda generation
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

from persona_loader import load_all_personas, get_persona_by_role, get_persona_by_name, load_locations, get_fallback_dialogue
from prompt_builder import build_preamble, build_listener_context


class Layer3Model:
    """Executive planning model using SmolLM2-1.7B-Instruct."""

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

        # Load persona and location data
        self.personas = load_all_personas()
        self.locations = load_locations()
        print(f"Layer3: Loaded {len(self.personas)} personas, {len(self.locations)} locations")

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

    def _get_persona(self, npc_name: str = "", role: str = "") -> dict:
        """Look up persona by name first, then role, then empty fallback."""
        if npc_name:
            p = get_persona_by_name(npc_name)
            if p:
                return p
        if role:
            p = get_persona_by_role(role)
            if p:
                return p
        return {"name": npc_name or "Unknown", "role": role or "Villager"}

    def _get_default_schedule(self, persona: dict) -> list[dict]:
        """Get default schedule from persona data."""
        return persona.get("schedule", [
            {"location": "town_square", "duration": 4.0, "priority": 0.5, "purpose": "idle"}
        ])

    def plan(self, role: str, memory_summary: str, current_context: str,
             emotion_summary: str, npc_name: str = "") -> dict:
        """
        Generate a daily agenda: list of plan chunks.
        Uses persona defaults normally; triggers LLM replanning when state warrants it.
        """
        persona = self._get_persona(npc_name, role)
        default = self._get_default_schedule(persona)

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
        if "urgent:" in mem_lower:
            should_replan = True

        if not should_replan:
            return {"agenda": list(default), "source": "default"}

        locations_list = ", ".join(self.locations.keys())

        preamble = build_preamble(persona, emotion_summary, current_context)
        prompt = (
            f"{preamble}\n\n"
            f"Plan your day given your current state.\n"
            f"Available locations: {locations_list}\n"
            f"Memory: {memory_summary}\n\n"
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
                valid = True
                for chunk in agenda:
                    if not isinstance(chunk, dict):
                        valid = False
                        break
                    loc = chunk.get("location", "")
                    if loc not in self.locations:
                        valid = False
                        break
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

    def reflect(self, memory_events: list[str], npc_name: str = "",
                role: str = "") -> dict:
        """Compress memory events into reflections and surface concerns."""
        if not memory_events:
            return {"reflections": [], "concerns": []}

        persona = self._get_persona(npc_name, role)
        name = persona.get("name", "A townsperson")

        events_str = "\n".join(f"- {e}" for e in memory_events[-10:])
        prompt = (
            f"Summarize these events from {name}'s perspective. "
            f"{name} is a {persona.get('role', 'villager')}.\n"
            f"Events:\n{events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "reflections": array of 1-3 short summary sentences about what happened\n'
            f'- "concerns": array of 0-2 unresolved issues that would worry {name}\n\n'
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
                 relationship_context: str, recent_events: list[str],
                 npc_name: str = "") -> dict:
        """Generate dialogue intent and utterance for player interaction."""
        persona = self._get_persona(npc_name, role)

        preamble = build_preamble(
            persona, emotion_summary,
            current_activity="", location="",
            recent_events=recent_events
        )
        prompt = (
            f"{preamble}\n\n"
            f"A traveler just approached you.\n"
            f"Relationship with traveler: {relationship_context}\n\n"
            f"Output a JSON object with:\n"
            f'- "intent": one word (greet, warn, complain, thank, refuse, ask, inform, dismiss)\n'
            f'- "utterance": one short sentence (max 15 words) spoken as {persona.get("name", role)}\n\n'
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

        fb = get_fallback_dialogue(role)
        return {"intent": "greet", "utterance": fb.get("greeting", "Hello there.")}

    def chat(self, role: str, npc_name: str, emotion_summary: str,
             relationship_context: str, recent_events: list[str],
             conversation_history: list[dict], player_message: str) -> dict:
        """Generate NPC reply to player's typed message."""
        persona = self._get_persona(npc_name, role)
        name = persona.get("name", npc_name)

        preamble = build_preamble(
            persona, emotion_summary,
            recent_events=recent_events
        )

        # Embed dialogue as narrative text (not user/assistant turns)
        dialogue_lines = []
        for msg in conversation_history[-4:]:
            if msg["speaker"] == "Player":
                dialogue_lines.append(f'Traveler: "{msg["text"]}"')
            else:
                dialogue_lines.append(f'{name}: "{msg["text"]}"')
        dialogue_lines.append(f'Traveler: "{player_message}"')
        dialogue_str = "\n".join(dialogue_lines)

        prompt = (
            f"{preamble}\n\n"
            f"Relationship with this traveler: {relationship_context}\n\n"
            f"Conversation so far:\n{dialogue_str}\n\n"
            f"Write {name}'s next reply. Stay in character. One or two sentences max.\n\n"
            f'Output ONLY a JSON object: {{"utterance": "what {name} says", "mood_shift": "one word"}}'
        )

        messages = [{"role": "user", "content": prompt}]
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

        # Persona-driven fallback instead of generic boilerplate
        fb = get_fallback_dialogue(role)
        return {
            "utterance": fb.get("busy", f"Things have been busy at the {role.lower()}'s."),
            "mood_shift": "neutral",
        }

    def converse(self, speaker_role: str, speaker_emotion: str,
                 listener_role: str, listener_emotion: str,
                 shared_context: str, speaker_recent: list[str],
                 speaker_name: str = "", listener_name: str = "") -> dict:
        """Generate NPC-to-NPC conversation."""
        speaker_persona = self._get_persona(speaker_name, speaker_role)
        listener_persona = self._get_persona(listener_name, listener_role)

        preamble = build_preamble(
            speaker_persona, speaker_emotion,
            current_activity=shared_context,
            recent_events=speaker_recent
        )
        listener_desc = build_listener_context(listener_persona)

        prompt = (
            f"{preamble}\n\n"
            f"You are talking to {listener_desc}, who seems: {listener_emotion}.\n\n"
            f"Say ONE line referencing something specific from your situation or memories.\n"
            f"BAD: \"How are you?\", \"Good to see you\", \"Interesting...\"\n"
            f"GOOD: \"That oven's been cold all morning\", \"The pantry's empty again\"\n\n"
            f"Output a JSON object with:\n"
            f'"intent": one word (gossip, warn, greet, ask, complain, share, joke, inform)\n'
            f'"utterance": one short sentence (max 15 words)\n'
            f'"topic": what you are talking about in 5 words or less\n\n'
            f"Output ONLY valid JSON."
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

        fb = get_fallback_dialogue(speaker_role)
        return {
            "intent": "greet",
            "utterance": fb.get("gossip", f"Hello, {listener_persona.get('name', listener_role)}."),
            "topic": "small talk",
        }

    def get_location_tile(self, location_name: str) -> list[int] | None:
        """Get tile coordinates for a named location."""
        loc = self.locations.get(location_name)
        if loc:
            return loc.get("tile")
        return None
