"""
SmolLM2 Limbic System Training Script
======================================
Fine-tunes SmolLM2-135M-Instruct to function as an emotional processing layer.

Three input types:
  A) Sensory: 6D neural activation vector + context → emotions + attention + drives
  B) Thought: Inner monologue text (GoEmotions) → emotions + attention + drives
  C) Integrated: Both A + B → blended emotional state

Usage (Colab):
  1. Upload this file or paste cells into a Colab notebook
  2. Runtime > Change runtime type > T4 GPU (free tier is fine)
  3. Run cells in order

Usage (CLI):
  python limbic_training.py --mode train
  python limbic_training.py --mode eval --output-dir ./limbic-smollm2-lora
  python limbic_training.py --mode demo --output-dir ./limbic-smollm2-lora
"""

# %% [markdown]
# # SmolLM2 Limbic System Training
# Fine-tunes SmolLM2-135M-Instruct with LoRA to translate between
# neural activation vectors, text, and emotional states.

# %% Install dependencies
# !pip install -q torch transformers datasets peft trl accelerate bitsandbytes scipy

# %%
import json
import random
import math
import numpy as np
from typing import Optional
from dataclasses import dataclass, field, asdict

random.seed(42)
np.random.seed(42)

# ---------------------------------------------------------------------------
# 1. Emotion Reference Framework
# ---------------------------------------------------------------------------

# 6D continuous space: [valence, arousal, dominance, social_focus, temporal, certainty]
EMOTION_VECTORS_6D = {
    # Positive emotions
    "admiration":     [0.85, 0.50, 0.35, 0.85, 0.40, 0.75],
    "amusement":      [0.85, 0.65, 0.60, 0.65, 0.45, 0.70],
    "approval":       [0.80, 0.35, 0.65, 0.75, 0.50, 0.80],
    "caring":         [0.80, 0.40, 0.50, 0.90, 0.55, 0.70],
    "desire":         [0.70, 0.75, 0.55, 0.50, 0.80, 0.50],
    "excitement":     [0.85, 0.90, 0.65, 0.50, 0.75, 0.55],
    "gratitude":      [0.90, 0.40, 0.40, 0.85, 0.35, 0.85],
    "joy":            [0.95, 0.75, 0.70, 0.60, 0.55, 0.80],
    "love":           [0.95, 0.65, 0.45, 0.95, 0.50, 0.75],
    "optimism":       [0.85, 0.55, 0.65, 0.50, 0.90, 0.60],
    "pride":          [0.85, 0.60, 0.85, 0.40, 0.50, 0.85],
    "relief":         [0.80, 0.20, 0.55, 0.35, 0.35, 0.80],
    # Negative emotions
    "anger":          [0.10, 0.85, 0.75, 0.45, 0.40, 0.75],
    "annoyance":      [0.20, 0.60, 0.55, 0.45, 0.40, 0.65],
    "disappointment": [0.15, 0.30, 0.25, 0.45, 0.30, 0.65],
    "disapproval":    [0.15, 0.45, 0.65, 0.70, 0.40, 0.75],
    "disgust":        [0.05, 0.60, 0.60, 0.35, 0.30, 0.85],
    "embarrassment":  [0.15, 0.70, 0.10, 0.80, 0.35, 0.40],
    "fear":           [0.05, 0.85, 0.10, 0.30, 0.75, 0.15],
    "grief":          [0.05, 0.55, 0.10, 0.50, 0.15, 0.60],
    "nervousness":    [0.20, 0.75, 0.20, 0.40, 0.80, 0.20],
    "remorse":        [0.10, 0.45, 0.20, 0.70, 0.25, 0.65],
    "sadness":        [0.10, 0.25, 0.20, 0.45, 0.25, 0.60],
    # Ambiguous / cognitive
    "confusion":      [0.35, 0.55, 0.25, 0.40, 0.50, 0.10],
    "curiosity":      [0.65, 0.65, 0.50, 0.45, 0.75, 0.20],
    "realization":    [0.60, 0.60, 0.55, 0.35, 0.50, 0.85],
    "surprise":       [0.50, 0.80, 0.30, 0.40, 0.50, 0.10],
    # Neutral
    "neutral":        [0.50, 0.25, 0.50, 0.50, 0.50, 0.50],
}

EMOTION_NAMES = list(EMOTION_VECTORS_6D.keys())
EMOTION_MATRIX = np.array([EMOTION_VECTORS_6D[e] for e in EMOTION_NAMES])  # (28, 6)

# Dimension labels for prompt formatting
DIM_LABELS = ["valence", "arousal", "dominance", "social_focus", "temporal", "certainty"]

# GoEmotions simplified label order (alphabetical, 28 labels, index 27 = neutral)
# Source: https://github.com/google-research/google-research/tree/master/goemotions
GOEMOTIONS_LABELS = [
    "admiration", "amusement", "anger", "annoyance", "approval", "caring",
    "confusion", "curiosity", "desire", "disappointment", "disapproval",
    "disgust", "embarrassment", "excitement", "fear", "gratitude", "grief",
    "joy", "love", "nervousness", "optimism", "pride", "realization",
    "relief", "remorse", "sadness", "surprise", "neutral"
]

