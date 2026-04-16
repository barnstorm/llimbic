"""
Layer 3 — Command Model (SmolLM3-3B LoRA fine-tune via llama-server)

Adventure-command interface for NPC executive function.
Receives perception state, thinks in <think> tags, outputs VERB NOUN command.

Two-pass inference:
  Pass 1: Unconstrained — generates <think>...</think> + command
  Pass 2 (optional): GBNF-constrained — re-generates just the command if
          pass 1 produced an unparseable one.

Uses llama-server subprocess on a dedicated port, same pattern as Layer 2.
"""

import os
import subprocess
import time
import logging
import requests

from command_parser import parse_command_output
from command_grammar import build_gbnf_from_context

log = logging.getLogger("layer3")

COMMAND_SERVER_PORT = 8423

SYSTEM_PROMPT = (
    "You are the mind of a simulated being. You receive your state and "
    "perceptions, think about your situation, then choose one action. "
    "Think inside <think></think> tags, then output exactly one command."
)


def _format_perception(context: dict) -> str:
    """Build the adventure-command user prompt from thought context.

    The being receives its body state as somatic tags (not numeric drives).
    Tags are compound descriptors like 'gut:empty:churning' that the being
    interprets through context. The being doesn't know its exact hunger level —
    it feels a gnawing emptiness and decides what to do about it.
    """
    npc_name = context.get("npc_name", "unknown")
    role = context.get("role", "villager")

    # Somatic tags — what the being feels (primary grounding)
    somatic_tags = context.get("somatic_tags", [])
    if somatic_tags:
        feel_str = ", ".join(str(t) for t in somatic_tags)
    else:
        # Fallback: synthesize minimal tags from drive floats if somatic stream not running
        feel_str = _fallback_feel_from_drives(context.get("drives", {}))

    location = context.get("location", "unknown")
    current_action = context.get("current_action", "idle")

    # Visible entities
    visible = context.get("visible", [])
    see_lines = []
    for v in visible[:6]:
        name = v.get("name", "someone")
        dist = v.get("distance", 0)
        direction = v.get("direction", "nearby")
        action = v.get("action", "standing")
        see_lines.append(f"  {name} -- {dist:.0f} tiles {direction}, {action}")
    see_str = "\n".join(see_lines) if see_lines else "  (no one)"

    # Heard
    heard = context.get("heard", [])
    hear_lines = []
    for h in heard[:3]:
        src = h.get("source", "unknown")
        text = h.get("text", "")
        dist = h.get("distance", 0)
        if text:
            hear_lines.append(f"  {src}: \"{text}\" ({dist:.0f} tiles {h.get('direction', 'away')})")
    hear_str = "\n".join(hear_lines) if hear_lines else "  (nothing)"

    # Nearby objects
    visible_objects = context.get("visible_objects", [])
    obj_lines = []
    for obj in visible_objects[:4]:
        obj_name = obj.get("name", "something")
        obj_state = obj.get("state", "")
        obj_lines.append(f"  {obj_name}" + (f" ({obj_state})" if obj_state else ""))
    obj_str = "\n".join(obj_lines) if obj_lines else "  (none)"

    # Recent events
    events = context.get("recent_events", [])
    events_str = "; ".join(str(e) for e in events[-3:]) if events else "Nothing notable."

    # Goal from intentions
    intentions = context.get("intentions_summary", "none")

    # Beliefs
    beliefs = context.get("beliefs_summary", "none")

    # Recent thoughts
    recent_thoughts = context.get("recent_thoughts", [])
    last_thought = recent_thoughts[-1] if recent_thoughts else "none"

    # Available locations
    from command_grammar import LOCATIONS
    places_str = ", ".join(LOCATIONS)

    return (
        f"BEING: {role}\n"
        f"LOCATION: {location}\n"
        f"DOING: {current_action}\n"
        f"\n"
        f"You feel: {feel_str}\n"
        f"\n"
        f"You see:\n{see_str}\n"
        f"You hear:\n{hear_str}\n"
        f"Nearby objects:\n{obj_str}\n"
        f"\n"
        f"Recent: {events_str}\n"
        f"Goal: {intentions}\n"
        f"Beliefs: {beliefs}\n"
        f"Last thought: {last_thought}\n"
        f"\n"
        f"Available places: {places_str}\n"
        f"\n"
        f"Think about your situation, then choose ONE action."
    )


def _fallback_feel_from_drives(drives: dict) -> str:
    """Synthesize minimal somatic tags from drive floats when somatic stream
    is not available. Rough approximation — the real stream is much richer."""
    parts = []
    energy = drives.get("energy", 80)
    hunger = drives.get("hunger", 20)
    social = drives.get("social_need", 30)
    safety = drives.get("safety", 80)

    if energy < 30:
        parts.append("muscles:heavy")
        parts.append("head:foggy")
    if hunger > 60:
        parts.append("gut:empty")
    if hunger > 80:
        parts.append("gut:gnawing")
    if social > 60:
        parts.append("chest:hollow")
    if safety < 40:
        parts.append("chest:tight")
        parts.append("skin:prickling")
    if energy > 70 and safety > 70:
        parts.append("head:clear")
        parts.append("chest:open")

    return ", ".join(parts) if parts else "body:settled"


