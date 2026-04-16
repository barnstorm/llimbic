# Fine-Tuning Spec: Universal Cognitive Model

## Goal

Train a small model (~1-2B parameters) that implements the cognitive process of *thinking* — not any particular character, species, or personality. The same model runs a medieval innkeeper, a guard dog, a forest spirit, or any being with drives, perception, and memory.

The model learns: given a state (drives, perception, emotions, memory), how does a mind process it?

## Architecture

One model, four modes selected by a mode token at the start of the input:

| Mode | Token | Purpose | Input | Output |
|------|-------|---------|-------|--------|
| Recall | `<recall>` | Associative memory search | Probe (entity/event/topic) + memory buffer | Relevant memory + relevance score |
| Think | `<think>` | Executive inner monologue | Attention signal + emotional state + current goal | Thought + want + feel |
| Infer | `<infer>` | Theory of mind / social modeling | Entity behavior + speech + relationship history | Inference about the other's state/intent |
| Appraise | `<appraise>` | Emotional reappraisal of a thought | Thought text + current emotion state | Emotion deltas with reason |

## Input Format (shared structure)

Every input starts with the being's current state, regardless of mode:

```
<{mode}>
BEING: {species/role — free text, e.g. "innkeeper", "wolf", "wandering spirit"}
DRIVES: energy={0-100} hunger={0-100} social={0-100} safety={0-100}
MOOD: {top 3 emotions with intensities, e.g. "curiosity 0.6, nervousness 0.3, joy 0.2"}
LOCATION: {where they are}
DOING: {current activity}
```

Then mode-specific fields follow.

## Mode Specs

### `<recall>` — Associative Memory

**When it fires:** A perception event, emotion shift, or thought mentions something that might have a memory match.

**Additional input:**
```
PROBE: {what triggered the recall — an entity name, event type, topic, or emotion}
MEMORY:
- {memory 1 — text, source, age}
- {memory 2}
- ...
```

**Output:**
```
RECALLED: {the relevant memory text, or "nothing" if no match}
RELEVANCE: {0.0-1.0}
CONNECTION: {why this memory is relevant — one short phrase}
```