# ---------------------------------------------------------------------------
# 2. Attention & Drive Mappings
# ---------------------------------------------------------------------------

ATTENTION_MAP = {
    "fear":           ["threat_source", "escape_route", "hiding_place"],
    "anger":          ["threat_source", "obstacle", "confrontation_target"],
    "curiosity":      ["novel_object", "unknown_source", "unusual_pattern"],
    "surprise":       ["stimulus_source", "environment_scan", "change_location"],
    "joy":            ["reward_source", "social_partner", "positive_stimulus"],
    "excitement":     ["opportunity_source", "action_target", "reward_source"],
    "sadness":        ["loss_source", "support_source", "withdrawal_location"],
    "grief":          ["loss_source", "memorial", "support_source"],
    "disgust":        ["contaminant_source", "avoidance_path", "clean_area"],
    "love":           ["social_partner", "bonding_opportunity", "shared_activity"],
    "caring":         ["social_partner", "need_source", "help_opportunity"],
    "admiration":     ["admired_entity", "achievement_source", "social_partner"],
    "gratitude":      ["benefactor", "gift_source", "social_partner"],
    "pride":          ["achievement_source", "audience", "display_opportunity"],
    "embarrassment":  ["social_observer", "escape_route", "concealment"],
    "nervousness":    ["threat_source", "safety_check", "social_observer"],
    "confusion":      ["information_source", "guidance_source", "pattern_search"],
    "relief":         ["resolved_threat", "safety_confirmation", "rest_location"],
    "disappointment": ["failed_expectation", "alternative_path", "reassessment"],
    "disapproval":    ["norm_violation", "social_target", "correction_opportunity"],
    "annoyance":      ["irritant_source", "avoidance_path", "resolution_target"],
    "remorse":        ["affected_party", "repair_opportunity", "self_reflection"],
    "optimism":       ["opportunity_source", "goal_target", "resource_assessment"],
    "amusement":      ["humor_source", "social_partner", "play_opportunity"],
    "desire":         ["desired_object", "acquisition_path", "rival_assessment"],
    "approval":       ["approved_entity", "social_signal", "reinforcement_target"],
    "realization":    ["insight_source", "implication_scan", "knowledge_update"],
    "neutral":        ["general_scan", "routine_check"],
}

DRIVE_MAP = {
    "fear":           {"avoid": 0.8, "flee": 0.7, "freeze": 0.4, "assess": 0.3},
    "anger":          {"confront": 0.7, "assert": 0.6, "avoid": 0.3},
    "curiosity":      {"explore": 0.9, "investigate": 0.8, "approach": 0.5},
    "surprise":       {"assess": 0.8, "orient": 0.7, "freeze": 0.3},
    "joy":            {"explore": 0.6, "social": 0.7, "play": 0.5},
    "excitement":     {"explore": 0.8, "approach": 0.7, "social": 0.5},
    "sadness":        {"rest": 0.7, "withdraw": 0.6, "social": 0.3},
    "grief":          {"withdraw": 0.8, "rest": 0.7, "social": 0.4},
    "disgust":        {"avoid": 0.9, "withdraw": 0.6, "clean": 0.5},
    "love":           {"social": 0.9, "approach": 0.8, "protect": 0.6},
    "caring":         {"social": 0.8, "help": 0.8, "approach": 0.6},
    "admiration":     {"approach": 0.6, "social": 0.5, "observe": 0.7},
    "gratitude":      {"social": 0.7, "reciprocate": 0.6, "approach": 0.5},
    "pride":          {"display": 0.6, "social": 0.5, "assert": 0.5},
    "embarrassment":  {"withdraw": 0.7, "hide": 0.6, "freeze": 0.4},
    "nervousness":    {"assess": 0.7, "avoid": 0.5, "freeze": 0.4},
    "confusion":      {"investigate": 0.7, "seek_help": 0.5, "pause": 0.6},
    "relief":         {"rest": 0.7, "social": 0.4, "explore": 0.3},
    "disappointment": {"reassess": 0.6, "withdraw": 0.5, "rest": 0.4},
    "disapproval":    {"assert": 0.6, "correct": 0.5, "withdraw": 0.4},
    "annoyance":      {"avoid": 0.5, "assert": 0.5, "confront": 0.3},
    "remorse":        {"repair": 0.7, "social": 0.5, "withdraw": 0.4},
    "optimism":       {"explore": 0.7, "plan": 0.7, "social": 0.5},
    "amusement":      {"social": 0.7, "play": 0.7, "explore": 0.4},
    "desire":         {"approach": 0.8, "acquire": 0.7, "plan": 0.5},
    "approval":       {"social": 0.6, "reinforce": 0.6, "approach": 0.4},
    "realization":    {"plan": 0.7, "investigate": 0.5, "social": 0.3},
    "neutral":        {"monitor": 0.5, "rest": 0.4},
}

# Context keywords that add attention targets
CONTEXT_ATTENTION_MODS = {
    "noise": ["sound_source"],
    "movement": ["motion_source", "change_location"],
    "social": ["social_partner", "face", "interaction_potential"],
    "dark": ["light_source", "obstacle"],
    "crowd": ["social_partner", "escape_route", "threat_scan"],
    "alone": ["environment_scan", "self_reflection"],
    "food": ["food_source", "hunger_check"],
    "danger": ["threat_source", "escape_route", "weapon"],
    "novel": ["novel_object", "unusual_pattern"],
    "familiar": ["recognition_target", "memory_check"],
}

