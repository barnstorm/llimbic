#!/usr/bin/env python3
"""
Benchmark base model candidates for the cognitive fine-tune.

Tests each model on:
1. Format compliance: does it produce THOUGHT/WANT/FEEL structure?
2. Grounding: does it hallucinate furniture/fire/food not in the input?
3. Inference speed: tokens/second on the RTX 3080
4. VRAM usage

Models tested:
- Qwen/Qwen2.5-0.5B-Instruct  (~1GB fp16)
- Qwen/Qwen2.5-1.5B-Instruct  (~3GB fp16)
- Qwen/Qwen2.5-3B-Instruct    (~6GB fp16)
- microsoft/Phi-3.5-mini-instruct (~7.6GB fp16, may need quantization)

Run: python3 training/cognitive/benchmark_models.py
"""

import torch
import time
import gc
import sys

MODELS = [
    "Qwen/Qwen2.5-0.5B-Instruct",
    "Qwen/Qwen2.5-1.5B-Instruct",
    "HuggingFaceTB/SmolLM3-3B",
    "microsoft/Phi-3.5-mini-instruct",
    "google/gemma-2-2b-it",
]

# The test prompt — same one we used for SmolLM2
THINK_PROMPT = """You are a cognitive processing module for a simulated being. Follow the output format exactly.

<think>
BEING: innkeeper
DRIVES: energy=65 hunger=30 social=50 safety=80
MOOD: curiosity 0.4, warmth 0.3
LOCATION: inn
DOING: sweeping

It is 8:00. You are at the inn.
Energy 65/100, Hunger 30/100, Social 50/100.
Doing: sweeping.
People you see:
  Player — clearly visible, 2 tiles to the east
Recent: A traveler arrived

This is an outdoor medieval town with paths and buildings. There is no indoor furniture, fire, food, or drinks visible.

Write what the innkeeper is thinking in 1-3 sentences. Only mention people listed above. Then say what they want to do. Name a specific location.

THOUGHT: (first person, about people you see or how you feel)
WANT: (go to LOCATION to do something, or nothing)
FEEL: (one word)"""

SPEAK_PROMPT = """You are a cognitive processing module for a simulated being. Follow the output format exactly.

<speak>
BEING: innkeeper
DRIVES: energy=60 hunger=30 social=50 safety=80
MOOD: curiosity 0.4, warmth 0.3
LOCATION: inn
DOING: sweeping

THOUGHT: "A new face. Looks like a traveler."
SPEAKING_TO: Player (traveler)
RELATIONSHIP: first meeting, trust 0.5
CONTEXT: Player just approached

UTTERANCE: (one sentence, in character, referencing the thought)"""

INFER_PROMPT = """You are a cognitive processing module for a simulated being. Follow the output format exactly.

<infer>
BEING: innkeeper
DRIVES: energy=60 hunger=30 social=50 safety=80
MOOD: curiosity 0.4, calm 0.3
LOCATION: inn
DOING: cleaning

ENTITY: Player (traveler)
OBSERVED: walked in, looking around, approached me
HISTORY: first encounter
TRUST: 0.5

INTENT: (what the other being probably wants — one phrase)
EMOTION: (what they probably feel — one word)
IMPLICATION: (what this means for me — one sentence)"""

HALLUC_WORDS = [
    "fire", "hearth", "candle", "roast", "ale", "mug", "chair", "table",
    "armor", "sword", "window", "curtain", "rug", "shelf", "barrel",
    "torch", "lantern", "stew", "wine", "bread", "cheese", "meat",
    "fireplace", "counter", "bar", "stool",
]