**Training examples should teach:**
- Match by entity name ("Player" → recall last interaction with Player)
- Match by emotional similarity (feeling afraid → recall last time you felt afraid)
- Match by topic ("oven" → recall oven-related memories)
- Return "nothing" when no memories are relevant (don't invent)
- Higher relevance for recent, high-salience, emotionally-charged memories
- Species-appropriate recall (a wolf recalls territories and threats, not conversations)

**Example:**
```
<recall>
BEING: guard dog
DRIVES: energy=70 hunger=40 social=30 safety=50
MOOD: alertness 0.7, anxiety 0.3
LOCATION: front gate
DOING: watching

PROBE: unfamiliar human approaching
MEMORY:
- "A stranger threw rocks at me three days ago" (salience 0.8, 3 days old)
- "My owner fed me this morning" (salience 0.3, 6 hours old)
- "Another dog passed by the gate yesterday" (salience 0.4, 1 day old)

RECALLED: A stranger threw rocks at me three days ago
RELEVANCE: 0.8
CONNECTION: unfamiliar human — last unfamiliar human was hostile
```

---

### `<think>` — Executive Inner Monologue

**When it fires:** An attention signal has captured focus — could be a perception event, a drive becoming urgent, an emotion spike, or a recalled memory.

**Additional input:**
```
SIGNAL: {the attention signal that triggered this thought — what just happened or what just entered awareness}
GOAL: {current intention, or "none"}
BELIEFS: {relevant beliefs, or "none"}
RECENT_THOUGHTS: {last 1-2 thoughts, if any}
```

**Output:**
```
THOUGHT: {first-person interpretation, 1-2 sentences}
WANT: {what the being wants to do — must name a concrete place/action, or "nothing"}
FEEL: {one emotion word}
```

**Training examples should teach:**
- React to the SIGNAL, not to imagination
- Reference only things present in the input (NO hallucinated details)
- Drive states influence wants (hungry → want food, tired → want rest)
- Emotions color interpretation (anxious being interprets ambiguous signal as threat)
- Thoughts build on RECENT_THOUGHTS (continuity, not random)
- WANT names real actions/locations, not abstract desires
- Different beings think differently (wolf: territory/pack/hunt, human: social/work/comfort)
- Simple, concrete, grounded — not flowery prose

**Example:**
```
<think>
BEING: herbalist
DRIVES: energy=45 hunger=60 social=80 safety=75
MOOD: loneliness 0.5, curiosity 0.3
LOCATION: herbalist shop
DOING: sorting herbs

SIGNAL: entity_appeared — Edith the Baker, 3 tiles to the north, walking past
GOAL: sort herbs for the morning
BELIEFS: Edith is friendly (0.7); Edith knows about remedies (0.5)
RECENT_THOUGHTS: "It's been quiet all morning. Nobody's come by."

THOUGHT: Edith is passing by. I haven't talked to anyone all morning and I could use the company.
WANT: go to town_square to talk to Edith
FEEL: hopeful
```

**Example (non-human):**
```
<think>
BEING: stray cat
DRIVES: energy=60 hunger=75 social=20 safety=40
MOOD: wariness 0.5, hunger 0.4
LOCATION: alley behind bakery
DOING: hiding

SIGNAL: smell detected — bread from bakery, strong
GOAL: find food
BELIEFS: bakery has food scraps (0.8); the baker chases me away (0.6)
RECENT_THOUGHTS: "Stomach is growling. Need to eat soon."

THOUGHT: The bread smells strong. The baker might have thrown out scraps. But she chased me last time.
WANT: sneak to bakery back door to check for scraps
FEEL: cautious
```

---

### `<infer>` — Social / Theory of Mind

**When it fires:** Another being does something observable — speaks, approaches, flees, gives, takes. The being needs to model the other's mental state.

**Additional input:**
```
ENTITY: {who — name/description}
OBSERVED: {what they did or said}
HISTORY: {past interactions, or "first encounter"}
TRUST: {0.0-1.0}
```

**Output:**
```
INTENT: {what the other being probably wants/is doing — one phrase}
EMOTION: {what the other being probably feels — one word}
IMPLICATION: {what this means for me — one sentence}
```

**Training examples should teach:**
- Infer intent from behavior (approaching = wants something, fleeing = afraid)
- Infer emotion from context (someone visiting a grave = sad)
- History modulates interpretation (trusted friend approaching = welcome, distrusted stranger = threatening)
- Speech content drives inference ("Have you seen Roland?" → looking for Roland)
- Uncertainty is okay ("unclear intent" is valid)
- Non-human social modeling (wolf reading another wolf's posture, crow watching a human's pattern)

**Example:**
```
<infer>
BEING: innkeeper
DRIVES: energy=60 hunger=30 social=50 safety=80
MOOD: calm 0.5, curiosity 0.3
LOCATION: inn
DOING: cleaning

ENTITY: Player (traveler)
OBSERVED: walked into the inn, looking around, approached me
HISTORY: first encounter
TRUST: 0.5

INTENT: looking for lodging or information
EMOTION: uncertain
IMPLICATION: A potential guest. I should greet them and see what they need.
```

---

### `<appraise>` — Emotional Reappraisal

**When it fires:** A thought has been formed by the executive stream, and needs to pass back through the emotional system for coloring. This is the post-cognitive emotional loop.

**Additional input:**
```
THOUGHT: {the thought to appraise}
CURRENT_MOOD: {current emotion state}
```

**Output:**
```
EMOTIONS: {emotion_name: delta, ...} (only emotions that change, delta -1.0 to +1.0)
REASON: {why — one phrase}
```

**Training examples should teach:**
- Threatening thoughts increase fear/anxiety
- Loss-related thoughts increase sadness/grief
- Social thoughts modulate desire/loneliness
- Positive outcomes increase joy/relief
- The REASON explains the causal link
- Small deltas for mild thoughts, large for significant ones
- Emotions appropriate to the being type (wolf doesn't feel embarrassment)

**Example:**
```
<appraise>
BEING: baker
DRIVES: energy=50 hunger=30 social=40 safety=80
MOOD: pride 0.4, calm 0.3

THOUGHT: The oven has been broken for two days now and nobody has come to fix it.
CURRENT_MOOD: pride 0.4, calm 0.3

EMOTIONS: frustration +0.4, anxiety +0.2, pride -0.2
REASON: inability to do my job, losing sense of purpose
```

---

## Training Data Generation Strategy

### Axes of variation

Each training example varies along these dimensions:

| Axis | Values |
|------|--------|
| Being type | human (8+ roles), animal (wolf, cat, horse, crow, dog), mythical (spirit, golem), abstract (guardian, watcher) |
| Drive state | 5 drives × 3 levels (low/med/high) — not all combinations, focus on interesting ones |
| Emotional state | 27 GoEmotions, focus on dominant 1-3 per example |
| Perception | alone, one entity, crowd, threat visible, loved one visible, nothing notable |
| Memory | empty, sparse, rich, conflicting |
| Social context | stranger, friend, enemy, authority, dependent |
| Complexity | simple reaction, conflicting drives, moral dilemma, ambiguous signal |

### Volume targets

| Mode | Examples | Rationale |
|------|----------|-----------|
| `<recall>` | 500 | Simplest mode — pattern matching |
| `<think>` | 2000 | Core mode, most variation needed |
| `<infer>` | 800 | Social reasoning, entity-dependent |
| `<appraise>` | 500 | Structured emotion math |
| **Total** | ~3800 | |

### Generation process

1. Define scenario templates (being type × situation × mode)
2. For each template, generate 3-5 examples using Claude with varied drive/emotion states
3. Review for grounding violations (hallucinated details, flowery prose, wrong format)
4. Filter to examples that are concrete, grounded, and format-compliant
5. Balance across being types, drive states, and complexity levels

### Quality criteria

A training example is good if:
- Output ONLY references things present in the input
- Format is exact (right fields, right structure)
- Thought/inference is plausible given the state
- Emotions are proportional to the cause
- Different being types produce different but valid cognitive styles
- WANT names concrete actions, not abstract desires
- "Nothing" / "unclear" is used when appropriate (not everything needs a strong reaction)

## Base Model Candidates

| Model | Size | Quantized | VRAM | Notes |
|-------|------|-----------|------|-------|
| SmolLM2-1.7B-Instruct | 1.7B | fp16 | ~3.4GB | Current L3. Poor instruction following. |
| SmolLM2-360M-Instruct | 360M | fp16 | ~720MB | Very small. Good if fine-tuning makes up for size. |
| Qwen2.5-1.5B-Instruct | 1.5B | fp16 | ~3GB | Better instruction following than SmolLM2. |
| Phi-3.5-mini-instruct | 3.8B | Q4 GGUF | ~2.5GB | Excellent instruction following. May be too large with L2. |
| Gemma-2-2B-it | 2B | fp16 | ~4GB | Good at structured output. |
| TinyLlama-1.1B | 1.1B | Q4 GGUF | ~636MB | Current L2 base. Could unify L2+L3. |

The appraise mode could potentially stay on the L2 model (TinyLlama-1.1B) since it's the simplest mode and closest to what the limbic model already does. Then the L3 model handles recall/think/infer.

Or: one unified model for all four modes, running on the larger VRAM budget (~6-8GB with quantization), leaving the rest for the L2 limbic model or replacing it entirely.
