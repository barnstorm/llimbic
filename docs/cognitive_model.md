# Cognitive Model: Stream-Based Mind Architecture

## Core Principle

The mind is not a pipeline. It's concurrent streams competing for attention on a shared bus. Each stream runs at its own rate, publishes events, subscribes to others, and the "inner monologue" is just the readout of whichever stream currently has the highest activation.

```
                        ┌─────────────────────┐
                        │    ATTENTION BUS     │
                        │  (weighted priority  │
                        │   queue of signals)  │
                        └──┬──┬──┬──┬──┬──┬───┘
                           │  │  │  │  │  │
              ┌────────────┘  │  │  │  │  └────────────┐
              │     ┌─────────┘  │  │  └─────────┐     │
              │     │     ┌──────┘  └──────┐     │     │
              ▼     ▼     ▼                ▼     ▼     ▼
           ┌─────┬─────┬─────┐          ┌─────┬─────┬─────┐
           │SENSE│SOMAT│EMOTI│          │ASSOC│EXECU│SOCIA│
           │ORY  │IC   │ONAL │          │IATI │TIVE │L    │
           └─────┴─────┴─────┘          └─────┴─────┴─────┘
            continuous / fast              slower / linguistic
            GDScript + Hebbian            LLM-mediated
```

## The Six Streams

### 1. SENSORY (perception)
- **Rate:** Every physics tick
- **Runs in:** GDScript (SensorSystem)
- **Publishes:** `entity_appeared`, `entity_vanished`, `sound_heard`, `object_state_changed`
- **Subscribes to:** nothing (pure input)
- **What it does:** Raw perception — who/what is visible, how clearly, from where. Doesn't interpret. Just reports.
- **Interrupt condition:** New entity appears, loud sound, entity enters/exits FOV

### 2. SOMATIC (drives/body)
- **Rate:** Every physics tick
- **Runs in:** GDScript (Layer1Substrate + HebbianNetwork)
- **Publishes:** `drive_critical` (hunger/energy/safety/social crosses threshold), `stall_detected`, `fatigue_onset`, `drive_satisfied`
- **Subscribes to:** `emotion_shift` (emotions modulate drive rates), `action_completed`
- **What it does:** Homeostatic regulation. Energy depletes, hunger rises, social need grows. Publishes when a drive becomes urgent enough to demand attention.
- **Interrupt condition:** Any drive crosses urgency threshold (not hardcoded — emergent from network activation competing with current attention)

### 3. EMOTIONAL (limbic)
- **Rate:** Continuous (deterministic engine every tick, limbic model every ~2s)
- **Runs in:** GDScript fast path + L2 limbic model slow path
- **Publishes:** `emotion_shift` (27-dim vector changed significantly), `valence_flip` (positive↔negative), `arousal_spike`
- **Subscribes to:** `entity_appeared`, `sound_heard`, `thought_formed`, `belief_changed`, `drive_critical`
- **What it does:** Colors everything emotionally. Pre-cognitive (fast, before interpretation) AND post-cognitive (reacts to thoughts). A sound triggers fear BEFORE you know what made it. Reflecting on a betrayal triggers anger AFTER the thought forms.
- **Two phases:**
  - **Fast:** Sensory → immediate emotional response (the deterministic engine)
  - **Slow:** Thought → emotional reappraisal (the limbic model coloring a thought)

### 4. ASSOCIATIVE (memory/pattern matching)
- **Rate:** Event-driven (fires when sensory or emotional input matches a stored pattern)
- **Runs in:** LLM (this is where language is needed)
- **Publishes:** `memory_recalled`, `belief_formed`, `belief_contradicted`, `pattern_recognized`
- **Subscribes to:** `entity_appeared`, `sound_heard`, `emotion_shift`, `thought_formed`
- **What it does:** "Have I seen this before? What happened last time? This reminds me of..." Searches memory for relevant matches. When a match is found, it publishes — and that publication can trigger the executive or emotional streams.
- **Examples:**
  - Player approaches → associative stream searches → "Last time this person was here, they blocked my path" → publishes `memory_recalled` → emotional stream fires resentment → executive adjusts plan
  - Hears "oven is broken" → matches against known objects → "I know the bakery oven — it was working yesterday" → publishes `belief_contradicted`

