# Resume Prompt: Replace Hardcoded Emotion→Quality Nudges with Emotion Sensory Neurons

Paste this into a new Claude Code session to continue.

---

## The Problem

`somatic_stream.gd` has a method `_apply_emotion_to_qualities()` that hardcodes emotion→quality neuron mappings:

```gdscript
# somatic_stream.gd lines 68-140
func _apply_emotion_to_qualities(emo: Array) -> void:
    var rate: float = 2.0
    var fear: float = emo[IDX_FEAR]
    if fear > 0.2:
        _nudge("q_tight", fear * rate)
        _nudge("q_pounding", fear * rate * 0.8)
        _nudge("q_prickling", fear * rate)
        _nudge("q_churning", fear * rate * 0.7)
        _nudge("q_constricted", fear * rate * 0.6)
    # ...anger, disgust, nervousness, grief, joy, excitement, sadness, embarrassment, relief
```

This fights the Hebbian network. Both systems write to the same quality neurons — one through learned weighted connections, one through hardcoded if/then rules. The hardcoded nudges are louder (rate=2.0 vs propagation scale 0.1), so they overwhelm learned signals. Worse, Hebbian learning sees the co-activation and "learns" redundant copies of the hardcoded rules. No individuation. Every being with `fear > 0.2` gets the same tight+pounding+prickling. Two beings never diverge.

`emotion_engine.gd` has the same problem one layer deeper — it hardcodes drive→emotion mappings:

```gdscript
# emotion_engine.gd lines 64-72
if energy < 30.0:
    vec[IDX_SADNESS] = minf(vec[IDX_SADNESS] + 0.02, 1.0)
if frustration > 0.3:
    vec[IDX_ANGER] = minf(vec[IDX_ANGER] + frustration * 0.04, 1.0)
```

Both of these should be learnable Hebbian connections, not code.

## The Fix

### Step 1: Add emotion sensory neurons to the Hebbian network

Add ~10 protected sensory neurons that read the emotion vector each tick. Only the emotions with body correlates — the somatic-relevant subset:

```
emo_fear         ← emotion_vector[18]
emo_anger        ← emotion_vector[12]
emo_disgust      ← emotion_vector[16]
emo_nervousness  ← emotion_vector[20]
emo_grief        ← emotion_vector[19]
emo_joy          ← emotion_vector[7]
emo_excitement   ← emotion_vector[5]
emo_sadness      ← emotion_vector[22]
emo_embarrassment ← emotion_vector[17]
emo_relief       ← emotion_vector[11]
```

These are protected (`true`) — their activation is SET from the emotion vector, not computed by propagation. But their OUTGOING connections to quality neurons are normal learnable Hebbian connections.

**File:** `scripts/hebbian_network.gd`
- Add neurons in `setup_default_network()` after vagal neurons, before quality neurons
- Type: "emotion_sensory", protected: true
- Initial activation: 0.0 (set each tick from vector)

### Step 2: Add seed connections from emotion neurons to quality neurons

These replace the hardcoded mappings in `_apply_emotion_to_qualities()`. The SAME mappings become SEED WEIGHTS:

```
# Fear → threat body sensations
emo_fear → q_tight: 0.08
emo_fear → q_pounding: 0.06
emo_fear → q_prickling: 0.08
emo_fear → q_churning: 0.05
emo_fear → q_constricted: 0.05

# Anger → tension body sensations  
emo_anger → q_tight: 0.06
emo_anger → q_coiled: 0.08
emo_anger → q_pressure: 0.05
emo_anger → q_raw: 0.04

# Disgust → gut sensations
emo_disgust → q_churning: 0.08
emo_disgust → q_crawling: 0.06

# Nervousness → flutter/prickling
emo_nervousness → q_churning: 0.05
emo_nervousness → q_fluttering: 0.08
emo_nervousness → q_dry: 0.04
emo_nervousness → q_prickling: 0.04

# Grief → hollow/cold/heavy
emo_grief → q_hollow: 0.08
emo_grief → q_cold: 0.06
emo_grief → q_heavy: 0.06
emo_grief → q_constricted: 0.04

# Joy → warm/light/open
emo_joy → q_warm: 0.08
emo_joy → q_light: 0.06
emo_joy → q_open: 0.06

# Excitement → fluttering/buzzing/aroused
emo_excitement → q_fluttering: 0.08
emo_excitement → q_buzzing: 0.06
emo_excitement → q_aroused: 0.06

# Sadness → heavy/foggy/cold
emo_sadness → q_heavy: 0.08
emo_sadness → q_foggy: 0.06
emo_sadness → q_cold: 0.04

# Embarrassment → warm(flush)/churning
emo_embarrassment → q_warm: 0.04
emo_embarrassment → q_churning: 0.05

# Relief → loose/settled/open
emo_relief → q_loose: 0.08
emo_relief → q_settled: 0.06
emo_relief → q_open: 0.05
```