# Sensory context templates for data generation
SENSORY_CONTEXTS = [
    "sudden unexpected stimulus",
    "novel object detected nearby",
    "familiar environment, routine patrol",
    "social encounter with known entity",
    "social encounter with stranger",
    "loud noise from unknown direction",
    "obstacle blocking intended path",
    "pleasant stimulus from food source",
    "threat detected in peripheral vision",
    "calm environment, low activity",
    "crowded social gathering",
    "isolated quiet area",
    "movement detected behind cover",
    "familiar face approaching",
    "unfamiliar territory exploration",
    "recently visited safe location",
    "rapid environmental change",
    "slow predictable environment",
    "darkness with limited visibility",
    "bright open area with clear sightlines",
    "receiving gift or reward",
    "witnessing conflict between others",
    "discovering broken or damaged object",
    "completing a difficult task",
    "failing to achieve a goal",
    "being observed by others",
    "finding something lost",
    "approaching deadline or time pressure",
    "pleasant weather and surroundings",
    "uncomfortable physical conditions",
]


# ---------------------------------------------------------------------------
# 3. Data Generation Utilities
# ---------------------------------------------------------------------------

def vec_to_emotions(vec_6d: list[float], top_k: int = 3, threshold: float = 0.6) -> dict[str, float]:
    """Map a 6D vector to nearest emotion categories with intensities."""
    vec = np.array(vec_6d)
    dists = np.linalg.norm(EMOTION_MATRIX - vec, axis=1)
    # Convert distance to similarity (inverse, normalized)
    max_dist = math.sqrt(6)  # max possible distance in unit hypercube
    similarities = 1.0 - (dists / max_dist)

    # Filter by threshold and take top-k
    candidates = [(EMOTION_NAMES[i], float(similarities[i]))
                  for i in range(len(EMOTION_NAMES))
                  if similarities[i] >= threshold and EMOTION_NAMES[i] != "neutral"]

    if not candidates:
        # Fallback: take the single nearest
        best_idx = int(np.argmin(dists))
        return {EMOTION_NAMES[best_idx]: round(float(similarities[best_idx]), 2)}

    candidates.sort(key=lambda x: x[1], reverse=True)
    candidates = candidates[:top_k]

    # Normalize intensities to sum to 1.0
    total = sum(c[1] for c in candidates)
    return {name: round(intensity / total, 2) for name, intensity in candidates}


def emotions_to_attention(emotions: dict[str, float], context: str = "") -> list[str]:
    """Derive attention focus targets from emotional state + context."""
    targets = set()
    for emo, intensity in emotions.items():
        if emo in ATTENTION_MAP and intensity >= 0.15:
            n_targets = max(1, int(len(ATTENTION_MAP[emo]) * intensity))
            targets.update(ATTENTION_MAP[emo][:n_targets])

    # Context modulation
    context_lower = context.lower()
    for keyword, extra_targets in CONTEXT_ATTENTION_MODS.items():
        if keyword in context_lower:
            targets.update(extra_targets)

    return sorted(targets)[:5]  # Cap at 5


def emotions_to_drives(emotions: dict[str, float]) -> dict[str, float]:
    """Derive motivational drives from emotional state."""
    drives: dict[str, float] = {}
    for emo, intensity in emotions.items():
        if emo in DRIVE_MAP:
            for drive, base_strength in DRIVE_MAP[emo].items():
                combined = base_strength * intensity
                drives[drive] = max(drives.get(drive, 0.0), combined)

    # Normalize top drives
    if drives:
        items = sorted(drives.items(), key=lambda x: x[1], reverse=True)[:4]
        total = sum(v for _, v in items)
        return {k: round(v / total, 2) for k, v in items}
    return {"monitor": 0.6, "rest": 0.4}


def reverse_engineer_vector(emotions: dict[str, float]) -> list[float]:
    """Given emotion labels, produce a plausible 6D sensory vector."""
    vec = np.zeros(6)
    total_weight = 0.0
    for emo, intensity in emotions.items():
        if emo in EMOTION_VECTORS_6D:
            ref = np.array(EMOTION_VECTORS_6D[emo])
            vec += ref * intensity
            total_weight += intensity
    if total_weight > 0:
        vec /= total_weight
    # Add noise (sensory vectors aren't perfect matches)
    noise = np.random.normal(0, 0.08, 6)
    vec = np.clip(vec + noise, 0.0, 1.0)
    return [round(float(v), 2) for v in vec]


# ---------------------------------------------------------------------------
# 4. Prompt Formatting (SmolLM2 ChatML template)
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = (
    "You are a limbic system — an emotional processing layer that translates "
    "between neural activations, thoughts, and emotional states. You receive "
    "sensory data (6D neural activation vectors) and/or inner thoughts, and "
    "output structured emotional assessments including emotion labels with "
    "intensities, attention focus priorities, and motivational drives."
)