### 5. EXECUTIVE (planning/inner monologue)
- **Rate:** Slow (~every 5-10s when it has attention, but gets interrupted)
- **Runs in:** LLM
- **Publishes:** `thought_formed`, `intention_set`, `intention_dropped`, `plan_step_completed`
- **Subscribes to:** `memory_recalled`, `drive_critical`, `emotion_shift`, `entity_appeared`, `belief_formed`
- **What it does:** "What should I do? How do I get there? What does this mean?" The planning, reasoning, inner monologue stream. But it's NOT the sole occupant of consciousness — it gets interrupted by somatic urgency, emotional spikes, and sensory surprises.
- **Key behavior:** The executive forms intentions but can be derailed. It starts planning "go to bakery" but a `drive_critical(hunger)` interrupt makes it switch to "find food." It's trying to plan but `entity_appeared(stranger)` grabs attention and it switches to interpreting the newcomer.

### 6. SOCIAL (theory of mind)
- **Rate:** Event-driven (fires during/after social encounters)
- **Runs in:** LLM
- **Publishes:** `social_inference` (what the other person wants/feels/knows), `trust_updated`, `obligation_recognized`
- **Subscribes to:** `entity_appeared`, `sound_heard` (speech), `memory_recalled` (past interactions), `emotion_shift`
- **What it does:** Models other minds. "Why is this person here? What do they want? Are they angry? Do they know about the broken oven?" This is where NPCs develop theories about each other and the player.
- **Examples:**
  - Player says "Have you seen Roland?" → social stream infers "Player is looking for Roland" → publishes `social_inference(player wants to find Roland)` → executive can act on it ("I should help" or "I don't trust them enough to say")
  - Edith looks stressed → social stream infers "Edith is having a bad day" → emotional stream responds with concern → executive may generate "I should check on Edith"

## The Attention Bus

The bus is a priority queue. Every stream publishes signals with a **weight** (0.0-1.0). The weights compete. The signal with the highest weight "wins" attention and becomes the current inner monologue focus.

```
Weight factors:
  - Novelty:     new stimulus > repeated stimulus
  - Intensity:   loud sound > quiet sound, acute pain > mild discomfort
  - Relevance:   related to current goal > unrelated
  - Emotional:   high-arousal emotion amplifies the triggering signal
  - Recency:     fresh signal > stale signal
  - Drive state: hungry amplifies food-related signals
```

### Attention dynamics:

**Sustained attention:** When the executive is deep in planning (high task_momentum), incoming signals need higher weight to interrupt. This is already modeled by the Hebbian network's momentum/tolerance neurons.

**Attention capture:** Some signals are involuntary interrupts — a sudden loud sound, acute pain, a threat entering visual field. These bypass the weight competition and grab attention immediately.

**Background processing:** Streams that don't have attention still run. The back ache doesn't stop when you're focused on typing — it just doesn't have enough weight to interrupt. But it accumulates, and eventually its weight crosses the threshold.

**Rumination:** The associative stream can loop — a recalled memory triggers an emotion, the emotion recalls more memories, which trigger more emotion. This is how NPCs get "stuck thinking about" something. The loop continues until a stronger signal breaks it or the emotional charge dissipates.

## What the LLM Does (and Doesn't Do)

The LLM handles streams 4, 5, 6 — the linguistic ones. But NOT as a monolithic "generate a response" call. Instead:

### The LLM is called per-signal, not per-tick

When `entity_appeared(Player)` fires:
1. **Associative** gets called: "Given memory M and entity E, any relevant recall?" → produces `memory_recalled` or nothing
2. **Executive** gets called: "Given current intention I, emotion E, and this new entity, what do you think?" → produces `thought_formed`
3. **Social** gets called: "Given entity E's behavior and your history, what do they want?" → produces `social_inference`