**File:** `scripts/hebbian_network.gd`
- Add a new `_seed_emotion_quality_connections()` function
- Call it from `_seed_connections()` alongside `_seed_quality_connections()` and `_seed_vagal_connections()`

### Step 3: Set emotion sensory neuron activations each tick

The L1 substrate needs to write the emotion vector values into the emotion sensory neurons each tick, just like it writes `sense_at_home` and `sense_is_night`.

**File:** `scripts/layer1_substrate.gd`
- In `_update_sensory_neurons()`, add lines that set `emo_fear`, `emo_anger`, etc. from `_emotion_vector`
- The emotion vector is already cached in `_emotion_vector` (set via `apply_emotion_feedback()`)
- Scale: emotion values are 0.0-1.0, neurons are 0-100, so multiply by 100

```gdscript
# In _update_sensory_neurons():
if _emotion_vector.size() >= 27:
    _network.set_activation("emo_fear", _emotion_vector[18] * 100.0)
    _network.set_activation("emo_anger", _emotion_vector[12] * 100.0)
    _network.set_activation("emo_disgust", _emotion_vector[16] * 100.0)
    _network.set_activation("emo_nervousness", _emotion_vector[20] * 100.0)
    _network.set_activation("emo_grief", _emotion_vector[19] * 100.0)
    _network.set_activation("emo_joy", _emotion_vector[7] * 100.0)
    _network.set_activation("emo_excitement", _emotion_vector[5] * 100.0)
    _network.set_activation("emo_sadness", _emotion_vector[22] * 100.0)
    _network.set_activation("emo_embarrassment", _emotion_vector[17] * 100.0)
    _network.set_activation("emo_relief", _emotion_vector[11] * 100.0)
```

### Step 4: Delete `_apply_emotion_to_qualities()` from somatic_stream.gd

Remove the entire method and its call in `emit()`. The emotion→quality path is now ENTIRELY through the Hebbian network.

**File:** `scripts/somatic_stream.gd`
- Delete `_apply_emotion_to_qualities()` (lines ~68-140)
- In `emit()`, remove the call: `if emotion_vector.size() >= 27: _apply_emotion_to_qualities(emotion_vector)`
- The `emit()` method no longer needs the `emotion_vector` parameter at all — remove it
- Update the call site in `layer1_substrate.gd`: `somatic_tags = _somatic.emit()` instead of `_somatic.emit(_emotion_vector)`

### Step 5: Consider the same fix for EmotionEngine

`emotion_engine.gd` has hardcoded drive→emotion rules that could similarly become Hebbian connections from drive neurons to emotion sensory neurons. But this is a bigger refactor — the EmotionEngine currently outputs the 27-dim vector that the emotion sensory neurons read from. If we remove EmotionEngine's rules, we need another source for the emotion vector.

Options:
- **Keep EmotionEngine for now** as the drive→emotion path (it feeds the emotion sensory neurons which feed quality neurons via Hebbian connections). The hardcoded rules only affect the emotion vector, which is now just an intermediate representation — the somatic tags are what the LLM reads.
- **Replace EmotionEngine later** with drive→emotion connections in the Hebbian network. This would mean adding 27 emotion neurons (not just the 10 somatic-relevant ones) and computing the full vector from network dynamics. Bigger change, save for later.

**Recommendation:** Do Step 5 in a future session. Steps 1-4 fix the immediate problem (emotion→quality fighting) without disrupting the emotion vector pipeline.

## What changes (summary)