def format_sensory_input(vec_6d: list[float], context: str) -> str:
    dims = ", ".join(f"{DIM_LABELS[i]}={vec_6d[i]:.2f}" for i in range(6))
    return f"Neural Activation: [{dims}]\nContext: {context}"


def format_thought_input(thought: str) -> str:
    return f"Inner Thought: \"{thought}\""


def format_integrated_input(vec_6d: list[float], context: str, thought: str) -> str:
    dims = ", ".join(f"{DIM_LABELS[i]}={vec_6d[i]:.2f}" for i in range(6))
    return (
        f"Neural Activation: [{dims}]\n"
        f"Context: {context}\n"
        f"Inner Thought: \"{thought}\""
    )


def format_output(emotions: dict[str, float], attention: list[str], drives: dict[str, float]) -> str:
    emo_str = ", ".join(f"{k}: {v}" for k, v in emotions.items())
    att_str = ", ".join(attention)
    drv_str = ", ".join(f"{k}: {v}" for k, v in drives.items())
    return (
        f"Emotional State: {emo_str}\n"
        f"Attention Focus: {att_str}\n"
        f"Motivational Drive: {drv_str}"
    )


def make_chat_example(user_content: str, assistant_content: str) -> dict:
    """Format as SmolLM2 ChatML template."""
    return {
        "text": (
            f"<|im_start|>system\n{SYSTEM_PROMPT}<|im_end|>\n"
            f"<|im_start|>user\n{user_content}<|im_end|>\n"
            f"<|im_start|>assistant\n{assistant_content}<|im_end|>"
        )
    }


# ---------------------------------------------------------------------------
# 5. Generate Training Data
# ---------------------------------------------------------------------------

def generate_sensory_examples(n: int = 5000) -> list[dict]:
    """Type 1: Neural vector + context -> emotions + attention + drives."""
    examples = []
    for _ in range(n):
        # Generate a random 6D vector biased toward emotion clusters
        if random.random() < 0.7:
            # 70%: near an existing emotion (within 0.25 radius)
            base_emo = random.choice(EMOTION_NAMES)
            base_vec = np.array(EMOTION_VECTORS_6D[base_emo])
            noise = np.random.normal(0, 0.12, 6)
            vec = np.clip(base_vec + noise, 0.0, 1.0)
        else:
            # 30%: truly random (tests interpolation)
            vec = np.random.uniform(0.0, 1.0, 6)
        vec_6d = [round(float(v), 2) for v in vec]

        context = random.choice(SENSORY_CONTEXTS)
        emotions = vec_to_emotions(vec_6d)
        attention = emotions_to_attention(emotions, context)
        drives = emotions_to_drives(emotions)

        user = format_sensory_input(vec_6d, context)
        assistant = format_output(emotions, attention, drives)
        examples.append(make_chat_example(user, assistant))

    return examples


def generate_thought_examples_synthetic(n: int = 2000) -> list[dict]:
    """Synthetic thought examples as fallback if GoEmotions unavailable."""
    templates = {
        "joy": [
            "This is wonderful, everything is going so well today",
            "I feel great about how things turned out",
            "What a beautiful moment, I'm truly happy",
        ],
        "fear": [
            "Something doesn't feel right, I need to be careful",
            "I'm terrified of what might happen next",
            "That sound... what if it's dangerous?",
        ],
        "anger": [
            "This is completely unacceptable, how could they do this",
            "I'm so frustrated with this situation",
            "They had no right to do that",
        ],
        "sadness": [
            "I miss the way things used to be",
            "Everything feels empty and pointless right now",
            "I wish I could go back and change what happened",
        ],
        "curiosity": [
            "What is that? I've never seen anything like it",
            "I wonder what would happen if I tried something different",
            "There's something interesting about this pattern",
        ],
        "surprise": [
            "I did not expect that at all",
            "Wait, what just happened?",
            "This completely changes everything I thought I knew",
        ],
        "disgust": [
            "That's revolting, I can't stand to look at it",
            "How could anyone think that's acceptable",
            "I need to get away from this",
        ],
        "nervousness": [
            "I have a bad feeling about this",
            "What if I mess this up completely",
            "Everyone is watching and I'm not ready",
        ],
        "gratitude": [
            "I'm so thankful for what they did",
            "I don't know what I'd do without their help",
            "That was incredibly kind of them",
        ],
        "confusion": [
            "None of this makes any sense",
            "I thought I understood but now I'm completely lost",
            "How do these pieces fit together?",
        ],
        "excitement": [
            "I can't wait to see what happens next!",
            "This is going to be amazing",
            "Finally, the moment I've been waiting for",
        ],
        "disappointment": [
            "I really thought this would work out differently",
            "All that effort for nothing",
            "They let me down again",
        ],
    }

    examples = []
    for _ in range(n):
        emo = random.choice(list(templates.keys()))
        thought = random.choice(templates[emo])
        # Add some variation
        if random.random() < 0.3:
            secondary = random.choice([e for e in templates if e != emo])
            emotions = {emo: round(random.uniform(0.5, 0.8), 2),
                        secondary: round(random.uniform(0.1, 0.3), 2)}
        else:
            emotions = {emo: round(random.uniform(0.6, 0.9), 2)}

        # Normalize
        total = sum(emotions.values())
        emotions = {k: round(v / total, 2) for k, v in emotions.items()}

        attention = emotions_to_attention(emotions)
        drives = emotions_to_drives(emotions)

        user = format_thought_input(thought)
        assistant = format_output(emotions, attention, drives)
        examples.append(make_chat_example(user, assistant))

    return examples