These are THREE separate LLM calls, not one. Each is small, focused, and has a clear input/output contract. Each produces a signal that goes back on the bus.

### The fine-tuned model needs multiple "modes"

Not one prompt format — several:

**Associative mode:**
```
INPUT: {entity: "Player", context: "approaching from east", memory: [...]}
OUTPUT: {recalled: "Player blocked my path yesterday", relevance: 0.7}
```

**Executive mode:**
```
INPUT: {current_goal: "serve guests", attention_signal: "Player arrived", emotion: "curiosity"}
OUTPUT: {thought: "A new face. Wonder what brings them here.", want: "greet them", feel: "curious"}
```

**Social mode:**
```
INPUT: {entity: "Player", said: "Have you seen Roland?", my_knowledge: [...]}
OUTPUT: {inference: "Player is looking for Roland", belief: "Player needs help finding Roland"}
```

**Appraisal mode (for emotional stream):**
```
INPUT: {thought: "Roland hasn't been to the inn in days", current_emotions: [...]}
OUTPUT: {emotion_delta: {concern: +0.3, curiosity: +0.2}, reason: "unusual absence"}
```

## What Stays in GDScript

Everything that doesn't need language:
- Sensory stream (perception queries, FOV, hearing)
- Somatic stream (drive dynamics, Hebbian network, neurogenesis)
- Fast emotional path (deterministic emotion engine)
- Attention routing (priority queue, weight comparison, interrupt logic)
- Action execution (pathfinding, animation, speech bubbles)
- The bus itself (signal dispatch, subscription management)

## Implementation Sketch

### The Bus (GDScript)

```
class AttentionBus:
  var signals: Array[BusSignal]  # priority queue sorted by weight
  var subscribers: Dictionary     # signal_type -> Array[Callable]
  
  func publish(signal: BusSignal):
    signals.insert_sorted(signal)
    for sub in subscribers.get(signal.type, []):
      sub.call(signal)
  
  func get_focus() -> BusSignal:
    return signals[0] if signals else null
```

### BusSignal

```
{
  type: "entity_appeared" | "drive_critical" | "thought_formed" | ...,
  source_stream: "sensory" | "somatic" | "emotional" | ...,
  weight: float (0-1),
  data: Dictionary (signal-specific payload),
  timestamp: int,
}
```

### LLM Dispatch (Server)

Instead of one `generate_thought()` call, the server has:
- `associative_recall(entity, context, memory)` → small, fast
- `executive_think(goal, signal, emotion)` → the inner monologue
- `social_infer(entity, utterance, history)` → theory of mind
- `emotional_appraise(thought, current_emotions)` → post-cognitive emotion

Each runs in a thread. Multiple can run concurrently. Results are pushed back to the client as bus signals.

### Attention → Inner Monologue

The "inner monologue" is not generated by one call. It's the **narrative readout** of the current attention focus:

- Bus focus is `thought_formed("A new face")` → inner monologue is "A new face. Wonder what brings them here."
- Bus focus shifts to `drive_critical(hunger)` → inner monologue becomes "...but I'm so hungry. Need to eat."  
- Bus focus shifts to `social_inference("Player wants Roland")` → "They're looking for Roland? Haven't seen him today."

The chat model, when the player talks to the NPC, reads the **recent bus history** — the last N signals with their weights — and speaks from that stream of consciousness. It doesn't generate its own reality. It narrates the bus.

## Training Data Implications

The fine-tuned model needs to learn four distinct behaviors, not one:
1. **Recall:** Given a probe (entity/event/topic), retrieve relevant memory → short, factual
2. **Think:** Given attention signal + emotional state, produce grounded interpretation → 1-2 sentences
3. **Infer:** Given social interaction, model the other's mental state → structured
4. **Appraise:** Given a thought, produce emotional delta → structured

Each is a separate fine-tuning task. A multi-task model with mode tokens (`<recall>`, `<think>`, `<infer>`, `<appraise>`) would let one model handle all four without mode confusion.