class CommandModel:
    """Adventure-command model using SmolLM3-3B GGUF via llama-server."""

    def __init__(self, gguf_path: str | None = None):
        server_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(server_dir)

        if gguf_path is None:
            gguf_path = os.path.join(
                project_root, "training", "cognitive",
                "SmolLM3-3B.Q4_K_M.gguf"
            )
        self.gguf_path = gguf_path

        if not os.path.exists(self.gguf_path):
            raise FileNotFoundError(f"Command GGUF not found: {self.gguf_path}")

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

    def _start_server(self):
        log.info(f"CommandModel: Starting llama-server on port {COMMAND_SERVER_PORT}...")
        self._proc = subprocess.Popen(
            [
                self._llama_bin,
                "-m", self.gguf_path,
                "--port", str(COMMAND_SERVER_PORT),
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
                    f"http://127.0.0.1:{COMMAND_SERVER_PORT}/health",
                    timeout=1,
                )
                if r.status_code == 200:
                    log.info(
                        "CommandModel: llama-server ready "
                        f"(SmolLM3-3B Q4_K_M, port {COMMAND_SERVER_PORT})"
                    )
                    return
            except requests.ConnectionError:
                pass
            time.sleep(1)
        raise RuntimeError(
            f"CommandModel llama-server failed to start on port {COMMAND_SERVER_PORT}"
        )

    def __del__(self):
        if hasattr(self, '_proc') and self._proc and self._proc.poll() is None:
            self._proc.terminate()

    def _generate(self, user_content: str, max_tokens: int = 200,
                  temperature: float = 0.4, grammar: str | None = None) -> str:
        """Call llama-server using raw completion endpoint.

        Uses the exact chatml format from training data to bypass
        SmolLM3's built-in chat template (which has its own thinking
        mode that conflicts with our fine-tuned <think> tags).
        """
        try:
            # Build raw chatml prompt matching training format
            prompt = (
                f"<|im_start|>system\n{SYSTEM_PROMPT}<|im_end|>\n"
                f"<|im_start|>user\n{user_content}<|im_end|>\n"
                f"<|im_start|>assistant\n"
            )

            payload = {
                "prompt": prompt,
                "n_predict": max_tokens,
                "temperature": temperature,
                "top_p": 0.9,
                "stop": ["<|im_end|>"],
            }
            if grammar:
                payload["grammar"] = grammar

            r = requests.post(
                f"http://127.0.0.1:{COMMAND_SERVER_PORT}/completion",
                json=payload,
                timeout=30,
            )
            data = r.json()
            content = data.get("content", "")
            if not content:
                log.warning(f"CommandModel: empty response: {str(data)[:200]}")
                return ""
            return content.strip()
        except Exception as e:
            log.warning(f"CommandModel: inference error: {e}")
            return ""

    def generate_command(self, context: dict) -> dict:
        """
        Generate a thought + command from NPC perception context.

        Returns dict compatible with thought loop protocol:
            thoughts, intentions, beliefs, action_biases,
            trigger_actions, command, target, raw
        """
        prompt = _format_perception(context)
        raw = self._generate(prompt, max_tokens=200, temperature=0.4)

        if not raw:
            return {
                "thoughts": [],
                "intentions": [],
                "beliefs": [],
                "action_biases": {},
                "trigger_actions": [],
                "command": "",
                "target": None,
                "raw": "",
            }

        result = parse_command_output(raw, context)

        # If no command was parsed, try pass 2 with GBNF grammar
        if not result["command"] and result["thoughts"]:
            log.info(f"CommandModel: pass 1 had no valid command, trying GBNF constrained")
            grammar = build_gbnf_from_context(context)
            raw2 = self._generate(prompt, max_tokens=60, temperature=0.3,
                                  grammar=grammar)
            if raw2:
                # Parse the constrained output as just a command (no think block)
                result2 = parse_command_output(raw2, context)
                if result2["command"]:
                    # Keep thoughts from pass 1, command from pass 2
                    result["intentions"] = result2["intentions"]
                    result["action_biases"] = result2["action_biases"]
                    result["trigger_actions"] = result2["trigger_actions"]
                    result["command"] = result2["command"]
                    result["target"] = result2["target"]

        log.info(
            f"CommandModel [{context.get('npc_name', '?')}]: "
            f"thought={result['thoughts'][0][:60] if result['thoughts'] else '(none)'} "
            f"cmd={result['command']}"
        )

        return result