def generate_thought_examples_goemotions(n: int = 10000) -> list[dict]:
    """Type 2: Use GoEmotions dataset for human-labeled thought examples.

    Dataset: google-research-datasets/go_emotions (simplified config)
    Labels: 28 categories in alphabetical order, index 27 = neutral.
    Reference: https://github.com/google-research/google-research/tree/master/goemotions
    """
    from datasets import load_dataset

    ds = load_dataset("google-research-datasets/go_emotions", "simplified", split="train")
    print(f"Loaded GoEmotions: {len(ds)} examples")

    examples = []
    indices = list(range(len(ds)))
    random.shuffle(indices)

    for idx in indices:
        if len(examples) >= n:
            break

        row = ds[idx]
        text = row["text"].strip()
        label_ids = row["labels"]

        # Skip neutral-only or empty
        non_neutral = [lid for lid in label_ids if lid < 27]
        if not non_neutral or len(text) < 10 or len(text) > 300:
            continue

        # Build emotion dict with intensities
        emotions = {}
        if len(non_neutral) == 1:
            emotions[GOEMOTIONS_LABELS[non_neutral[0]]] = round(random.uniform(0.6, 0.9), 2)
        else:
            for i, lid in enumerate(non_neutral[:3]):
                # First label strongest, diminishing
                intensity = round(random.uniform(0.4, 0.8) * (0.8 ** i), 2)
                emotions[GOEMOTIONS_LABELS[lid]] = max(0.1, intensity)

        # Normalize
        total = sum(emotions.values())
        emotions = {k: round(v / total, 2) for k, v in emotions.items()}

        attention = emotions_to_attention(emotions)
        drives = emotions_to_drives(emotions)

        user = format_thought_input(text)
        assistant = format_output(emotions, attention, drives)
        examples.append(make_chat_example(user, assistant))

    return examples


def generate_integrated_examples(
    thought_examples: list[dict], n: int = 10000
) -> list[dict]:
    """Type 3: Combined sensory + thought -> integrated emotional state."""
    examples = []
    contexts = SENSORY_CONTEXTS

    for _ in range(n):
        pattern = random.choices(
            ["reinforce", "reappraise", "conflict", "cognitive_dominant"],
            weights=[0.35, 0.20, 0.20, 0.25],
            k=1
        )[0]

        # Pick a base emotion set
        base_emo = random.choice(EMOTION_NAMES[:-1])  # exclude neutral
        base_ref = EMOTION_VECTORS_6D[base_emo]

        if pattern == "reinforce":
            # Sensory and thought agree -> amplified output
            vec = reverse_engineer_vector({base_emo: 0.8})
            thought_templates = {
                "fear": "Something is very wrong here, I need to get away",
                "joy": "This is exactly what I was hoping for, wonderful",
                "anger": "This is infuriating, completely unacceptable",
                "sadness": "I feel so heavy and empty inside",
                "curiosity": "What is this? I have to find out more",
                "surprise": "I never expected this, how is this possible",
                "disgust": "This is absolutely revolting",
                "excitement": "This is incredible, I can barely contain myself",
                "nervousness": "I have a terrible feeling about what's coming",
                "love": "My heart is full just being near them",
                "caring": "I need to make sure they're okay",
                "gratitude": "I can't believe how generous they've been",
            }
            thought = thought_templates.get(base_emo, f"I feel {base_emo}")
            context = random.choice(contexts)

            # Amplified: boost primary emotion
            emotions = {base_emo: round(random.uniform(0.7, 0.9), 2)}
            if random.random() < 0.4:
                # Add a congruent secondary
                close_emos = _find_close_emotions(base_emo, n=3)
                if close_emos:
                    sec = random.choice(close_emos)
                    emotions[sec] = round(random.uniform(0.1, 0.3), 2)

        elif pattern == "reappraise":
            # Sensory suggests one thing, thought reframes it
            sensory_emo = random.choice(["fear", "anger", "nervousness", "surprise", "disgust"])
            vec = reverse_engineer_vector({sensory_emo: 0.8})
            context = random.choice(contexts)

            reappraisal_thoughts = [
                "Actually, this is perfectly normal, nothing to worry about",
                "Wait, I've seen this before, it's harmless",
                "Now that I think about it, this could be a good thing",
                "I was wrong about this, it's not what I thought",
                "There's a simple explanation for this",
            ]
            thought = random.choice(reappraisal_thoughts)

            # Output: relief/calm, reduced original emotion
            emotions = {"relief": round(random.uniform(0.4, 0.6), 2)}
            if random.random() < 0.5:
                emotions[sensory_emo] = round(random.uniform(0.1, 0.2), 2)
            if random.random() < 0.3:
                emotions["realization"] = round(random.uniform(0.1, 0.3), 2)

        elif pattern == "conflict":
            # Sources disagree
            sensory_emo = random.choice(["curiosity", "excitement", "desire", "joy"])
            thought_emo = random.choice(["fear", "nervousness", "disapproval"])
            vec = reverse_engineer_vector({sensory_emo: 0.7})
            context = random.choice(contexts)

            conflict_thoughts = [
                "But this could be dangerous, I should be careful",
                "I want to but something tells me not to",
                "This looks interesting but the risk is too high",
                "My instincts say go but my mind says stop",
                "I'm drawn to this but I know better",
            ]
            thought = random.choice(conflict_thoughts)

            # Output: blend with tension
            emotions = {
                sensory_emo: round(random.uniform(0.2, 0.4), 2),
                thought_emo: round(random.uniform(0.3, 0.5), 2),
            }
            if random.random() < 0.4:
                emotions["confusion"] = round(random.uniform(0.1, 0.2), 2)

        else:  # cognitive_dominant
            # Neutral sensory, strong thought
            vec = reverse_engineer_vector({"neutral": 0.9})
            context = "calm environment, low activity"

            cog_emo = random.choice(["sadness", "joy", "anger", "love",
                                     "gratitude", "remorse", "optimism", "grief"])
            cog_thoughts = {
                "sadness": "I really miss them, wish they were here",
                "joy": "Thinking about all the good times makes me smile",
                "anger": "I still can't believe they did that to me",
                "love": "Just thinking about them fills me with warmth",
                "gratitude": "I'm so lucky to have had that experience",
                "remorse": "I should have handled that differently",
                "optimism": "Things are going to get better, I can feel it",
                "grief": "The loss still weighs heavy on my heart",
            }
            thought = cog_thoughts.get(cog_emo, f"I feel deeply {cog_emo}")

            # Thought dominates
            emotions = {cog_emo: round(random.uniform(0.6, 0.8), 2)}
            if random.random() < 0.3:
                secondary = random.choice(_find_close_emotions(cog_emo, n=2) or ["neutral"])
                emotions[secondary] = round(random.uniform(0.1, 0.3), 2)

        # Normalize emotions
        total = sum(emotions.values())
        emotions = {k: round(v / total, 2) for k, v in emotions.items()}

        attention = emotions_to_attention(emotions, context)
        drives = emotions_to_drives(emotions)

        user = format_integrated_input(vec, context, thought)
        assistant = format_output(emotions, attention, drives)
        examples.append(make_chat_example(user, assistant))

    return examples


