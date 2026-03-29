"""
Layer 2 — Translation / Modulation Model

Uses a small local model (~135M parameters) for bounded translation tasks:
- Project Layer 1 state → 27-dim GoEmotions vector
- Modulate Layer 3 directives → bounded Layer 1 parameters

Uses outlines for guaranteed structured JSON output.
All persistent state exists outside the model. Calls are stateless.
"""

import torch
from pydantic import BaseModel
from transformers import AutoModelForCausalLM, AutoTokenizer
import outlines
from emotion_coords import (
    DIMENSIONS, NUM_DIMS, DIM_INDEX, clamp_vector, default_vector,
    top_dimensions, format_state_prompt, format_modulation_prompt
)


# --- Output schemas for outlines structured generation ---

class ProjectionOutput(BaseModel):
    changes: dict[str, float]
    summary: str

class ModulationOutput(BaseModel):
    learning_rate_mod: float
    exploration_bias: float
    attention_weight: float
    interruption_sensitivity: float
    persistence_scale: float


class Layer2Model:
    """Small model for emotion vector projection and modulation."""

    def __init__(self, model_name: str = "HuggingFaceTB/SmolLM2-135M-Instruct",
                 device: str = "cuda"):
        self.device = device
        self.model_name = model_name
        print(f"Layer2: Loading {model_name}...")
        self.tokenizer = AutoTokenizer.from_pretrained(model_name)
        hf_model = AutoModelForCausalLM.from_pretrained(
            model_name,
            torch_dtype=torch.float16,
            device_map=device
        )
        hf_model.eval()
        print(f"Layer2: Model loaded ({sum(p.numel() for p in hf_model.parameters()) / 1e6:.1f}M params)")

        # Wrap with outlines for structured generation
        self._outlines_model = outlines.from_transformers(hf_model, self.tokenizer)

        # Pre-build generators (compiles FSM index per schema — avoids first-call latency)
        print("Layer2: Building structured generators...")
        self._project_gen = outlines.Generator(self._outlines_model, output_type=ProjectionOutput)
        self._modulate_gen = outlines.Generator(self._outlines_model, output_type=ModulationOutput)
        print("Layer2: Generators ready.")

        self._dim_names = DIMENSIONS

    def _format_prompt(self, prompt: str) -> str:
        """Apply chat template to a single-turn prompt."""
        messages = [{"role": "user", "content": prompt}]
        return self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )

    def project(self, layer1_state: dict, recent_events: list[str],
                current_vector: list[float]) -> dict:
        """
        Northbound projection: Layer 1 state → updated 27-dim emotion vector.

        Uses outlines structured generation to guarantee valid JSON output.
        Heuristic reinforcement is applied on top of model output.
        """
        prompt = self._format_prompt(
            "You are an emotion projection system. Given an NPC's physical state and recent events, "
            "output a JSON object with 'changes' (dict of emotion dimension names to delta values between -0.3 and +0.3) "
            "and 'summary' (one short sentence).\n\n"
            f"Emotion dimensions: {', '.join(self._dim_names[:10])}... (27 total from GoEmotions)\n\n"
            f"{format_state_prompt(layer1_state, recent_events, current_vector)}\n\n"
            "Output ONLY valid JSON. Example: {\"changes\": {\"joy\": -0.1, \"frustration\": 0.15}, \"summary\": \"tired and slightly annoyed\"}"
        )

        result = self._project_gen(prompt, max_tokens=120, temperature=0.1)
        changes = result.changes
        summary = result.summary

        # Apply changes to current vector
        new_vector = list(current_vector) if current_vector else default_vector()

        for dim_name, delta in changes.items():
            if dim_name in DIM_INDEX:
                idx = DIM_INDEX[dim_name]
                delta = max(-0.3, min(0.3, float(delta)))
                new_vector[idx] += delta

        # Heuristic reinforcement based on Layer 1 state
        energy = layer1_state.get("energy", 50)
        hunger = layer1_state.get("hunger", 50)
        frustration = layer1_state.get("frustration", 0)
        safety = layer1_state.get("safety", 80)
        social = layer1_state.get("social_need", 50)

        if energy < 30:
            new_vector[DIM_INDEX["sadness"]] += 0.05
            new_vector[DIM_INDEX["excitement"]] -= 0.05
        if frustration > 0.5:
            new_vector[DIM_INDEX["anger"]] += frustration * 0.1
            new_vector[DIM_INDEX["annoyance"]] += frustration * 0.15
        if safety < 40:
            new_vector[DIM_INDEX["fear"]] += (40 - safety) / 200
            new_vector[DIM_INDEX["nervousness"]] += (40 - safety) / 150
        if social > 70:
            new_vector[DIM_INDEX["desire"]] += 0.05
        if hunger > 70:
            new_vector[DIM_INDEX["annoyance"]] += 0.05

        new_vector = clamp_vector(new_vector)

        return {
            "vector": new_vector,
            "summary": summary or self._heuristic_summary(new_vector),
        }

    def modulate(self, directives: str, current_vector: list[float]) -> dict:
        """
        Southbound modulation: Layer 3 directives → Layer 1 modulation parameters.

        Uses outlines structured generation for guaranteed valid output.
        """
        prompt = self._format_prompt(
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

        result = self._modulate_gen(prompt, max_tokens=80, temperature=0.1)
        params = result.model_dump()

        # Clamp to valid ranges
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
