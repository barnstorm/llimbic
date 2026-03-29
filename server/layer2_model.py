"""
Layer 2 — Translation / Modulation Model

Uses a small local model (~15-33M parameters) for bounded translation tasks:
- Project Layer 1 state → 27-dim GoEmotions vector
- Modulate Layer 3 directives → bounded Layer 1 parameters

The model is NOT conversational. It performs structured extraction.
All persistent state exists outside the model. Calls are stateless.
"""

import torch
import json
import re
from transformers import AutoModelForCausalLM, AutoTokenizer
from emotion_coords import (
    DIMENSIONS, NUM_DIMS, DIM_INDEX, clamp_vector, default_vector,
    top_dimensions, format_state_prompt, format_modulation_prompt
)


class Layer2Model:
    """Small model for emotion vector projection and modulation."""

    def __init__(self, model_name: str = "HuggingFaceTB/SmolLM2-135M-Instruct",
                 device: str = "cuda"):
        """
        Load a small instruct-tuned model for Layer 2.
        We use SmolLM2-135M-Instruct as the smallest available instruct model
        that can follow structured output instructions. For Layer 2, we constrain
        its generation heavily (low temperature, short max_tokens).

        Note: True 15M models (TinyStories etc.) lack instruction-following
        capability needed for structured JSON output. SmolLM2-135M is the
        practical minimum that can reliably produce bounded structured output.
        We compensate by keeping generation very short and deterministic.
        """
        self.device = device
        self.model_name = model_name
        print(f"Layer2: Loading {model_name}...")
        self.tokenizer = AutoTokenizer.from_pretrained(model_name)
        self.model = AutoModelForCausalLM.from_pretrained(
            model_name,
            torch_dtype=torch.float16,
            device_map=device
        )
        self.model.eval()
        print(f"Layer2: Model loaded ({sum(p.numel() for p in self.model.parameters()) / 1e6:.1f}M params)")

        # Precompute dimension token IDs for constrained decoding
        self._dim_names = DIMENSIONS

    def _generate(self, prompt: str, max_new_tokens: int = 150,
                  temperature: float = 0.1) -> str:
        """Generate text from prompt with tight constraints."""
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
        # Decode only the generated tokens
        generated = outputs[0][inputs["input_ids"].shape[1]:]
        return self.tokenizer.decode(generated, skip_special_tokens=True).strip()

    def project(self, layer1_state: dict, recent_events: list[str],
                current_vector: list[float]) -> dict:
        """
        Northbound projection: Layer 1 state → updated 27-dim emotion vector.

        Uses the model to interpret state changes and adjust the emotion vector.
        Falls back to heuristic adjustment if model output is unparseable.
        """
        prompt = (
            "You are an emotion projection system. Given an NPC's physical state and recent events, "
            "output a JSON object with 'changes' (dict of emotion dimension names to delta values between -0.3 and +0.3) "
            "and 'summary' (one short sentence).\n\n"
            f"Emotion dimensions: {', '.join(self._dim_names[:10])}... (27 total from GoEmotions)\n\n"
            f"{format_state_prompt(layer1_state, recent_events, current_vector)}\n\n"
            "Output ONLY valid JSON. Example: {\"changes\": {\"joy\": -0.1, \"frustration\": 0.15}, \"summary\": \"tired and slightly annoyed\"}"
        )

        raw = self._generate(prompt, max_new_tokens=120, temperature=0.1)

        # Parse model output
        try:
            # Try to extract JSON from output
            json_match = re.search(r'\{[^{}]*\}', raw, re.DOTALL)
            if json_match:
                data = json.loads(json_match.group())
                changes = data.get("changes", {})
                summary = data.get("summary", "")
            else:
                changes = {}
                summary = raw[:80]
        except (json.JSONDecodeError, AttributeError):
            changes = {}
            summary = raw[:80] if raw else ""

        # Apply changes to current vector (with heuristic fallback)
        new_vector = list(current_vector) if current_vector else default_vector()

        # Model-driven changes
        for dim_name, delta in changes.items():
            if dim_name in DIM_INDEX:
                idx = DIM_INDEX[dim_name]
                delta = max(-0.3, min(0.3, float(delta)))
                new_vector[idx] += delta

        # Heuristic reinforcement based on Layer 1 state
        # These ensure the vector stays grounded even if model output is poor
        energy = layer1_state.get("energy", 50)
        hunger = layer1_state.get("hunger", 50)
        frustration = layer1_state.get("frustration", 0)
        safety = layer1_state.get("safety", 80)
        social = layer1_state.get("social_need", 50)

        # Low energy → sadness/relief up, excitement down
        if energy < 30:
            new_vector[DIM_INDEX["sadness"]] += 0.05
            new_vector[DIM_INDEX["excitement"]] -= 0.05
        # High frustration → anger/annoyance up
        if frustration > 0.5:
            new_vector[DIM_INDEX["anger"]] += frustration * 0.1
            new_vector[DIM_INDEX["annoyance"]] += frustration * 0.15
        # Low safety → fear/nervousness up
        if safety < 40:
            new_vector[DIM_INDEX["fear"]] += (40 - safety) / 200
            new_vector[DIM_INDEX["nervousness"]] += (40 - safety) / 150
        # High social need → desire up, joy down slightly
        if social > 70:
            new_vector[DIM_INDEX["desire"]] += 0.05
        # High hunger → annoyance up slightly
        if hunger > 70:
            new_vector[DIM_INDEX["annoyance"]] += 0.05

        new_vector = clamp_vector(new_vector)

        return {
            "vector": new_vector,
            "summary": summary or self._heuristic_summary(new_vector),
            "raw_model_output": raw[:200]
        }

    def modulate(self, directives: str, current_vector: list[float]) -> dict:
        """
        Southbound modulation: Layer 3 directives → Layer 1 modulation parameters.

        Converts high-level framing into bounded numeric parameters.
        """
        prompt = (
            "You are a behavior modulation system. Given a directive and current emotional state, "
            "output a JSON object with these bounded float parameters:\n"
            "- learning_rate_mod: 0.5-2.0 (how fast to adapt)\n"
            "- exploration_bias: 0.0-1.0 (explore vs exploit)\n"
            "- attention_weight: 0.0-1.0 (focus level)\n"
            "- interruption_sensitivity: 0.0-1.0 (how easily interrupted)\n"
            "- persistence_scale: 0.5-2.0 (how strongly to persist)\n\n"
            f"{format_modulation_prompt(directives, current_vector)}\n\n"
            "Output ONLY valid JSON."
        )

        raw = self._generate(prompt, max_new_tokens=80, temperature=0.1)

        # Parse with fallback
        params = {
            "learning_rate_mod": 1.0,
            "exploration_bias": 0.5,
            "attention_weight": 0.5,
            "interruption_sensitivity": 0.5,
            "persistence_scale": 1.0,
        }

        try:
            json_match = re.search(r'\{[^{}]*\}', raw, re.DOTALL)
            if json_match:
                data = json.loads(json_match.group())
                for key in params:
                    if key in data:
                        params[key] = float(data[key])
        except (json.JSONDecodeError, ValueError):
            pass

        # Clamp all parameters to valid ranges
        params["learning_rate_mod"] = max(0.5, min(2.0, params["learning_rate_mod"]))
        params["exploration_bias"] = max(0.0, min(1.0, params["exploration_bias"]))
        params["attention_weight"] = max(0.0, min(1.0, params["attention_weight"]))
        params["interruption_sensitivity"] = max(0.0, min(1.0, params["interruption_sensitivity"]))
        params["persistence_scale"] = max(0.5, min(2.0, params["persistence_scale"]))

        return params

    def _heuristic_summary(self, vec: list[float]) -> str:
        """Generate a short summary from the top emotion dimensions."""
        top = top_dimensions(vec, 3)
        if not top or top[0][1] < 0.05:
            return "neutral"
        return ", ".join(f"{name}" for name, val in top if val > 0.05)