def _find_close_emotions(emo: str, n: int = 3) -> list[str]:
    """Find emotions close in 6D space to the given one."""
    if emo not in EMOTION_VECTORS_6D:
        return []
    ref = np.array(EMOTION_VECTORS_6D[emo])
    dists = [(name, np.linalg.norm(np.array(EMOTION_VECTORS_6D[name]) - ref))
             for name in EMOTION_NAMES if name != emo and name != "neutral"]
    dists.sort(key=lambda x: x[1])
    return [d[0] for d in dists[:n]]


# ---------------------------------------------------------------------------
# 6. Training Pipeline
# ---------------------------------------------------------------------------

BASE_MODEL_ID = "HuggingFaceTB/SmolLM2-135M-Instruct"
DEFAULT_OUTPUT_DIR = "./limbic-smollm2-lora"


def build_dataset(use_goemotions: bool = True):
    """Generate all training data and return as HuggingFace Dataset."""
    from datasets import Dataset

    print("Generating sensory examples (5,000)...")
    sensory = generate_sensory_examples(5000)

    if use_goemotions:
        print("Loading GoEmotions and generating thought examples (10,000)...")
        try:
            thought = generate_thought_examples_goemotions(10000)
        except Exception as e:
            print(f"GoEmotions load failed ({e}), using synthetic fallback...")
            thought = generate_thought_examples_synthetic(10000)
    else:
        print("Generating synthetic thought examples (10,000)...")
        thought = generate_thought_examples_synthetic(10000)

    print("Generating integrated examples (10,000)...")
    integrated = generate_integrated_examples(thought, 10000)

    all_examples = sensory + thought + integrated
    random.shuffle(all_examples)

    print(f"Total examples: {len(all_examples)}")
    print(f"  Sensory: {len(sensory)}")
    print(f"  Thought: {len(thought)}")
    print(f"  Integrated: {len(integrated)}")

    ds = Dataset.from_list(all_examples)

    # 95/5 train/eval split
    split = ds.train_test_split(test_size=0.05, seed=42)
    return split["train"], split["test"]


