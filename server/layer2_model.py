"""
Layer 2 — Limbic System Model (GGUF via llama-cpp-python)

Fine-tuned TinyLlama-1.1B quantized to Q4_K_M GGUF, ~636MB.
Runs on GPU via llama-cpp-python CUDA backend. ~0.3s per inference.
"""

import os
import subprocess
import time
import requests
from emotion_coords import (
    DIMENSIONS, NUM_DIMS, DIM_INDEX, clamp_vector, default_vector,
    top_dimensions,
)

LIMBIC_DIMS = ["valence", "arousal", "dominance", "social_focus", "temporal", "certainty"]

SYSTEM_PROMPT = (
    "You are a limbic system — an emotional processing layer that translates "
    "between neural activations, thoughts, and emotional states. You receive "
    "sensory data (6D neural activation vectors) and/or inner thoughts, and "
    "output structured emotional assessments including emotion labels with "
    "intensities, attention focus priorities, and motivational drives."
)


LLAMA_SERVER_PORT = 8422


class Layer2Model:
    """Limbic system model using GGUF via llama-server subprocess (CPU)."""

    def __init__(self, device: str = "cuda"):
        self.model_name = "limbic-tinyllama-lora"

        server_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(server_dir)
        self.gguf_path = os.path.join(project_root, "training", "limbic-tinyllama-q4.gguf")

        if not os.path.exists(self.gguf_path):
            raise FileNotFoundError(f"GGUF model not found: {self.gguf_path}")

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
        print(f"Layer2: Starting llama-server on port {LLAMA_SERVER_PORT}...")
        self._proc = subprocess.Popen(
            [
                self._llama_bin,
                "-m", self.gguf_path,
                "--port", str(LLAMA_SERVER_PORT),
                "--ctx-size", "4096",
                "-t", "8",
                "-np", "2",
                "--log-disable",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(30):
            try:
                r = requests.get(f"http://127.0.0.1:{LLAMA_SERVER_PORT}/health", timeout=1)
                if r.status_code == 200:
                    print("Layer2: llama-server ready (GGUF Q4_K_M, CPU 8 threads)")
                    return
            except requests.ConnectionError:
                pass
            time.sleep(1)
        raise RuntimeError("llama-server failed to start")

    def __del__(self):
        if hasattr(self, '_proc') and self._proc and self._proc.poll() is None:
            self._proc.terminate()

    def _generate(self, user_content: str, max_tokens: int = 200,
                  temperature: float = 0.3) -> str:
        try:
            r = requests.post(
                f"http://127.0.0.1:{LLAMA_SERVER_PORT}/v1/chat/completions",
                json={
                    "messages": [
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": user_content},
                    ],
                    "temperature": temperature,
                    "max_tokens": max_tokens,
                    "frequency_penalty": 0.1,
                },
                timeout=30,
            )
            data = r.json()
            if "choices" not in data:
                print(f"Layer2: unexpected response: {str(data)[:200]}")
                return ""
            return data["choices"][0]["message"]["content"].strip()
        except Exception as e:
            print(f"Layer2: inference error: {e}")
            return ""

    @staticmethod
    def l1_to_6d(layer1_state: dict) -> list[float]:
        """Map Layer 1 substrate state to 6D limbic vector."""
        energy = layer1_state.get("energy", 50.0) / 100.0
        hunger = layer1_state.get("hunger", 50.0) / 100.0
        social = layer1_state.get("social_need", 50.0) / 100.0
        safety = layer1_state.get("safety", 80.0) / 100.0
        momentum = layer1_state.get("task_momentum", 0.5)
        frustration = layer1_state.get("frustration", 0.0)

        valence = max(0, min(1,
            energy * 0.3 + safety * 0.3 + (1.0 - hunger) * 0.2 + (1.0 - frustration) * 0.2
        ))
        arousal = max(0, min(1,
            frustration * 0.4 + momentum * 0.3 + (1.0 - energy) * 0.15 + hunger * 0.15
        ))
        dominance = max(0, min(1,
            safety * 0.4 + momentum * 0.3 + energy * 0.3
        ))
        social_focus = max(0, min(1, social))
        temporal = max(0, min(1,
            momentum * 0.6 + (1.0 - frustration) * 0.4
        ))
        certainty = max(0, min(1,
            safety * 0.4 + (1.0 - frustration) * 0.4 + momentum * 0.2
        ))

        return [round(v, 2) for v in [valence, arousal, dominance, social_focus, temporal, certainty]]

    @staticmethod
    def _build_context(layer1_state: dict, recent_events: list[str]) -> str:
        """Build a natural-language context string from L1 state."""
        parts = []
        energy = layer1_state.get("energy", 50)
        hunger = layer1_state.get("hunger", 50)
        safety = layer1_state.get("safety", 80)
        frustration = layer1_state.get("frustration", 0)
        social = layer1_state.get("social_need", 50)
        momentum = layer1_state.get("task_momentum", 0)

        if energy < 25:
            parts.append("exhausted and low energy")
        elif energy < 40:
            parts.append("tired")
        if hunger > 80:
            parts.append("very hungry")
        elif hunger > 60:
            parts.append("hungry")
        if safety < 30:
            parts.append("danger nearby, feeling unsafe")
        elif safety < 50:
            parts.append("somewhat uneasy environment")
        if frustration > 0.7:
            parts.append("very frustrated by repeated obstacles")
        elif frustration > 0.4:
            parts.append("frustrated")
        if social > 80:
            parts.append("lonely, strong need for social contact")
        elif social > 60:
            parts.append("wanting social interaction")
        if momentum > 0.7:
            parts.append("deeply focused on current task")
        elif momentum > 0.4:
            parts.append("engaged in work")

        if not parts:
            parts.append("routine activity, calm environment")

        if recent_events:
            last_event = str(recent_events[-1])
            if len(last_event) > 80:
                last_event = last_event[:77] + "..."
            parts.append(last_event)

        return ", ".join(parts)

    @staticmethod
    def _build_thought(recent_events: list[str]) -> str:
        """Build an inner thought string from recent events."""
        if not recent_events:
            return ""
        thoughts = []
        for event in recent_events[-3:]:
            ev = str(event)
            if len(ev) > 60:
                ev = ev[:57] + "..."
            thoughts.append(ev)
        return "; ".join(thoughts)

    @staticmethod
    def _parse_limbic_output(text: str) -> dict:
        """Parse structured limbic model output."""
        result = {"emotions": {}, "attention": [], "drives": {}}
        for line in text.strip().split("\n"):
            line = line.strip()
            if line.startswith("Emotional State:"):
                parts = line.replace("Emotional State:", "").strip()
                for pair in parts.split(","):
                    pair = pair.strip()
                    if not pair:
                        continue
                    if ":" in pair:
                        k, v = pair.rsplit(":", 1)
                        try:
                            result["emotions"][k.strip()] = float(v.strip())
                        except ValueError:
                            result["emotions"][k.strip()] = 1.0
                    else:
                        result["emotions"][pair] = 1.0
            elif line.startswith("Attention Focus:"):
                parts = line.replace("Attention Focus:", "").strip()
                result["attention"] = [p.strip() for p in parts.split(",") if p.strip()]
            elif line.startswith("Motivational Drive:"):
                parts = line.replace("Motivational Drive:", "").strip()
                for pair in parts.split(","):
                    pair = pair.strip()
                    if not pair:
                        continue
                    if ":" in pair:
                        k, v = pair.rsplit(":", 1)
                        try:
                            val = float(v.strip())
                            key = k.strip().split(" or ")[0].split("/")[0].strip()
                            result["drives"][key] = val
                        except ValueError:
                            pass
        return result

    @staticmethod
    def emotions_to_27dim(emotions: dict, current_vector: list[float] = None) -> list[float]:
        """Convert limbic emotion labels to 27-dim GoEmotions vector.
        Blends with current vector: limbic 0.6, current 0.4.
        """
        limbic_vec = [0.0] * NUM_DIMS
        for label, intensity in emotions.items():
            if label in DIM_INDEX:
                limbic_vec[DIM_INDEX[label]] = max(0.0, min(1.0, float(intensity)))

        if current_vector and len(current_vector) == NUM_DIMS:
            blended = [
                limbic_vec[i] * 0.6 + current_vector[i] * 0.4
                for i in range(NUM_DIMS)
            ]
            return clamp_vector(blended)
        return clamp_vector(limbic_vec)

    def project(self, layer1_state: dict, recent_events: list[str],
                current_vector: list[float]) -> dict:
        """Northbound projection: Layer 1 state → emotions + attention + drives."""
        vec_6d = self.l1_to_6d(layer1_state)
        context = self._build_context(layer1_state, recent_events)
        thought = self._build_thought(recent_events)

        dims = ", ".join(f"{LIMBIC_DIMS[i]}={vec_6d[i]:.2f}" for i in range(6))
        if thought:
            user_input = (
                f"Neural Activation: [{dims}]\n"
                f"Context: {context}\n"
                f"Inner Thought: \"{thought}\""
            )
        else:
            user_input = (
                f"Neural Activation: [{dims}]\n"
                f"Context: {context}"
            )

        raw = self._generate(user_input, max_tokens=200, temperature=0.3)
        parsed = self._parse_limbic_output(raw)

        vec = current_vector if current_vector and len(current_vector) == NUM_DIMS else default_vector()
        if parsed["emotions"]:
            new_vector = self.emotions_to_27dim(parsed["emotions"], vec)
        else:
            new_vector = vec

        if parsed["emotions"]:
            summary = ", ".join(list(parsed["emotions"].keys())[:3])
        else:
            summary = self._heuristic_summary(new_vector)

        return {
            "vector": new_vector,
            "summary": summary,
            "emotions": parsed["emotions"],
            "attention": parsed["attention"],
            "drives": parsed["drives"],
            "raw_model_output": raw[:300],
        }

    def modulate(self, directives: str, current_vector: list[float]) -> dict:
        """Southbound modulation: deterministic mapping from emotions to L1 params."""
        vec = current_vector if current_vector and len(current_vector) == NUM_DIMS else default_vector()

        fear = vec[DIM_INDEX["fear"]]
        curiosity = vec[DIM_INDEX["curiosity"]]
        anger = vec[DIM_INDEX["anger"]]
        pride = vec[DIM_INDEX["pride"]]
        nervousness = vec[DIM_INDEX["nervousness"]]
        neg_sum = sum(vec[i] for i in range(12, 23))

        chunk_priority = 0.5
        if "priority=" in directives:
            try:
                chunk_priority = float(directives.split("priority=")[1].split()[0])
            except (ValueError, IndexError):
                pass

        return {
            "learning_rate_mod": max(0.5, min(2.0, 1.0 + curiosity * 0.5 - fear * 0.3)),
            "exploration_bias": max(0.0, min(1.0, curiosity * 0.8 - fear * 0.4 - nervousness * 0.2)),
            "attention_weight": max(0.0, min(1.0, 0.5 + fear * 0.3 + chunk_priority * 0.2)),
            "interruption_sensitivity": max(0.0, min(1.0, 0.5 - chunk_priority * 0.3 + curiosity * 0.2 - pride * 0.1)),
            "persistence_scale": max(0.5, min(2.0, 1.0 + chunk_priority * 0.5 + anger * 0.2 + pride * 0.2 - neg_sum * 0.05)),
        }

    def color_thought(self, thought_text: str, current_emotions: dict,
                      current_vector: list[float]) -> dict:
        """Pass a thought through the limbic system for emotional coloring.

        The thought is treated as an inner stimulus — the limbic model interprets
        it emotionally, exactly as it would interpret a sensory input.

        Returns: {
            "vector": list[float],   # updated 27-dim emotion vector
            "emotions": dict,        # {emotion_label: intensity}
            "attention": list[str],
            "drives": dict,
            "summary": str,
        }
        """
        emo_str = ", ".join(f"{k}={v:.2f}" for k, v in list(current_emotions.items())[:3])
        context = f"currently feeling {emo_str}" if emo_str else "neutral state"

        user_input = (
            f"Neural Activation: [valence=0.50, arousal=0.50, dominance=0.50, "
            f"social_focus=0.50, temporal=0.50, certainty=0.50]\n"
            f"Context: {context}\n"
            f"Inner Thought: \"{thought_text}\""
        )

        raw = self._generate(user_input, max_tokens=200, temperature=0.3)
        parsed = self._parse_limbic_output(raw)

        vec = current_vector if current_vector and len(current_vector) == NUM_DIMS else default_vector()
        if parsed["emotions"]:
            new_vector = self.emotions_to_27dim(parsed["emotions"], vec)
        else:
            new_vector = vec

        summary = ", ".join(list(parsed["emotions"].keys())[:3]) if parsed["emotions"] else "unchanged"

        return {
            "vector": new_vector,
            "emotions": parsed["emotions"],
            "attention": parsed.get("attention", []),
            "drives": parsed.get("drives", {}),
            "summary": summary,
        }

    def narrate_body_state(self, drives: dict, somatic_tags: list[str],
                           vagal_state: dict, recent_events: list[str],
                           current_action: str = "") -> str:
        """Translate raw body state into felt second-person narrative.

        This is the northbound interoception path: the being's body speaks
        to its mind in natural language, not numbers or tag syntax.
        """
        context = self._build_context(drives, recent_events)
        tags_str = ", ".join(somatic_tags[:6]) if somatic_tags else "calm"

        # Vagal framing
        vagal_frame = ""
        if vagal_state:
            v = vagal_state.get("ventral", 50)
            s = vagal_state.get("sympathetic", 20)
            d = vagal_state.get("dorsal", 5)
            if d > s and d > v and d > 40:
                vagal_frame = "You feel shut down, disconnected."
            elif s > v and s > 40:
                vagal_frame = "Your body is on edge, mobilized."
            elif v > 60:
                vagal_frame = "You feel safe and grounded."

        user_input = (
            f"Body signals: {tags_str}\n"
            f"Context: {context}\n"
            f"{f'Doing: {current_action}' + chr(10) if current_action else ''}"
            f"{vagal_frame + chr(10) if vagal_frame else ''}"
            f"Describe what this being feels in their body in 2-3 short "
            f"second-person sentences. Be specific and physical, not emotional labels."
        )

        raw = self._generate(user_input, max_tokens=80, temperature=0.3)
        # Clean up — take first 2-3 sentences
        if raw:
            sentences = [s.strip() for s in raw.replace('\n', ' ').split('.') if s.strip()]
            narrative = '. '.join(sentences[:3])
            if narrative and not narrative.endswith('.'):
                narrative += '.'
            return narrative
        return "You feel settled. Nothing demands your attention."

    def _heuristic_summary(self, vec: list[float]) -> str:
        top = top_dimensions(vec, 3)
        if not top or top[0][1] < 0.05:
            return "neutral"
        return ", ".join(f"{name}" for name, val in top if val > 0.05)
