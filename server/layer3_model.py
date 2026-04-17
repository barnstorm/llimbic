"""
Layer 3 — Executive / Planning Model

Uses SmolLM3-3B (base, via llama-server on port 8424) for:
- Daily agenda generation
- Reflection over memory summaries
- Dialogue intent generation
- Player chat (multi-turn)
- NPC-to-NPC conversation
- Social reasoning (bounded)

Thought loop (generate_thought) delegates to CommandModel — a fine-tuned
SmolLM3-3B served via llama-server on port 8423.

Both instances use the same GGUF weights. The command model is fine-tuned
for <think> + adventure commands. This model uses the base SmolLM3 for
general chat/planning via raw chatml /completion.
"""

import os
import subprocess
import time
import json
import re
import logging
import requests

from persona_loader import load_all_personas, get_persona_by_role, get_persona_by_name, load_locations, get_fallback_dialogue
from prompt_builder import build_preamble, build_preamble_from_packet, build_listener_context

log = logging.getLogger("layer3")

CHAT_SERVER_PORT = 8424


class Layer3Model:
    """Executive planning model using SmolLM3-3B via llama-server."""

    def __init__(self, gguf_path: str | None = None, command_model=None):
        self.model_name = "SmolLM3-3B-chat"
        self._command_model = command_model

        server_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(server_dir)

        if gguf_path is None:
            gguf_path = os.path.join(
                project_root, "training", "cognitive",
                "SmolLM3-3B.Q4_K_M.gguf"
            )
        self.gguf_path = gguf_path

        if not os.path.exists(self.gguf_path):
            raise FileNotFoundError(f"Chat GGUF not found: {self.gguf_path}")

        # Find llama-server binary
        self._llama_bin = None
        for candidate in [
            "/tmp/llama.cpp/build/bin/llama-server",
            os.path.join(project_root, "llama-server"),
        ]:
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                self._llama_bin = candidate
                break

        if self._llama_bin is None:
            raise FileNotFoundError("llama-server binary not found")

        self._proc = None
        self._start_server()

        # Load persona and location data
        self.personas = load_all_personas()
        self.locations = load_locations()
        print(f"Layer3: Loaded {len(self.personas)} personas, {len(self.locations)} locations")

    def _start_server(self):
        log.info(f"Layer3: Starting llama-server (chat) on port {CHAT_SERVER_PORT}...")
        self._proc = subprocess.Popen(
            [
                self._llama_bin,
                "-m", self.gguf_path,
                "--port", str(CHAT_SERVER_PORT),
                "--ctx-size", "2048",
                "-t", "8",
                "-np", "2",
                "--log-disable",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(30):
            try:
                r = requests.get(
                    f"http://127.0.0.1:{CHAT_SERVER_PORT}/health",
                    timeout=1,
                )
                if r.status_code == 200:
                    log.info(
                        f"Layer3: llama-server (chat) ready "
                        f"(SmolLM3-3B Q4_K_M, port {CHAT_SERVER_PORT})"
                    )
                    return
            except requests.ConnectionError:
                pass
            time.sleep(1)
        raise RuntimeError(
            f"Layer3 chat llama-server failed to start on port {CHAT_SERVER_PORT}"
        )

    def __del__(self):
        if hasattr(self, '_proc') and self._proc and self._proc.poll() is None:
            self._proc.terminate()

    def _generate(self, prompt: str, max_new_tokens: int = 300,
                  temperature: float = 0.3, system: str = "") -> str:
        """Generate text via llama-server raw /completion endpoint.

        Uses chatml format matching SmolLM3's training template.
        """
        try:
            sys_block = f"<|im_start|>system\n{system}<|im_end|>\n" if system else ""
            chatml = (
                f"{sys_block}"
                f"<|im_start|>user\n{prompt}<|im_end|>\n"
                f"<|im_start|>assistant\n"
            )

            r = requests.post(
                f"http://127.0.0.1:{CHAT_SERVER_PORT}/completion",
                json={
                    "prompt": chatml,
                    "n_predict": max_new_tokens,
                    "temperature": max(temperature, 0.01),
                    "top_p": 0.9,
                    "repeat_penalty": 1.1,
                    "stop": ["<|im_end|>", "<|im_start|>"],
                },
                timeout=30,
            )
            data = r.json()
            content = data.get("content", "")
            if not content:
                log.warning(f"Layer3: empty response: {str(data)[:200]}")
                return ""
            return content.strip()
        except Exception as e:
            log.warning(f"Layer3: inference error: {e}")
            return ""

    def _generate_chat(self, system_msg: str, messages: list[dict],
                       max_new_tokens: int = 120,
                       temperature: float = 0.25) -> str:
        """Generate a chat response from multi-turn conversation.

        Uses raw chatml format for proper multi-turn handling.
        """
        try:
            chatml = f"<|im_start|>system\n{system_msg}<|im_end|>\n"
            for msg in messages:
                role = msg["role"]
                content = msg["content"]
                chatml += f"<|im_start|>{role}\n{content}<|im_end|>\n"
            # Don't start with bare assistant — the fine-tuned model will
            # produce <think>...</think>COMMAND with nothing speakable.
            # Instead, use a two-shot prompt that shows the expected format.
            chatml += "<|im_start|>assistant\n"

            r = requests.post(
                f"http://127.0.0.1:{CHAT_SERVER_PORT}/completion",
                json={
                    "prompt": chatml,
                    "n_predict": max_new_tokens,
                    "temperature": max(temperature, 0.01),
                    "top_p": 0.9,
                    "repeat_penalty": 1.2,
                    "stop": ["<|im_end|>", "<|im_start|>"],
                },
                timeout=30,
            )
            data = r.json()
            content = data.get("content", "")
            if not content:
                log.warning(f"Layer3: empty chat response: {str(data)[:200]}")
                return ""
            return content.strip()
        except Exception as e:
            log.warning(f"Layer3: chat inference error: {e}")
            return ""

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
             somatic_tags: list[str] | str = "", npc_name: str = "") -> dict:
        """
        Generate a daily agenda: list of plan chunks.
        Uses persona defaults normally; triggers LLM replanning when state warrants it.
        """
        persona = self._get_persona(npc_name, role)
        default = self._get_default_schedule(persona)

        # Determine if state warrants LLM replanning
        should_replan = False
        mem_lower = memory_summary.lower()
        if "concern" in mem_lower or "worried" in mem_lower:
            should_replan = True
        if "frustration is high" in mem_lower:
            should_replan = True
        if "multiple recent failures" in mem_lower:
            should_replan = True
        if "urgent:" in mem_lower:
            should_replan = True
        # Somatic distress signals replan
        tags_str = ", ".join(somatic_tags) if isinstance(somatic_tags, list) else str(somatic_tags)
        tags_lower = tags_str.lower()
        if any(t in tags_lower for t in ("churning", "pounding", "tight", "prickling", "gnawing")):
            should_replan = True

        if not should_replan:
            return {"agenda": list(default), "source": "default"}

        locations_list = ", ".join(self.locations.keys())

        preamble = build_preamble(persona, somatic_tags, current_context)
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

    def plan_from_packet(self, packet: dict) -> dict:
        """
        Structured packet-based planning. No substring heuristics.
        Replan decision is explicit via packet['replan_reason'].
        """
        npc_name = packet.get("npc_name", "")
        role = packet.get("role", "")
        persona = self._get_persona(npc_name, role)
        default = self._get_default_schedule(persona)

        reason = packet.get("replan_reason", "none")
        if reason == "none":
            return {"agenda": list(default), "source": "default"}

        locations_list = ", ".join(self.locations.keys())

        preamble = build_preamble_from_packet(persona, packet)

        # Build compact context from packet fields
        context_parts = [f"Replan reason: {reason}."]

        failures = packet.get("recent_failures", [])
        if failures:
            for f in failures[:2]:
                context_parts.append(f"Failed: {f.get('purpose', '?')} at {f.get('location', '?')}")

        prompt = (
            f"{preamble}\n\n"
            f"Plan your day given your current state.\n"
            f"{' '.join(context_parts)}\n"
            f"Available locations: {locations_list}\n\n"
            f"Create a daily plan as a JSON array of objects. Each object has:\n"
            f'- "location": one of the available locations\n'
            f'- "duration": hours (0.5-5.0)\n'
            f'- "priority": 0.0-1.0\n'
            f'- "purpose": short description\n\n'
            f"Output 4-6 plan chunks. Output ONLY the JSON array."
        )

        # Log prompt length for measurement
        import logging
        logging.getLogger("layer3").info(f"PLAN_V2 prompt len={len(prompt)} chars (reason={reason})")

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

    def reflect_from_packet(self, packet: dict) -> dict:
        """Structured packet-based reflection."""
        events = packet.get("events", [])
        if not events:
            return {"reflections": [], "concerns": []}

        npc_name = packet.get("npc_name", "")
        role = packet.get("role", "")
        persona = self._get_persona(npc_name, role)
        name = persona.get("name", "A townsperson")

        # Build event lines from structured entries (already capped at 6)
        event_lines = []
        for e in events:
            text = e.get("text", "")
            kind = e.get("kind", "")
            conf = e.get("confidence", 1.0)
            suffix = f" [uncertain]" if conf < 0.5 else ""
            event_lines.append(f"- {text}{suffix}")
        events_str = "\n".join(event_lines)

        # Include concerns if present
        concerns_ctx = ""
        current_concerns = packet.get("current_concerns", [])
        if current_concerns:
            concerns_ctx = f"\nCurrent worries: {'; '.join(current_concerns)}\n"

        activity_ctx = ""
        intention = packet.get("active_intention", "")
        if intention:
            activity_ctx = f"\nCurrently: {intention}\n"

        import logging
        prompt = (
            f"Summarize these events from {name}'s perspective. "
            f"{name} is a {persona.get('role', 'villager')}.{activity_ctx}{concerns_ctx}\n"
            f"Events:\n{events_str}\n\n"
            f"Output a JSON object with:\n"
            f'- "reflections": array of 1-3 short summary sentences about what happened\n'
            f'- "concerns": array of 0-2 unresolved issues that would worry {name}\n\n'
            f"Output ONLY valid JSON."
        )

        logging.getLogger("layer3").info(f"REFLECT_V2 prompt len={len(prompt)} chars ({len(events)} events)")

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

    def dialogue(self, role: str, somatic_tags: list[str] | str,
                 relationship_context: str, recent_events: list[str],
                 npc_name: str = "") -> dict:
        """Generate dialogue greeting for player interaction."""
        persona = self._get_persona(npc_name, role)
        name = persona.get("name", npc_name or role)

        preamble = build_preamble(
            persona, somatic_tags,
            current_activity="", location="",
            recent_events=recent_events
        )

        system_msg = (
            f"{preamble}\n"
            f"Relationship with this traveler: {relationship_context}\n"
            f"A traveler just approached you. Greet them with one short sentence "
            f"as {name}. Stay in character."
        )

        messages = [{"role": "user", "content": "A traveler approaches."}]
        raw = self._generate_chat(system_msg, messages, max_new_tokens=60,
                                  temperature=0.4)
        thought, _ = self._split_think_and_speech(raw) if raw else ("", "")
        utterance = self._clean_utterance(raw) if raw else ""
        if not utterance or utterance == "Hmm.":
            fb = get_fallback_dialogue(role)
            utterance = fb.get("greeting", "Hello there.")

        result = {"intent": "greet", "utterance": utterance}
        if thought:
            result["inner_thought"] = thought[:200]
        return result

    def chat(self, role: str, npc_name: str, somatic_tags: list[str] | str,
             relationship_context: str, recent_events: list[str],
             conversation_history: list[dict], player_message: str) -> dict:
        """Generate NPC reply using multi-turn chatml via llama-server."""
        persona = self._get_persona(npc_name, role)
        name = persona.get("name", npc_name)

        preamble = build_preamble(
            persona, somatic_tags,
            recent_events=recent_events
        )

        system_msg = (
            f"{preamble}\n"
            f"Relationship with this traveler: {relationship_context}\n"
            f"Reply as {name} in one or two sentences. Stay in character. "
            f"Never break character or mention being an AI."
        )

        messages = []
        for msg in conversation_history[-6:]:
            if msg.get("speaker") == "Player":
                messages.append({"role": "user", "content": msg.get("text", "")})
            else:
                messages.append({"role": "assistant", "content": msg.get("text", "")})
        messages.append({"role": "user", "content": player_message})

        raw = self._generate_chat(system_msg, messages, max_new_tokens=120,
                                  temperature=0.25)
        thought, _ = self._split_think_and_speech(raw)
        utterance = self._clean_utterance(raw)

        result = {
            "utterance": utterance,
            "mood_shift": "neutral",
        }
        if thought:
            result["inner_thought"] = thought[:200]
        return result

    def converse(self, speaker_role: str, speaker_somatic: list[str] | str,
                 listener_role: str, listener_somatic: list[str] | str,
                 shared_context: str, speaker_recent: list[str],
                 speaker_name: str = "", listener_name: str = "") -> dict:
        """Generate NPC-to-NPC conversation line."""
        speaker_persona = self._get_persona(speaker_name, speaker_role)
        listener_persona = self._get_persona(listener_name, listener_role)

        preamble = build_preamble(
            speaker_persona, speaker_somatic,
            current_activity=shared_context,
            recent_events=speaker_recent
        )
        listener_desc = build_listener_context(listener_persona)

        if isinstance(listener_somatic, list):
            listener_feel = ", ".join(str(t) for t in listener_somatic[:3]) if listener_somatic else "calm"
        else:
            listener_feel = listener_somatic or "calm"

        system_msg = (
            f"{preamble}\n"
            f"You are talking to {listener_desc}, who seems: {listener_feel}.\n"
            f"Say ONE short sentence referencing something specific from your "
            f"situation or memories. No generic pleasantries."
        )

        messages = [{"role": "user", "content": f"{listener_persona.get('name', listener_role)} is standing nearby."}]
        raw = self._generate_chat(system_msg, messages, max_new_tokens=40,
                                  temperature=0.25)
        utterance = self._clean_utterance(raw) if raw else ""
        if not utterance:
            fb = get_fallback_dialogue(speaker_role)
            utterance = fb.get("gossip", f"Hello, {listener_persona.get('name', listener_role)}.")

        return {"intent": "greet", "utterance": utterance, "topic": "conversation"}

    def dialogue_from_packet(self, packet: dict) -> dict:
        """Structured packet-based dialogue (player greeting)."""
        npc_name = packet.get("npc_name", "")
        role = packet.get("role", "")
        persona = self._get_persona(npc_name, role)
        name = persona.get("name", npc_name or role)

        preamble = build_preamble_from_packet(persona, packet)

        trust = packet.get("trust", 0.5)
        target_type = packet.get("target_type", "player")
        trust_desc = "friendly" if trust > 0.6 else "neutral" if trust > 0.3 else "wary"
        approacher = "A traveler" if target_type == "player" else packet.get("target_name", "someone")

        system_msg = (
            f"{preamble}\n"
            f"{approacher} just approached you. You feel {trust_desc} toward them.\n"
            f"Greet them with one short sentence as {name}. Stay in character."
        )

        messages = [{"role": "user", "content": f"{approacher} approaches."}]
        raw = self._generate_chat(system_msg, messages, max_new_tokens=40,
                                  temperature=0.4)

        thought, _ = self._split_think_and_speech(raw) if raw else ("", "")
        utterance = self._clean_utterance(raw) if raw else ""

        log.info(f"DIALOGUE_V2 [{npc_name}] thought='{thought[:80]}' speech='{utterance}'")

        if not utterance or utterance == "Hmm.":
            fb = get_fallback_dialogue(role)
            utterance = fb.get("greeting", "Hello there.")

        result = {"intent": "greet", "utterance": utterance}
        if thought:
            result["inner_thought"] = thought[:200]
        return result

    def chat_from_packet(self, params: dict) -> dict:
        """Structured packet-based chat (player conversation reply).

        Uses proper chat template turns instead of embedding dialogue in one
        message. The model generates the assistant turn directly — no JSON
        wrapper needed, which eliminates role confusion on small models.
        """
        import logging
        npc_name = params.get("npc_name", "")
        role = params.get("role", "")
        persona = self._get_persona(npc_name, role)
        name = persona.get("name", npc_name)

        preamble = build_preamble_from_packet(persona, params)

        trust = params.get("trust", 0.5)
        trust_desc = "friendly" if trust > 0.6 else "neutral" if trust > 0.3 else "wary"

        conversation_history = params.get("conversation_history", [])
        player_message = params.get("player_message", "")

        # Build perception string
        perception = params.get("perception", "You don't see much around you.")
        current_thought = params.get("current_thought", "")

        logging.getLogger("layer3").info(
            f"CHAT_V2 [{npc_name}] perception='{perception[:120]}'"
        )

        # The chat model is just a mouth. It speaks from the being's current
        # thoughts and awareness. No backstory — that triggers fantasy hallucination.
        p = persona.get("personality", {})
        speech = p.get("speech_style", "plain spoken")

        # What the being currently knows/feels — this IS the grounding
        state_parts = []
        if current_thought:
            state_parts.append(f"You are thinking: \"{current_thought}\"")
        if perception:
            state_parts.append(perception)
        somatic_tags = params.get("somatic_tags", [])
        if somatic_tags:
            feel_str = ", ".join(str(t) for t in somatic_tags)
            state_parts.append(f"You feel: {feel_str}")
        state_str = "\n".join(state_parts) if state_parts else "You feel calm. You see a traveler nearby."

        system_msg = (
            f"You are {name}, {persona.get('role', 'villager')}. Speech: {speech}.\n"
            f"{state_str}\n"
            f"This is an outdoor town with paths and buildings. No indoor scenes.\n"
            f"Reply in 1-3 sentences. Only mention what is listed above."
        )

        messages = []
        for msg in conversation_history[-6:]:
            if msg.get("speaker") == "Player":
                messages.append({"role": "user", "content": msg.get("text", "")})
            else:
                messages.append({"role": "assistant", "content": msg.get("text", "")})
        messages.append({"role": "user", "content": player_message})

        logging.getLogger("layer3").info(
            f"CHAT_V2 prompt {len(messages)} turns"
        )

        raw = self._generate_chat(system_msg, messages, max_new_tokens=120,
                                  temperature=0.25)
        thought, _ = self._split_think_and_speech(raw)
        utterance = self._clean_utterance(raw)

        result = {
            "utterance": utterance,
            "mood_shift": "neutral",
        }
        if thought:
            result["inner_thought"] = thought[:200]
        return result

    def converse_from_packet(self, params: dict) -> dict:
        """Structured packet-based NPC-to-NPC conversation."""
        speaker = params.get("speaker", {})
        listener = params.get("listener", {})

        speaker_name = speaker.get("npc_name", "")
        speaker_role = speaker.get("role", "")
        listener_name = listener.get("npc_name", "")
        listener_role = listener.get("role", "")

        speaker_persona = self._get_persona(speaker_name, speaker_role)
        listener_persona = self._get_persona(listener_name, listener_role)

        preamble = build_preamble_from_packet(speaker_persona, speaker)
        listener_desc = build_listener_context(listener_persona)

        listener_somatic = listener.get("somatic_tags", [])
        listener_feel = ", ".join(str(t) for t in listener_somatic[:3]) if listener_somatic else "calm"

        system_msg = (
            f"{preamble}\n"
            f"You are talking to {listener_desc}, who seems: {listener_feel}.\n"
            f"Say ONE short sentence referencing something specific from your "
            f"situation or memories. No generic pleasantries."
        )

        messages = [{"role": "user", "content": f"{listener_persona.get('name', listener_role)} is standing nearby."}]
        raw = self._generate_chat(system_msg, messages, max_new_tokens=40,
                                  temperature=0.25)

        log.info(f"CONVERSE_V2 [{speaker_name}->{listener_name}] raw='{raw[:120] if raw else '(empty)'}'")

        utterance = self._clean_utterance(raw) if raw else ""
        if not utterance:
            fb = get_fallback_dialogue(speaker_role)
            utterance = fb.get("gossip", f"Hello, {listener_persona.get('name', listener_role)}.")

        return {"intent": "greet", "utterance": utterance, "topic": "conversation"}

    # ------------------------------------------------------------------
    # Utterance cleanup
    # ------------------------------------------------------------------

    @staticmethod
    def _split_think_and_speech(raw: str) -> tuple[str, str]:
        """Separate <think>...</think> inner monologue from spoken output.

        Returns (thought, speech). The thought is the being's inner monologue.
        The speech is what gets said aloud. Either may be empty.
        """
        thought = ""
        speech = raw

        # Extract thought from <think> block
        think_match = re.search(r'<think>(.*?)</think>', raw, re.DOTALL)
        if think_match:
            thought = think_match.group(1).strip()
            speech = raw[think_match.end():].strip()
        elif raw.startswith('<think>'):
            # Unclosed think block — everything is thought, no speech
            thought = raw.replace('<think>', '').replace('</think>', '').strip()
            speech = ""

        # Clean orphaned tags and chatml tokens from speech
        speech = speech.replace('</think>', '').replace('<think>', '')
        speech = re.sub(r'<\|im_start\|>.*', '', speech, flags=re.DOTALL)
        speech = speech.replace('<|im_end|>', '').strip()

        return thought, speech

    @staticmethod
    def _clean_utterance(raw: str, max_len: int = 300) -> str:
        """Clean model output into a presentable utterance.
        Extracts speech after <think> blocks, strips artifacts, caps length.
        If the model only thought with no speech, uses the thought as speech —
        the fine-tuned model often puts good dialogue inside think tags."""
        thought, speech = Layer3Model._split_think_and_speech(raw)

        # If no speech but there's a thought, use the thought
        if not speech.strip() and thought.strip():
            speech = thought

        # Take first non-empty line
        utterance = ""
        for line in speech.split("\n"):
            line = line.strip()
            if line:
                utterance = line
                break
        if not utterance:
            return "Hmm."
        # Remove JSON wrapper if model accidentally produced one
        if utterance.startswith("{"):
            try:
                data = json.loads(utterance)
                utterance = str(data.get("utterance", utterance))
            except (json.JSONDecodeError, ValueError):
                pass
        # Remove wrapping quotes
        if len(utterance) > 2 and utterance[0] in ('"', "'") and utterance[-1] == utterance[0]:
            utterance = utterance[1:-1]
        # Try to end at a sentence boundary if over max_len
        if len(utterance) > max_len:
            for i in range(max_len - 1, max(max_len - 80, 0), -1):
                if utterance[i] in ".!?":
                    utterance = utterance[:i + 1]
                    break
            else:
                utterance = utterance[:max_len]
        return utterance or "Hmm."

    # ------------------------------------------------------------------
    # Thought Loop: generate_thought + extract_beliefs
    # ------------------------------------------------------------------

    _THOUGHT_TOOLS = (
        "Tools available (use one or more per response):\n"
        "- think(\"text\") — express an internal thought or interpretation\n"
        "- intend(\"goal\", \"location\", priority, \"reason\") — set a persistent goal (priority 0.0-1.0)\n"
        "- believe(\"subject\", \"predicate\", \"object\", confidence) — record a belief (confidence 0.0-1.0)\n"
        "- bias_action(\"action\", strength) — bias an action tendency (strength -1.0 to 1.0)\n"
        "  Actions: approach, avoid, observe, help, flee\n"
    )

    _THOUGHT_TOOL_RE = re.compile(
        r'(think|intend|believe|bias_action)\s*\(\s*'
        r'(.*?)'
        r'\)\s*',
        re.DOTALL
    )

    def generate_thought(self, context: dict) -> dict:
        """Generate thought + command via the adventure-command model.

        Delegates to CommandModel (SmolLM3-3B GGUF via llama-server).
        Falls back to the old THOUGHT/WANT/FEEL format if command model
        is not available.

        Returns: {
            "thoughts": [str],
            "intentions": [{goal, location, priority, reason}],
            "beliefs": [{subject, predicate, object, confidence}],
            "action_biases": {action_name: float},
            "trigger_actions": [dict],
            "command": str,
            "target": dict | None,
            "raw": str,
        }
        """
        # --- New path: adventure-command model ---
        if self._command_model is not None:
            return self._command_model.generate_command(context)

        # --- Legacy fallback: THOUGHT/WANT/FEEL with SmolLM2 ---
        return self._legacy_generate_thought(context)

    def _legacy_generate_thought(self, context: dict) -> dict:
        """Legacy thought generation using THOUGHT/WANT/FEEL format."""
        npc_name = context.get("npc_name", "")
        role = context.get("role", "")
        persona = self._get_persona(npc_name, role)

        name = persona.get("name", npc_name)
        p = persona.get("personality", {})
        traits = ", ".join(p.get("traits", ["quiet"]))
        backstory = p.get("backstory", "A resident of the town.")

        drives = context.get("drives", {})

        # Somatic tags — what the being feels in its body
        somatic_tags = context.get("somatic_tags", [])
        if somatic_tags:
            feel_str = ", ".join(str(t) for t in somatic_tags)
        else:
            feel_str = "body:settled"

        visible = context.get("visible", [])
        perception_lines = []
        for v in visible[:6]:
            exposure = v.get("exposure", 1.0)
            clarity = "clearly" if exposure > 0.7 else "partially" if exposure > 0.3 else "barely"
            perception_lines.append(
                f"  {v.get('name', 'someone')} — {clarity} visible, "
                f"{v.get('distance', 0):.0f} tiles to the {v.get('direction', 'east')}"
            )
        if not perception_lines:
            perception_lines.append("  No one nearby. Just the town around you.")

        heard = context.get("heard", [])
        if heard:
            for h in heard[:3]:
                src = h.get("source", "unknown")
                text = h.get("text", "")
                dist = h.get("distance", 0)
                if text:
                    perception_lines.append(f"  You hear {src} say: \"{text}\" ({dist:.0f} tiles away)")
                else:
                    perception_lines.append(f"  You hear sounds from {src} ({dist:.0f} tiles away)")

        perception_str = "\n".join(perception_lines)

        events = context.get("recent_events", [])
        events_str = "; ".join(str(e) for e in events[-3:]) if events else "nothing notable"

        recent_thoughts = context.get("recent_thoughts", [])
        thoughts_str = ""
        if recent_thoughts:
            thoughts_str = "\nYour recent thoughts: " + "; ".join(recent_thoughts[-2:])

        intentions_str = context.get("intentions_summary", "nothing in particular")
        beliefs_str = context.get("beliefs_summary", "none")

        hour = context.get("hour", 6.0)
        hour_str = f"{int(hour)}:{int((hour % 1) * 60):02d}"
        location = context.get("location", "unknown")

        prompt = (
            f"You are {name}, the {role}. Personality: {traits}.\n"
            f"Background: {backstory}\n"
            f"You feel: {feel_str}.\n"
            f"Current goals: {intentions_str}.\n"
            f"What you know: {beliefs_str}.\n"
            f"{thoughts_str}\n\n"
            f"It is {hour_str}. You are at the {location}.\n"
            f"\n"
            f"Doing: {context.get('current_action', 'idle')}.\n"
            f"People you see:\n{perception_str}\n"
            f"Recent: {events_str}\n\n"
            f"This is an outdoor medieval town with paths and buildings. "
            f"There is no indoor furniture, fire, food, or drinks visible.\n\n"
            f"Write what {name} is thinking in 1-3 sentences. "
            f"Only mention people listed above. "
            f"Then say what {name} wants to do. Name a specific location from: "
            f"{', '.join(self.locations.keys()) if self.locations else 'town'}\n\n"
            f"THOUGHT: (first person, about people you see or how you feel)\n"
            f"WANT: (go to LOCATION_NAME to do something, or nothing)\n"
            f"FEEL: (one word)"
        )

        log.info(f"THOUGHT_LEGACY [{npc_name}] prompt len={len(prompt)} chars")

        raw = self._generate(prompt, max_new_tokens=150, temperature=0.4)

        return self._parse_simple_thought(raw, context)

    def _parse_simple_thought(self, raw: str, context: dict) -> dict:
        """Parse THOUGHT/WANT/FEEL format from the model output."""
        result = {
            "thoughts": [],
            "intentions": [],
            "beliefs": [],
            "action_biases": {},
            "raw": raw,
        }

        thought = ""
        want = ""
        feel = ""

        for line in raw.strip().split("\n"):
            line = line.strip()
            upper = line.upper()
            if upper.startswith("THOUGHT:"):
                thought = line[len("THOUGHT:"):].strip().strip('"')
            elif upper.startswith("WANT:"):
                want = line[len("WANT:"):].strip().strip('"')
            elif upper.startswith("FEEL:"):
                feel = line[len("FEEL:"):].strip().strip('"').lower()

        # If no structured output, use the whole thing as thought
        if not thought:
            cleaned = raw.strip().split("\n")[0].strip()
            if cleaned:
                thought = cleaned[:200]

        if thought:
            result["thoughts"].append(thought)

        # Parse WANT into an intention if it names a location
        if want and want.lower() != "nothing":
            want_lower = want.lower()
            # Try to extract a location from the want text
            best_loc = ""
            if self.locations:
                for loc_name in self.locations:
                    if loc_name.replace("_", " ") in want_lower or loc_name in want_lower:
                        best_loc = loc_name
                        break
            if best_loc:
                result["intentions"].append({
                    "goal": want[:80],
                    "location": best_loc,
                    "priority": 0.6,
                    "reason": thought[:60] if thought else "want",
                })
            # Derive action biases from want text
            if any(w in want_lower for w in ["go", "walk", "head", "visit", "check"]):
                result["action_biases"]["approach"] = 0.3
            if any(w in want_lower for w in ["talk", "chat", "socialize", "greet"]):
                result["action_biases"]["approach"] = 0.3
                result["action_biases"]["help"] = 0.2
            if any(w in want_lower for w in ["watch", "look", "observe", "investigate"]):
                result["action_biases"]["observe"] = 0.3
            if any(w in want_lower for w in ["avoid", "leave", "get away"]):
                result["action_biases"]["avoid"] = 0.3

        # Derive action biases from feel
        if feel:
            if feel in ("curious", "interested", "intrigued"):
                result["action_biases"]["observe"] = result["action_biases"].get("observe", 0) + 0.2
            elif feel in ("anxious", "nervous", "scared", "afraid"):
                result["action_biases"]["flee"] = 0.2
                result["action_biases"]["avoid"] = 0.2
            elif feel in ("happy", "content", "warm", "friendly"):
                result["action_biases"]["approach"] = result["action_biases"].get("approach", 0) + 0.1

        return result

    def _parse_thought_output(self, raw: str) -> dict:
        """Parse tool calls from thought generation output."""
        result = {
            "thoughts": [],
            "intentions": [],
            "beliefs": [],
            "action_biases": {},
            "raw": raw,
        }

        # Try structured tool-call parsing
        for match in self._THOUGHT_TOOL_RE.finditer(raw):
            func_name = match.group(1)
            args_str = match.group(2).strip()

            try:
                if func_name == "think":
                    text = self._extract_string_arg(args_str)
                    if text:
                        result["thoughts"].append(text)

                elif func_name == "intend":
                    parts = self._split_args(args_str)
                    if len(parts) >= 4:
                        result["intentions"].append({
                            "goal": self._unquote(parts[0]),
                            "location": self._unquote(parts[1]),
                            "priority": self._parse_float(parts[2], 0.5),
                            "reason": self._unquote(parts[3]),
                        })

                elif func_name == "believe":
                    parts = self._split_args(args_str)
                    if len(parts) >= 4:
                        result["beliefs"].append({
                            "subject": self._unquote(parts[0]),
                            "predicate": self._unquote(parts[1]),
                            "object": self._unquote(parts[2]),
                            "confidence": self._parse_float(parts[3], 0.5),
                        })

                elif func_name == "bias_action":
                    parts = self._split_args(args_str)
                    if len(parts) >= 2:
                        action = self._unquote(parts[0])
                        strength = self._parse_float(parts[1], 0.0)
                        if action in ("approach", "avoid", "observe", "help", "flee"):
                            result["action_biases"][action] = max(-1.0, min(1.0, strength))
            except Exception:
                continue

        # Fallback: if no tool calls parsed, treat entire output as a thought
        if not result["thoughts"] and not result["intentions"] and not result["beliefs"]:
            cleaned = raw.strip()
            if cleaned:
                # Strip any accidental JSON or formatting
                if cleaned.startswith('"') and cleaned.endswith('"'):
                    cleaned = cleaned[1:-1]
                result["thoughts"].append(cleaned[:200])

        return result

    @staticmethod
    def _extract_string_arg(args_str: str) -> str:
        """Extract a single string argument from args like '"hello world"'."""
        args_str = args_str.strip()
        if args_str.startswith('"') and args_str.endswith('"'):
            return args_str[1:-1]
        if args_str.startswith("'") and args_str.endswith("'"):
            return args_str[1:-1]
        return args_str

    @staticmethod
    def _split_args(args_str: str) -> list[str]:
        """Split comma-separated args, respecting quoted strings."""
        parts = []
        current = ""
        in_quote = False
        quote_char = ""
        for ch in args_str:
            if ch in ('"', "'") and not in_quote:
                in_quote = True
                quote_char = ch
                current += ch
            elif ch == quote_char and in_quote:
                in_quote = False
                current += ch
            elif ch == "," and not in_quote:
                parts.append(current.strip())
                current = ""
            else:
                current += ch
        if current.strip():
            parts.append(current.strip())
        return parts

    @staticmethod
    def _unquote(s: str) -> str:
        s = s.strip()
        if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
            return s[1:-1]
        return s

    @staticmethod
    def _parse_float(s: str, default: float) -> float:
        try:
            return float(s.strip().strip('"').strip("'"))
        except (ValueError, AttributeError):
            return default

    def extract_beliefs_from_conversation(self, npc_name: str, role: str,
                                           utterance: str, speaker_name: str) -> dict:
        """Extract beliefs from something an NPC heard during conversation.

        Returns: {
            "beliefs": [{subject, predicate, object, confidence}],
        }
        """
        persona = self._get_persona(npc_name, role)
        name = persona.get("name", npc_name)

        prompt = (
            f"You are {name}, the {persona.get('role', 'villager')}.\n"
            f"{speaker_name} just said: \"{utterance}\"\n\n"
            f"Extract any factual claims as beliefs. Use:\n"
            f"- believe(\"subject\", \"predicate\", \"object\", confidence)\n"
            f"  confidence is 0.0-1.0 based on how much you trust {speaker_name}.\n\n"
            f"If there are no factual claims, output nothing.\n"
            f"Output ONLY tool calls, one per line."
        )

        raw = self._generate(prompt, max_new_tokens=100, temperature=0.2)
        parsed = self._parse_thought_output(raw)
        return {"beliefs": parsed["beliefs"]}

    def get_location_tile(self, location_name: str) -> list[int] | None:
        """Get tile coordinates for a named location."""
        loc = self.locations.get(location_name)
        if loc:
            return loc.get("tile")
        return None