def train(
    output_dir: str = DEFAULT_OUTPUT_DIR,
    num_epochs: int = 3,
    batch_size: int = 8,
    gradient_accumulation_steps: int = 2,
    learning_rate: float = 2e-4,
    max_seq_length: int = 512,
    use_goemotions: bool = True,
):
    """Full training pipeline."""
    import torch
    from transformers import (
        AutoModelForCausalLM,
        AutoTokenizer,
        TrainingArguments,
        BitsAndBytesConfig,
    )
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    from trl import SFTTrainer

    # --- Data ---
    train_ds, eval_ds = build_dataset(use_goemotions=use_goemotions)
    print(f"Train: {len(train_ds)}, Eval: {len(eval_ds)}")

    # --- Model ---
    model_id = BASE_MODEL_ID
    print(f"Loading {model_id}...")

    # 4-bit quantization for memory efficiency
    use_bf16 = torch.cuda.is_bf16_supported() if torch.cuda.is_available() else False
    compute_dtype = torch.bfloat16 if use_bf16 else torch.float16

    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=compute_dtype,
        bnb_4bit_use_double_quant=True,
    )

    tokenizer = AutoTokenizer.from_pretrained(model_id)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"

    model = AutoModelForCausalLM.from_pretrained(
        model_id,
        quantization_config=bnb_config,
        device_map="auto",
        torch_dtype=compute_dtype,
    )
    model = prepare_model_for_kbit_training(model)

    # --- LoRA ---
    # SmolLM2-135M uses LlamaForCausalLM architecture with q_proj, v_proj
    lora_config = LoraConfig(
        r=8,
        lora_alpha=16,
        target_modules=["q_proj", "v_proj"],
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # --- Training ---
    training_args = TrainingArguments(
        output_dir=output_dir,
        num_train_epochs=num_epochs,
        per_device_train_batch_size=batch_size,
        per_device_eval_batch_size=batch_size,
        gradient_accumulation_steps=gradient_accumulation_steps,
        learning_rate=learning_rate,
        lr_scheduler_type="cosine",
        warmup_steps=100,
        weight_decay=0.01,
        fp16=not use_bf16,
        bf16=use_bf16,
        logging_steps=50,
        eval_strategy="steps",
        eval_steps=500,
        save_strategy="steps",
        save_steps=500,
        save_total_limit=2,
        load_best_model_at_end=True,
        metric_for_best_model="eval_loss",
        report_to="none",
        optim="paged_adamw_8bit",
        gradient_checkpointing=True,
    )

    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=train_ds,
        eval_dataset=eval_ds,
        processing_class=tokenizer,
        max_length=max_seq_length,
    )

    print("Starting training...")
    trainer.train()

    # Save
    print(f"Saving to {output_dir}...")
    trainer.save_model(output_dir)
    tokenizer.save_pretrained(output_dir)

    return model, tokenizer


# ---------------------------------------------------------------------------
# 7. Inference & Evaluation
# ---------------------------------------------------------------------------

def load_trained_model(model_dir: str = DEFAULT_OUTPUT_DIR):
    """Load the fine-tuned model for inference."""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
    from peft import PeftModel

    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_use_double_quant=True,
    )

    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    base_model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL_ID,
        quantization_config=bnb_config,
        device_map="auto",
        torch_dtype=torch.float16,
    )
    model = PeftModel.from_pretrained(base_model, model_dir)
    model.eval()

    return model, tokenizer


def infer(model, tokenizer, user_input: str, max_new_tokens: int = 200) -> str:
    """Run a single limbic inference."""
    import torch

    prompt = (
        f"<|im_start|>system\n{SYSTEM_PROMPT}<|im_end|>\n"
        f"<|im_start|>user\n{user_input}<|im_end|>\n"
        f"<|im_start|>assistant\n"
    )

    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            temperature=0.3,
            top_p=0.9,
            do_sample=True,
            repetition_penalty=1.1,
            pad_token_id=tokenizer.eos_token_id,
        )

    response = tokenizer.decode(outputs[0][inputs["input_ids"].shape[1]:],
                                skip_special_tokens=True)
    return response.strip()


def parse_limbic_output(text: str) -> dict:
    """Parse structured limbic output into dict."""
    result = {"emotions": {}, "attention": [], "drives": {}}
    for line in text.strip().split("\n"):
        line = line.strip()
        if line.startswith("Emotional State:"):
            parts = line.replace("Emotional State:", "").strip()
            for pair in parts.split(","):
                pair = pair.strip()
                if ":" in pair:
                    k, v = pair.rsplit(":", 1)
                    try:
                        result["emotions"][k.strip()] = float(v.strip())
                    except ValueError:
                        pass
        elif line.startswith("Attention Focus:"):
            parts = line.replace("Attention Focus:", "").strip()
            result["attention"] = [p.strip() for p in parts.split(",") if p.strip()]
        elif line.startswith("Motivational Drive:"):
            parts = line.replace("Motivational Drive:", "").strip()
            for pair in parts.split(","):
                pair = pair.strip()
                if ":" in pair:
                    k, v = pair.rsplit(":", 1)
                    try:
                        result["drives"][k.strip()] = float(v.strip())
                    except ValueError:
                        pass
    return result