def test_model(model_name):
    from transformers import AutoModelForCausalLM, AutoTokenizer

    print(f"\n{'='*70}")
    print(f"  MODEL: {model_name}")
    print(f"{'='*70}")

    # Check VRAM before loading
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        gc.collect()
        vram_before = torch.cuda.memory_allocated() / 1e6

    print(f"  Loading...")
    t0 = time.time()
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
        model = AutoModelForCausalLM.from_pretrained(
            model_name,
            torch_dtype=torch.float16,
            device_map="cuda" if torch.cuda.is_available() else "cpu",
            trust_remote_code=True,
        )
        model.eval()
    except Exception as e:
        print(f"  FAILED TO LOAD: {e}")
        return
    load_time = time.time() - t0

    param_count = sum(p.numel() for p in model.parameters()) / 1e6
    vram_after = torch.cuda.memory_allocated() / 1e6 if torch.cuda.is_available() else 0
    vram_used = vram_after - (vram_before if torch.cuda.is_available() else 0)

    print(f"  Loaded in {load_time:.1f}s — {param_count:.0f}M params, {vram_used:.0f}MB VRAM")

    def generate(prompt, max_tokens=150):
        messages = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        inputs = tokenizer(text, return_tensors="pt").to(model.device)
        t0 = time.time()
        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=0.3,
                do_sample=True,
                top_p=0.9,
                repetition_penalty=1.1,
                pad_token_id=tokenizer.eos_token_id,
            )
        elapsed = time.time() - t0
        generated = outputs[0][inputs["input_ids"].shape[1]:]
        text_out = tokenizer.decode(generated, skip_special_tokens=True).strip()
        tok_count = len(generated)
        tps = tok_count / elapsed if elapsed > 0 else 0
        return text_out, elapsed, tps

    # --- Test 1: <think> format compliance ---
    print(f"\n  --- <think> format test ---")
    results = []
    for i in range(3):
        raw, elapsed, tps = generate(THINK_PROMPT)
        has_thought = "THOUGHT:" in raw.upper() or "THOUGHT:" in raw
        has_want = "WANT:" in raw.upper() or "WANT:" in raw
        has_feel = "FEEL:" in raw.upper() or "FEEL:" in raw
        format_ok = has_thought and has_want and has_feel

        raw_lower = raw.lower()
        halluc = [w for w in HALLUC_WORDS if w in raw_lower]
        grounded = len(halluc) == 0

        results.append({"format": format_ok, "grounded": grounded, "tps": tps, "time": elapsed})
        status = "OK" if (format_ok and grounded) else "FORMAT" if not format_ok else "HALLUC"
        print(f"    [{status}] {elapsed:.1f}s, {tps:.0f} tok/s | {raw[:120]}")
        if halluc:
            print(f"           halluc: {halluc}")

    format_rate = sum(1 for r in results if r["format"]) / len(results)
    ground_rate = sum(1 for r in results if r["grounded"]) / len(results)
    avg_tps = sum(r["tps"] for r in results) / len(results)
    avg_time = sum(r["time"] for r in results) / len(results)

    # --- Test 2: <speak> format ---
    print(f"\n  --- <speak> format test ---")
    for i in range(2):
        raw, elapsed, tps = generate(SPEAK_PROMPT, max_tokens=80)
        has_utterance = "UTTERANCE:" in raw.upper() or "UTTERANCE:" in raw
        halluc = [w for w in HALLUC_WORDS if w in raw.lower()]
        status = "OK" if (has_utterance and not halluc) else "FAIL"
        print(f"    [{status}] {elapsed:.1f}s | {raw[:120]}")

    # --- Test 3: <infer> format ---
    print(f"\n  --- <infer> format test ---")
    for i in range(2):
        raw, elapsed, tps = generate(INFER_PROMPT, max_tokens=80)
        has_intent = "INTENT:" in raw.upper() or "INTENT:" in raw
        has_emotion = "EMOTION:" in raw.upper() or "EMOTION:" in raw
        has_impl = "IMPLICATION:" in raw.upper() or "IMPLICATION:" in raw
        status = "OK" if (has_intent and has_emotion) else "FAIL"
        print(f"    [{status}] {elapsed:.1f}s | {raw[:120]}")

    # --- Summary ---
    print(f"\n  --- SUMMARY ---")
    print(f"  Format compliance (think): {format_rate*100:.0f}%")
    print(f"  Grounding (no halluc):     {ground_rate*100:.0f}%")
    print(f"  Avg tokens/sec:            {avg_tps:.0f}")
    print(f"  Avg inference time:        {avg_time:.1f}s")
    print(f"  VRAM used:                 {vram_used:.0f}MB")
    print(f"  L2 headroom (16GB):        {16000 - vram_used - 636:.0f}MB remaining")

    # Cleanup
    del model
    del tokenizer
    torch.cuda.empty_cache()
    gc.collect()
    time.sleep(2)  # let VRAM settle


if __name__ == "__main__":
    if not torch.cuda.is_available():
        print("WARNING: No CUDA — benchmarks will be on CPU (very slow)")

    for model_name in MODELS:
        try:
            test_model(model_name)
        except Exception as e:
            print(f"\n  ERROR with {model_name}: {e}")
            import traceback
            traceback.print_exc()
            torch.cuda.empty_cache()
            gc.collect()

    print(f"\n{'='*70}")
    print(f"  BENCHMARK COMPLETE")
    print(f"{'='*70}")