| Step | File | Change |
|------|------|--------|
| 1 | `hebbian_network.gd` | Add 10 emotion sensory neurons (protected) |
| 2 | `hebbian_network.gd` | Add `_seed_emotion_quality_connections()` with ~35 seed weights |
| 3 | `layer1_substrate.gd` | Write emotion vector into emotion neurons in `_update_sensory_neurons()` |
| 4 | `somatic_stream.gd` | Delete `_apply_emotion_to_qualities()` and its call |
| 4b | `layer1_substrate.gd` | Remove `_emotion_vector` param from `_somatic.emit()` call |

## What emerges

- A being whose fear consistently co-activates with `q_churning` (gut-fear) develops stronger `emo_fear → q_churning` via Hebbian learning. Another being whose fear co-activates with `q_pounding` (chest-fear) develops stronger `emo_fear → q_pounding`. Same emotion, different body. Individuation from experience.
- The seed weight `emo_fear → q_tight: 0.08` decays via `HEBBIAN_DECAY: 0.001` if fear and tight don't co-activate. Over time, unused mappings fade. The being's body vocabulary narrows to its actual experience.
- Neurogenesis can spawn new connections between emotion neurons and quality neurons that weren't in the seed set. A being that experiences `emo_embarrassment` and `q_pounding` together (blushing with racing heart) develops that connection spontaneously via `_check_spontaneous_connections()`.
- The vagal gate's quality connections (`vagal_sympathetic → q_tight`) now interact with the emotion→quality connections cleanly. Both feed quality neurons through the same mechanism. No fighting.

## Verification

1. **Headless test:** Set `emo_fear` high (emotion_vector[18] = 0.8), run 200 ticks, verify quality neurons `q_tight`, `q_pounding`, `q_prickling` activate above emission threshold. Compare activation levels to the old hardcoded path — should be similar magnitude.
2. **Individuation test:** Run two beings with identical initial state. Give one repeated `emo_fear + q_tight` co-activation, the other `emo_fear + q_churning`. After N learning cycles, verify the first has stronger `emo_fear → q_tight` weight, the second has stronger `emo_fear → q_churning`.
3. **Decay test:** Set a seed connection (e.g., `emo_embarrassment → q_warm: 0.04`), run many cycles where embarrassment fires but warm doesn't co-activate. Verify the weight decays toward zero.
4. **Live test:** Run full stack, verify somatic tags still drive contextually appropriate behavior from the CommandModel.

## Architecture after this fix

```
Emotion Vector (27-dim, from EmotionEngine + L2 model)
        │
        ▼ (set each tick)
Emotion Sensory Neurons (10 protected)
  emo_fear, emo_anger, emo_joy, etc.
        │
        ▼ (learnable Hebbian connections — seed weights that individuate)
Quality Neurons (31 base + compounds)
  q_tight, q_pounding, q_warm, etc.
        │
        ▼ (probabilistic emission via somatic stream)
Somatic Tags: "gut:empty:churning", "chest:tight:pounding"
        │
        ▼ (in LLM prompt)
"You feel: gut:empty:churning, chest:tight:pounding"
```

No hardcoded emotion→quality mappings anywhere. The only static things are seed weights that the network can reshape through experience. Every being starts the same and diverges from there.

## Key files

- `scripts/hebbian_network.gd` — Add emotion sensory neurons + seed connections
- `scripts/layer1_substrate.gd` — Write emotion values into emotion neurons each tick
- `scripts/somatic_stream.gd` — Delete `_apply_emotion_to_qualities()`
- `scripts/emotion_engine.gd` — No change (keep for now, refactor later)

## Current commit state

The user has uncommitted changes in:
- `scripts/hebbian_network.gd` — drive neurons made protected, other edits
- `scripts/memory_system.gd` — structured observations, entity threat levels
- `scripts/npc_brain.gd` — memory created before L1
- `server/layer3_server.py` — somatic_tags in request models
- `server/layer3_model.py`, `server/prompt_builder.py` — prompt unification

Commit these first with: `git add -A && git commit -m "unify prompts around somatic tags, protected drives, structured memory"` then proceed with the emotion neuron refactor.

## Repo

GitHub: https://github.com/barnstorm/llimbic
Branch: master (pushes to main)