def evaluate(model, tokenizer, n_examples: int = 50):
    """Run evaluation on test scenarios."""
    print("=" * 60)
    print("EVALUATION")
    print("=" * 60)

    test_cases = [
        (
            "Pure sensory: high arousal + low valence (fear-like)",
            format_sensory_input([0.10, 0.85, 0.10, 0.30, 0.75, 0.15], "sudden stimulus"),
            "fear",
        ),
        (
            "Pure sensory: high valence + moderate arousal (joy-like)",
            format_sensory_input([0.90, 0.70, 0.70, 0.60, 0.55, 0.80], "pleasant environment"),
            "joy",
        ),
        (
            "Pure sensory: curiosity vector",
            format_sensory_input([0.65, 0.65, 0.50, 0.45, 0.75, 0.20], "novel object detected"),
            "curiosity",
        ),
        (
            "Pure thought: excitement",
            format_thought_input("I can't believe this is happening, this is amazing!"),
            "excitement",
        ),
        (
            "Pure thought: fear",
            format_thought_input("Something is following me and I can't see what it is"),
            "fear",
        ),
        (
            "Pure thought: sadness",
            format_thought_input("They're gone and they're never coming back"),
            "sadness",
        ),
        (
            "Reinforcement: fear vector + fearful thought",
            format_integrated_input(
                [0.10, 0.85, 0.10, 0.30, 0.75, 0.15],
                "dark alley, movement detected",
                "I'm terrified, something is out there"
            ),
            "fear",
        ),
        (
            "Reappraisal: fear vector + calming thought",
            format_integrated_input(
                [0.10, 0.85, 0.10, 0.30, 0.75, 0.15],
                "sudden noise",
                "Oh, it's just the wind. Nothing to worry about."
            ),
            "relief",
        ),
        (
            "Conflict: curiosity vector + cautious thought",
            format_integrated_input(
                [0.65, 0.65, 0.50, 0.45, 0.75, 0.20],
                "novel object in restricted area",
                "This could be dangerous, I shouldn't touch it"
            ),
            "nervousness",
        ),
        (
            "Cognitive dominance: neutral vector + strong sadness thought",
            format_integrated_input(
                [0.50, 0.25, 0.50, 0.50, 0.50, 0.50],
                "calm environment",
                "I really miss them, wish they were here"
            ),
            "sadness",
        ),
    ]

    correct_top1 = 0
    correct_top3 = 0
    valid_format = 0

    for desc, user_input, expected in test_cases:
        print(f"\n--- {desc} ---")
        response = infer(model, tokenizer, user_input)
        print(f"Response:\n{response}")

        parsed = parse_limbic_output(response)
        if parsed["emotions"]:
            valid_format += 1
            sorted_emos = sorted(parsed["emotions"].items(), key=lambda x: x[1], reverse=True)
            top1 = sorted_emos[0][0]
            top3 = [e[0] for e in sorted_emos[:3]]
            if top1 == expected:
                correct_top1 += 1
            if expected in top3:
                correct_top3 += 1
            print(f"Expected: {expected}, Top-1: {top1}, Top-3: {top3}")
        else:
            print(f"FAILED TO PARSE: {response[:100]}")

    n = len(test_cases)
    print(f"\n{'=' * 60}")
    print(f"Results ({n} test cases):")
    print(f"  Valid format: {valid_format}/{n} ({100*valid_format/n:.0f}%)")
    print(f"  Top-1 accuracy: {correct_top1}/{n} ({100*correct_top1/n:.0f}%)")
    print(f"  Top-3 accuracy: {correct_top3}/{n} ({100*correct_top3/n:.0f}%)")
    print(f"{'=' * 60}")


# ---------------------------------------------------------------------------
# 8. Merged Model Export (for deployment)
# ---------------------------------------------------------------------------

def merge_and_export(
    lora_dir: str = DEFAULT_OUTPUT_DIR,
    output_dir: str = None,
):
    """Merge LoRA weights into base model and save for deployment."""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from peft import PeftModel

    if output_dir is None:
        output_dir = lora_dir + "-merged"

    print(f"Loading base model {BASE_MODEL_ID}...")
    base_model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL_ID,
        torch_dtype=torch.float16,
        device_map="cpu",  # merge on CPU to avoid quantization issues
    )

    print(f"Loading LoRA from {lora_dir}...")
    model = PeftModel.from_pretrained(base_model, lora_dir, torch_dtype=torch.float16)

    print("Merging weights...")
    model = model.merge_and_unload()

    print(f"Saving merged model to {output_dir}...")
    model.save_pretrained(output_dir, safe_serialization=True)

    tokenizer = AutoTokenizer.from_pretrained(lora_dir)
    tokenizer.save_pretrained(output_dir)

    print(f"Done. Merged model saved to {output_dir}")


# ---------------------------------------------------------------------------
# 9. Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="SmolLM2 Limbic System Training")
    parser.add_argument("--mode", choices=["train", "eval", "merge", "demo"],
                        default="train")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--no-goemotions", action="store_true",
                        help="Use synthetic data instead of GoEmotions")

    args = parser.parse_args()

    if args.mode == "train":
        model, tokenizer = train(
            output_dir=args.output_dir,
            num_epochs=args.epochs,
            batch_size=args.batch_size,
            learning_rate=args.lr,
            use_goemotions=not args.no_goemotions,
        )
        print("\nRunning evaluation on trained model...")
        evaluate(model, tokenizer)

    elif args.mode == "eval":
        model, tokenizer = load_trained_model(args.output_dir)
        evaluate(model, tokenizer)

    elif args.mode == "merge":
        merge_and_export(args.output_dir)

    elif args.mode == "demo":
        model, tokenizer = load_trained_model(args.output_dir)
        print("Limbic system loaded. Enter inputs (Ctrl+C to exit):\n")
        while True:
            try:
                user_input = input("Input: ")
                if not user_input.strip():
                    continue
                response = infer(model, tokenizer, user_input)
                print(f"\n{response}\n")
            except KeyboardInterrupt:
                break
