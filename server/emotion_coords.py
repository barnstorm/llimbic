"""
GoEmotions 27-dimensional coordinate system.

This is a FIXED projection surface — not the NPC's internal state, not a claim about emotion.
It is a translation interface and modulation handle system.
Each dimension is a bounded scalar 0.0-1.0.
"""

# The 27 GoEmotions dimensions in canonical order
DIMENSIONS = [
    # Positive valence (12)
    "admiration", "amusement", "approval", "caring",
    "desire", "excitement", "gratitude", "joy",
    "love", "optimism", "pride", "relief",
    # Negative valence (11)
    "anger", "annoyance", "disappointment", "disapproval",
    "disgust", "embarrassment", "fear", "grief",
    "nervousness", "remorse", "sadness",
    # Epistemic / arousal (4)
    "confusion", "curiosity", "realization", "surprise",
]

NUM_DIMS = len(DIMENSIONS)  # 27
assert NUM_DIMS == 27

# Index lookup
DIM_INDEX = {name: i for i, name in enumerate(DIMENSIONS)}

# Groupings for summary
POSITIVE_DIMS = set(DIMENSIONS[:12])
NEGATIVE_DIMS = set(DIMENSIONS[12:23])
EPISTEMIC_DIMS = set(DIMENSIONS[23:])


def clamp_vector(vec: list[float]) -> list[float]:
    """Clamp all dimensions to [0.0, 1.0]."""
    return [max(0.0, min(1.0, v)) for v in vec]


def zero_vector() -> list[float]:
    """Return a neutral 27-dim vector."""
    return [0.0] * NUM_DIMS


def default_vector() -> list[float]:
    """Return a mildly positive default vector (content, calm NPC)."""
    vec = zero_vector()
    vec[DIM_INDEX["joy"]] = 0.2
    vec[DIM_INDEX["optimism"]] = 0.3
    vec[DIM_INDEX["approval"]] = 0.15
    vec[DIM_INDEX["curiosity"]] = 0.25
    return vec


def top_dimensions(vec: list[float], n: int = 5) -> list[tuple[str, float]]:
    """Return the top-N most activated dimensions."""
    indexed = [(DIMENSIONS[i], v) for i, v in enumerate(vec)]
    indexed.sort(key=lambda x: x[1], reverse=True)
    return indexed[:n]


def valence_summary(vec: list[float]) -> dict:
    """Compute aggregate valence scores."""
    pos = sum(vec[DIM_INDEX[d]] for d in POSITIVE_DIMS) / len(POSITIVE_DIMS)
    neg = sum(vec[DIM_INDEX[d]] for d in NEGATIVE_DIMS) / len(NEGATIVE_DIMS)
    epi = sum(vec[DIM_INDEX[d]] for d in EPISTEMIC_DIMS) / len(EPISTEMIC_DIMS)
    return {"positive": pos, "negative": neg, "epistemic": epi}


def format_state_prompt(layer1_state: dict, recent_events: list[str],
                        current_vector: list[float]) -> str:
    """Format Layer 1 state into a structured prompt for the Layer 2 model."""
    top = top_dimensions(current_vector, 5)
    top_str = ", ".join(f"{name}={val:.2f}" for name, val in top)

    events_str = "; ".join(recent_events[-5:]) if recent_events else "none"

    prompt = (
        f"NPC state: energy={layer1_state.get('energy', 50):.0f}, "
        f"hunger={layer1_state.get('hunger', 50):.0f}, "
        f"frustration={layer1_state.get('frustration', 0):.2f}, "
        f"social={layer1_state.get('social_need', 50):.0f}, "
        f"safety={layer1_state.get('safety', 80):.0f}, "
        f"momentum={layer1_state.get('task_momentum', 0):.2f}. "
        f"Current emotions: {top_str}. "
        f"Recent events: {events_str}. "
        f"Update the emotion vector."
    )
    return prompt


def format_modulation_prompt(directives: str, current_vector: list[float]) -> str:
    """Format Layer 3 directives into a prompt for modulation."""
    top = top_dimensions(current_vector, 5)
    top_str = ", ".join(f"{name}={val:.2f}" for name, val in top)

    prompt = (
        f"Directive: {directives}. "
        f"Current emotions: {top_str}. "
        f"Output modulation parameters."
    )
    return prompt
