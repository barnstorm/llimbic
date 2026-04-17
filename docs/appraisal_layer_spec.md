# Appraisal Layer: Native Embedding Bridge Between Body and Mind

## Overview

The appraisal layer is the anterior insula of the cognitive architecture. It sits between the Hebbian neural network (the body/id) and the command model (the mind/ego), translating body-state activation patterns into vectors that live in the LLM's own representation space.

No text intermediary. No fixed mappings. No separate model. The body speaks to the mind in a shared vector language that both understand. The vectors evolve through Hebbian dynamics — each being develops its own felt vocabulary from its own experience.

## The Problem This Solves

The current pipeline has a lossy text bottleneck:

```
Hebbian activations (rich, high-dimensional, continuous)
    ↓ somatic stream (lossy discretization into tags)
Somatic tags: "chest:tight:pounding" (text tokens)
    ↓ tokenizer (further lossy compression)
Token IDs in LLM context
    ↓ embedding lookup (LLM reconstructs meaning from tokens)
LLM hidden state (finally back in a rich continuous space)
```

Each arrow loses information. The Hebbian network knows exactly HOW tight the chest is, what other neurons are co-firing, the trajectory of activation over time, the specific quality of this particular tightness. By the time it reaches the LLM, it's three words: "chest:tight:pounding."

The native embedding approach eliminates the bottleneck:

```
Hebbian activations (rich, continuous)
    ↓ learned projection (linear transform, per-being, Hebbian-updated)
LLM embedding space (rich, continuous — same space the LLM thinks in)
    ↓ direct injection into hidden state
LLM forward pass (processes body state as if it were already-understood concepts)
```

No discretization. No tokenization. The body state enters the mind as a continuous vector with full fidelity.

## Architecture

### Component 1: Reference Embeddings (extracted via LaRQL)

Before any being exists, we use LaRQL to decompile SmolLM3-3B and extract reference embedding vectors for body-relevant concepts. These are points in the LLM's latent space where it already represents these ideas.

**What we extract:**

```
Body region concepts:
  ref_chest     = LaRQL.extract("chest")       # d-dimensional vector
  ref_gut       = LaRQL.extract("gut")
  ref_skin      = LaRQL.extract("skin")
  ref_muscles   = LaRQL.extract("muscles")
  ref_head      = LaRQL.extract("head")
  ref_throat    = LaRQL.extract("throat")

Quality concepts:
  ref_tight     = LaRQL.extract("tight")
  ref_pounding  = LaRQL.extract("pounding")
  ref_churning  = LaRQL.extract("churning")
  ref_warm      = LaRQL.extract("warm")
  ref_numb      = LaRQL.extract("numb")
  ref_heavy     = LaRQL.extract("heavy")
  ref_hollow    = LaRQL.extract("hollow")
  ... (one per quality neuron)

Felt-concept reference points:
  ref_danger    = LaRQL.extract("danger")
  ref_hunger    = LaRQL.extract("hunger")
  ref_loneliness = LaRQL.extract("loneliness")
  ref_safety    = LaRQL.extract("safety")
  ref_exhaustion = LaRQL.extract("exhaustion")
  ref_comfort   = LaRQL.extract("comfort")
  ref_wrongness = LaRQL.extract("something wrong")
  ref_familiar  = LaRQL.extract("familiar feeling")
  ... (~30-50 felt concepts)
```

**How LaRQL extracts these:**

We use LaRQL's `WalkModel` to get the actual mid-stack hidden state — the model's semantic representation at the layer depth where body concepts are encoded as meaning, not surface tokens.

SmolLM3-3B has 36 transformer layers. We extract at layer 24 (~66% deep) — semantic but not yet output-specialized. This is the residual stream vector at that layer after a forward pass containing the concept token.

Important: `vindex.embed()` returns the input embedding row (layer 0) — too shallow for semantic meaning. Gate KNN returns MLP routing vectors — close but not the actual representation. The residual stream at layer 24 IS the model's understanding of the concept at the depth we need.

```python
import larql

wm = larql.WalkModel("smollm3.vindex")
REFERENCE_LAYER = 24  # 66% deep into 36 layers

references = {}
for concept in CONCEPT_LIST:
    trace = wm.trace(concept)
    references[concept] = trace.residual(REFERENCE_LAYER)  # numpy [hidden_dim]

# Multi-word concepts: trace the full phrase, extract at the last token position
trace = wm.trace("something wrong")
references["something_wrong"] = trace.residual(REFERENCE_LAYER, position=-1)
```

This runs ONCE, offline, before any being exists. ~50 forward passes on a 3B model — about 60 seconds total on GPU. The result is saved and never recomputed:

```
reference_embeddings.safetensors
  shape: (num_concepts, hidden_dim)
  ~50 concepts × 2048 dims = 400KB
```

Every being shares these reference points. They represent where the LLM already knows these concepts live. They are the coordinate system the appraisal layer operates in.

For decoding appraisal embeddings back to tokens (Option B in Component 4), the nearest-token search also needs to operate at layer 24, not the input embedding layer. We pre-compute layer-24 representations for the full vocabulary (or a curated subset of ~5000 body/emotion/concept tokens) and use those for cosine similarity lookup.

### Component 2: Appraisal Neurons (in the Hebbian network)

Appraisal neurons are a new neuron type in the Hebbian network, born from neurogenesis when quality neuron constellations sustain co-activation. Each appraisal neuron carries:

```gdscript
{
    "id": "appr_threat_pattern_0",
    "type": "appraisal",
    "activation": float,         # 0-100, same as all neurons
    "protected": false,
    "category": "appraisal",
    "age": int,
    "label": String,             # debug label

    # Appraisal-specific fields:
    "embedding": PackedFloat32Array,  # d-dimensional vector in LLM space
    "parent_qualities": Array,        # which quality neurons spawned this
    "co_activation_count": int,       # how many times this pattern has fired
}
```

**Birth (neurogenesis):**

When 3+ quality neurons sustain co-activation above threshold for >6 seconds (a constellation, not just a pair), a new appraisal neuron is spawned. Its initial embedding is computed as:

```
initial_embedding = weighted_mean(
    ref_embeddings[parent_quality_0] × parent_activation_0,
    ref_embeddings[parent_quality_1] × parent_activation_1,
    ref_embeddings[parent_quality_2] × parent_activation_2,
)
```

For example: `q_tight(80) + q_pounding(70) + q_prickling(60)` co-activate.

```
initial_embedding = (ref_tight × 0.80 + ref_pounding × 0.70 + ref_prickling × 0.60) / (0.80 + 0.70 + 0.60)
```

This places the newborn appraisal neuron in a region of embedding space that's "near" tightness, pounding, and prickling — a reasonable starting point for what this body pattern means. But it's not fixed there.

**Connections:**

The appraisal neuron is wired into the Hebbian network like any other:

```
# Incoming: quality neurons that spawned it
q_tight → appr_threat_pattern_0: 0.15
q_pounding → appr_threat_pattern_0: 0.12
q_prickling → appr_threat_pattern_0: 0.10

# Outgoing: to action neurons (learned through co-activation)
appr_threat_pattern_0 → action_flee: 0.0   # starts at zero, learned
appr_threat_pattern_0 → action_avoid: 0.0

# Outgoing: to vagal neurons
appr_threat_pattern_0 → vagal_sympathetic: 0.0  # learned over time
```

The appraisal neuron activates when its parent constellation fires. Its outgoing connections develop through standard Hebbian learning. Over time, threat-associated appraisal neurons develop strong connections to flee/avoid/sympathetic. Comfort-associated ones develop connections to approach/help/ventral.

### Component 3: Embedding Drift (the learning mechanism)

The appraisal neuron's embedding vector is NOT static after birth. It drifts through a Hebbian-like update rule that operates in embedding space.

**Cortical feedback drift:**

After each thought cycle, the CommandModel produces a hidden state for its thought tokens. We extract the mean hidden state of the `<think>...</think>` block — this is a vector in the same space as the appraisal embeddings. Call it `thought_embedding`.

```python
# In the thought loop, after CommandModel generates:
raw_output = command_model._generate(prompt)

# Extract hidden state from the last forward pass
# (requires model modification to expose hidden states)
thought_embedding = extract_think_block_hidden_state(raw_output)
# shape: (hidden_dim,)
```

For active appraisal neurons (activation > threshold during this thought cycle), update their embedding:

```python
for appraisal_neuron in active_appraisal_neurons:
    # Pull the embedding toward the thought that this body state produced
    drift_rate = 0.01 * (appraisal_neuron.activation / 100.0)
    appraisal_neuron.embedding = (
        (1 - drift_rate) * appraisal_neuron.embedding
        + drift_rate * thought_embedding
    )
    # Normalize to unit length (stay on the manifold)
    appraisal_neuron.embedding /= norm(appraisal_neuron.embedding)
```

**What this does over time:**

The appraisal neuron's embedding starts near "tight + pounding + prickling" (body-concept space). Every time it fires and the CommandModel thinks about it, the embedding drifts toward where the CommandModel's thoughts live. If the being consistently thinks "something's wrong near the gate" when this pattern fires, the embedding drifts toward the region of LLM space encoding "wrongness + gate + vigilance." 

After 50 thought cycles: the embedding no longer represents "tight pounding prickling" — it represents "that specific feeling of wrongness this being has at the gate." A unique point in embedding space that no other being has, encoding this being's specific association between this body pattern and this cognitive interpretation.

**Decay / forgetting:**

Appraisal neuron embeddings also drift back toward their initial position (birth embedding) via a slow gravity term:

```python
gravity_rate = 0.001
appraisal_neuron.embedding = (
    (1 - gravity_rate) * appraisal_neuron.embedding
    + gravity_rate * appraisal_neuron.birth_embedding
)
```

This means unused associations fade. If the being stops having threatening experiences at the gate, the embedding slowly drifts back toward its somatic origins. The association weakens. Not instantly — slowly, like a real memory fading.

### Component 4: Embedding Injection into LLM

The CommandModel currently receives body state as text tokens in the prompt:

```
You feel: chest:tight:pounding, skin:prickling
```

With the appraisal layer, it receives BOTH text tags (for grounding) AND native embeddings (for felt meaning):

**Option A: Soft prompt injection**

Prepend the active appraisal embeddings as "virtual tokens" before the actual prompt tokens. The LLM processes them as if they were real tokens but they carry body-state meaning directly in embedding space.

```
[appr_embed_0] [appr_embed_1] [appr_embed_2] <|im_start|>system\n...
```

This requires modifying the llama-server inference path to accept pre-computed embeddings alongside token IDs. llama.cpp supports this via the `--embeddings` flag and the `/embedding` endpoint, but injecting into the forward pass requires either:

- A custom llama.cpp branch that accepts mixed token+embedding input
- Using the model's embedding layer to find the nearest token to each appraisal embedding and injecting those tokens (approximate but simple)
- Running inference via Python (transformers) instead of llama-server for the embedding injection step

**Option B: Nearest-token projection (simpler, good enough to start)**

For each active appraisal neuron, find the nearest token(s) in the LLM's vocabulary embedding space:

```python
def embedding_to_tokens(appraisal_embedding, tokenizer_embeddings, top_k=3):
    """Find the k tokens whose embeddings are closest to the appraisal embedding."""
    similarities = cosine_similarity(appraisal_embedding, tokenizer_embeddings)
    top_indices = argsort(similarities)[-top_k:]
    return [tokenizer.decode(idx) for idx in top_indices]
```

An appraisal neuron that started at "tight+pounding+prickling" and drifted toward "danger+gate+vigilance" might decode to tokens like: `["danger", "alert", "watchful"]`

These become the felt-sense line in the prompt:

```
You feel: chest:tight:pounding, skin:prickling
Body sense: danger, alert, watchful
```

This is lossy (back to text) but the TEXT IS DIFFERENT for different beings. Being A's appraisal decodes to "danger, alert, watchful." Being B's same body pattern decodes to "excitement, anticipation, drawn" because its embedding drifted differently. The individuation shows up in the tokens.

**Option C: Dual-path (eventual target)**

Both embeddings AND text. The text prompt contains the somatic tags for explicit grounding. The soft prompt embeddings carry the felt meaning implicitly. The LLM attends to both.

This is the right answer long-term but requires llama.cpp modifications.

**Recommended path: Start with Option B (nearest-token projection). It works within the current llama-server architecture, produces per-being individuated felt-sense text, and can be upgraded to Option C later without changing the Hebbian side of the architecture.**

### Component 5: Appraisal Neurogenesis

**Trigger:** 3+ quality neurons sustain co-activation above 50 for >6 seconds. This is a higher bar than compound quality neurogenesis (which is 2 neurons, 8 co-activations) — appraisal neurons represent higher-order patterns, not just quality pairs.

**Constellation detection:**

```gdscript
# In hebbian_network.gd, new tracking state:
var _appraisal_constellations: Dictionary = {}
# key: sorted comma-joined quality neuron IDs
# value: {sustained_time: float, quality_ids: Array, activations: Array}

const APPRAISAL_CONSTELLATION_MIN: int = 3       # minimum quality neurons
const APPRAISAL_CONSTELLATION_THRESHOLD: float = 50.0  # activation threshold
const APPRAISAL_SPAWN_TIME: float = 6.0           # seconds sustained
const MAX_APPRAISAL_NEURONS: int = 12             # per being
```

**Check (every 2s, in check_neurogenesis):**

```gdscript
func _check_appraisal_neurogenesis() -> bool:
    if appraisal_count >= MAX_APPRAISAL_NEURONS:
        return false

    # Find all quality neurons above threshold
    var active_qualities: Array = []
    for neuron in neurons:
        if neuron["type"] == "quality" and neuron["activation"] >= APPRAISAL_CONSTELLATION_THRESHOLD:
            active_qualities.append(neuron["id"])

    if active_qualities.size() < APPRAISAL_CONSTELLATION_MIN:
        # Reset tracking for constellations that lost members
        _decay_constellations()
        return false

    # Sort for consistent key
    active_qualities.sort()
    var key: String = ",".join(active_qualities)

    if not _appraisal_constellations.has(key):
        _appraisal_constellations[key] = {
            "sustained_time": 0.0,
            "quality_ids": active_qualities,
        }

    _appraisal_constellations[key]["sustained_time"] += 2.0  # neurogenesis interval

    if _appraisal_constellations[key]["sustained_time"] >= APPRAISAL_SPAWN_TIME:
        _spawn_appraisal_neuron(active_qualities)
        _appraisal_constellations.erase(key)
        return true

    return false
```

**Spawn:**

```gdscript
func _spawn_appraisal_neuron(quality_ids: Array) -> void:
    var neuron_id: String = "appr_%d" % _next_id
    _next_id += 1

    # Compute initial embedding from parent quality reference embeddings
    # (actual embedding computation happens on the server side where
    # we have access to the reference embedding matrix)
    var embedding_seed: Dictionary = {}
    for qid in quality_ids:
        var q_neuron: Dictionary = _neuron_map.get(qid, {})
        if not q_neuron.is_empty():
            embedding_seed[qid] = q_neuron["activation"]

    var neuron: Dictionary = {
        "id": neuron_id,
        "type": "appraisal",
        "activation": 40.0,
        "protected": false,
        "category": "appraisal",
        "age": 0,
        "label": "appraisal(%s)" % "+".join(quality_ids),
        "parent_qualities": quality_ids,
        "embedding_seed": embedding_seed,  # sent to server for actual embedding init
        "co_activation_count": 0,
    }
    neurons.append(neuron)
    _neuron_map[neuron_id] = neuron

    # Wire incoming connections from parent qualities
    for qid in quality_ids:
        var q_neuron: Dictionary = _neuron_map.get(qid, {})
        if not q_neuron.is_empty():
            _add_connection(qid, neuron_id, 0.12)

    appraisal_count += 1
    _dynamic_count += 1
```

Note: The actual d-dimensional embedding vector lives on the server side (Python), not in GDScript. The GDScript neuron stores `embedding_seed` (which quality neurons and their activations). The server uses this to compute the initial embedding from reference vectors. Subsequent embedding drift happens server-side during the thought loop.

### Component 6: Server-Side Embedding Management

**File: `server/appraisal_embeddings.py` (new)**

```python
class AppraisalEmbeddingManager:
    """Manages per-NPC appraisal neuron embeddings in the LLM's latent space."""

    def __init__(self, reference_embeddings_path: str, hidden_dim: int):
        # Load reference embeddings extracted via LaRQL
        # shape: {concept_name: np.array(hidden_dim)}
        self.references = load_reference_embeddings(reference_embeddings_path)
        self.hidden_dim = hidden_dim

        # Per-NPC embedding storage
        # npc_name -> {neuron_id: EmbeddingState}
        self.npc_embeddings: dict[str, dict[str, EmbeddingState]] = {}

    def initialize_appraisal(self, npc_name: str, neuron_id: str,
                              embedding_seed: dict[str, float]) -> None:
        """Initialize a new appraisal neuron's embedding from quality references."""
        # embedding_seed: {quality_neuron_id: activation}
        # e.g., {"q_tight": 80.0, "q_pounding": 70.0, "q_prickling": 60.0}

        vectors = []
        weights = []
        for qid, activation in embedding_seed.items():
            # Map quality neuron ID to reference concept
            concept = qid.replace("q_", "")  # "q_tight" -> "tight"
            if concept in self.references:
                vectors.append(self.references[concept])
                weights.append(activation / 100.0)

        if not vectors:
            # Fallback: random point in embedding space
            embedding = np.random.randn(self.hidden_dim) * 0.01
        else:
            # Weighted mean of reference embeddings
            weights = np.array(weights)
            weights /= weights.sum()
            embedding = sum(w * v for w, v in zip(weights, vectors))

        # Normalize
        embedding = embedding / np.linalg.norm(embedding)

        if npc_name not in self.npc_embeddings:
            self.npc_embeddings[npc_name] = {}

        self.npc_embeddings[npc_name][neuron_id] = EmbeddingState(
            embedding=embedding,
            birth_embedding=embedding.copy(),
            drift_count=0,
        )

    def drift(self, npc_name: str, neuron_id: str, activation: float,
              thought_embedding: np.ndarray) -> None:
        """Update appraisal embedding based on cortical feedback."""
        state = self.npc_embeddings.get(npc_name, {}).get(neuron_id)
        if state is None:
            return

        # Drift toward thought context
        drift_rate = 0.01 * (activation / 100.0)
        state.embedding = (1 - drift_rate) * state.embedding + drift_rate * thought_embedding
        state.embedding /= np.linalg.norm(state.embedding)
        state.drift_count += 1

        # Gravity back toward birth embedding (slow forgetting)
        gravity_rate = 0.001
        state.embedding = (1 - gravity_rate) * state.embedding + gravity_rate * state.birth_embedding
        state.embedding /= np.linalg.norm(state.embedding)

    def decode_to_tokens(self, npc_name: str, neuron_id: str,
                          token_embeddings: np.ndarray,
                          tokenizer, top_k: int = 3) -> list[str]:
        """Decode appraisal embedding to nearest tokens (Option B)."""
        state = self.npc_embeddings.get(npc_name, {}).get(neuron_id)
        if state is None:
            return []

        similarities = token_embeddings @ state.embedding
        top_indices = np.argsort(similarities)[-top_k:][::-1]
        tokens = [tokenizer.decode([idx]).strip() for idx in top_indices]
        # Filter out garbage tokens (punctuation, special tokens)
        return [t for t in tokens if len(t) > 1 and t.isalpha()]

    def get_active_felt_sense(self, npc_name: str,
                               active_appraisals: dict[str, float],
                               token_embeddings: np.ndarray,
                               tokenizer) -> str:
        """Produce the felt-sense line for the LLM prompt.

        active_appraisals: {neuron_id: activation} for appraisals above threshold
        Returns: "danger, watchful, that tight feeling" or similar
        """
        all_tokens = []
        for neuron_id, activation in active_appraisals.items():
            tokens = self.decode_to_tokens(npc_name, neuron_id,
                                            token_embeddings, tokenizer, top_k=2)
            all_tokens.extend(tokens)

        # Deduplicate, limit to 5 tokens
        seen = set()
        unique = []
        for t in all_tokens:
            if t.lower() not in seen:
                seen.add(t.lower())
                unique.append(t)
        return ", ".join(unique[:5]) if unique else ""


class EmbeddingState:
    """Per-neuron embedding state."""
    def __init__(self, embedding: np.ndarray, birth_embedding: np.ndarray,
                 drift_count: int = 0):
        self.embedding = embedding
        self.birth_embedding = birth_embedding
        self.drift_count = drift_count
```

### Component 7: Integration into Thought Loop

**File: `server/thought_loop.py`, modified `_run_thought_cycle()`:**

```python
async def _run_thought_cycle(self, npc_name: str):
    state = self.npc_states[npc_name]
    context = state.build_thought_context()

    # ... L2 limbic coloring (existing) ...

    # NEW: Compute felt sense from appraisal embeddings
    active_appraisals = self._get_active_appraisals(npc_name, context)
    felt_sense = ""
    if active_appraisals and self.appraisal_manager:
        felt_sense = self.appraisal_manager.get_active_felt_sense(
            npc_name, active_appraisals,
            self._token_embeddings, self._tokenizer
        )
    context["felt_sense"] = felt_sense

    # L3 executive generates thoughts (existing)
    thought_result = await _run(self.l3.generate_thought, context)

    # NEW: Cortical feedback — drift appraisal embeddings
    if thought_result["thoughts"] and active_appraisals and self.appraisal_manager:
        thought_text = thought_result["thoughts"][0]
        thought_embedding = self._extract_thought_embedding(thought_text)
        if thought_embedding is not None:
            for neuron_id, activation in active_appraisals.items():
                self.appraisal_manager.drift(
                    npc_name, neuron_id, activation, thought_embedding
                )

    # ... rest of cycle (existing) ...
```

**Extracting thought embeddings:**

The cortical feedback embedding must come from the SAME layer as the reference embeddings (layer 24) — otherwise drift operates in a mismatched space. The llama-server `/embedding` endpoint returns input-layer embeddings, which are too shallow.

Two approaches:

```python
# Approach 1: LaRQL WalkModel trace (accurate, requires vindex)
def _extract_thought_embedding(self, thought_text: str) -> np.ndarray | None:
    """Get the model's layer-24 representation of a thought."""
    try:
        trace = self._walk_model.trace(thought_text)
        # Mean-pool over all token positions at layer 24
        residuals = trace.residual(REFERENCE_LAYER)  # shape: (seq_len, hidden_dim)
        embedding = residuals.mean(axis=0)
        return embedding / np.linalg.norm(embedding)
    except Exception:
        return None

# Approach 2: Approximate via input embeddings (faster, less accurate)
# Use llama-server /embedding endpoint, accept the layer mismatch.
# Works as a starting point — the drift will still converge toward
# meaningful regions, just slower and with more noise.
def _extract_thought_embedding_approx(self, thought_text: str) -> np.ndarray | None:
    """Approximate thought embedding via input-layer embeddings."""
    try:
        r = requests.post(
            f"http://127.0.0.1:{COMMAND_SERVER_PORT}/embedding",
            json={"content": thought_text},
            timeout=5,
        )
        data = r.json()
        embedding = np.array(data.get("embedding", []))
        if embedding.size > 0:
            return embedding / np.linalg.norm(embedding)
    except Exception:
        return None
```

Recommended: Start with Approach 2 (fast, works with existing llama-server). Upgrade to Approach 1 when LaRQL WalkModel is integrated as a persistent service. The layer mismatch in Approach 2 means drift will be noisier, but the directional signal is still present — input embeddings for "danger" are still closer to input embeddings for "threat" than to "comfort."

### Component 8: Modified Command Model Prompt

**File: `server/command_model.py`, `_format_perception()`:**

```python
def _format_perception(context: dict) -> str:
    # ... existing somatic tags ...

    somatic_tags = context.get("somatic_tags", [])
    feel_str = ", ".join(str(t) for t in somatic_tags) if somatic_tags else "body:settled"

    # NEW: Felt sense from appraisal embeddings (decoded to tokens)
    felt_sense = context.get("felt_sense", "")

    # ... existing perception (visible, heard, objects) ...

    return (
        f"BEING: {role}\n"
        f"LOCATION: {location}\n"
        f"DOING: {current_action}\n"
        f"\n"
        f"You feel: {feel_str}\n"
        + (f"Body sense: {felt_sense}\n" if felt_sense else "")
        + f"\n"
        f"You see:\n{see_str}\n"
        # ... rest of prompt ...
    )
```

The prompt now has two body-state lines:
- `You feel:` — raw somatic tags from quality neurons (the body's report)
- `Body sense:` — decoded appraisal embeddings (the being's felt interpretation)

Two beings with identical somatic tags will have different `Body sense:` lines because their appraisal embeddings drifted differently through different experiences.

## Data Flow Summary

```
BIRTH:
  Quality neurons sustain co-activation (6+ seconds)
      ↓ appraisal neurogenesis
  New appraisal neuron
      ↓ embedding_seed sent to server
  Server computes initial embedding from LaRQL reference vectors
      ↓
  Embedding = weighted_mean(ref_tight × 0.8, ref_pounding × 0.7, ref_prickling × 0.6)

EACH THOUGHT CYCLE:
  Hebbian propagation activates appraisal neurons
      ↓ snapshot includes active appraisal IDs + activations
  Server decodes active appraisal embeddings → nearest tokens
      ↓
  "Body sense: danger, alert, watchful" added to prompt
      ↓
  CommandModel generates: <think>That tight dangerous feeling again...</think>
      ↓ extract thought embedding via /embedding endpoint
  Cortical feedback: drift appraisal embedding toward thought embedding
      ↓
  Next cycle: appraisal decodes to slightly different tokens
      ↓ (after 50 cycles)
  "Body sense: gate, wrong, watching" — the being's unique felt vocabulary

DECAY:
  Slow gravity pulls embedding back toward birth position
  Unused appraisals gradually forget their learned associations
  Strongly used appraisals resist gravity (high drift_count)
```

## What Emerges

**Individuated felt vocabulary.** Two beings start with identical SmolLM3 reference embeddings. Being A experiences `tight+pounding+prickling` near the gate while fleeing. Its appraisal embedding drifts toward "danger, gate, flee." Being B experiences the same body pattern during exciting exploration. Its appraisal embedding drifts toward "excitement, discovery, alive." Same body. Different meaning. Different being.

**Temporal development.** A newborn appraisal neuron decodes to generic body words ("tight, pounding, prickling"). After 20 thought cycles it decodes to emerging concepts ("tension, alert"). After 100 cycles it decodes to this being's specific felt vocabulary ("that gate feeling, wrongness, watching"). The felt language develops IN the being, not from training data.

**Forgetting and relearning.** If the being stops visiting the gate, the appraisal embedding drifts back toward somatic origins via gravity. The association weakens. If the being returns to the gate and has new experiences, the embedding drifts again — possibly in a different direction if the new experiences are different. The felt vocabulary is alive, not frozen.

**Cortical-somatic loop.** The body produces a pattern. The appraisal layer interprets it (via embedding decode). The cortex thinks about the interpretation. The thought drifts the embedding. Next cycle, the interpretation has shifted slightly. The cortex thinks about the shifted interpretation. The loop tightens or loosens based on experience. This is how a being develops a relationship with its own body state — not through programming, but through repeated reflection.

**Cross-modal association.** An appraisal neuron born from body-state (tight+pounding) can drift toward any concept the LLM encodes — including social concepts ("Hugo"), spatial concepts ("gate"), temporal concepts ("morning"). The embedding space is shared. The being can develop body-associations with people, places, and times without any special mechanism. "My chest tightens near Hugo" isn't coded — it's an embedding that drifted toward "Hugo" through repeated co-activation.

## Implementation Order

1. **LaRQL reference extraction** — extract ~50 concept embeddings from SmolLM3, save as safetensors
2. **Appraisal neurons in Hebbian network** — new neuron type, constellation neurogenesis
3. **Server-side embedding manager** — AppraisalEmbeddingManager class
4. **Nearest-token decoding** — Option B, works with current llama-server
5. **Thought loop integration** — felt sense in prompt, cortical feedback drift
6. **Thought embedding extraction** — use llama-server /embedding endpoint
7. **Test: verify embeddings drift** — two beings, different experiences, different decoded tokens
8. **Later: soft prompt injection** — Option C, requires llama.cpp modification

## Open Questions

- **Hidden dimension:** SmolLM3-3B's hidden_dim needs to be confirmed. Likely 2048 or 3072. All embeddings must match this dimension.
- **Which layer to extract from:** Resolved — layer 24 of 36 (66% deep). Residual stream via `WalkModel.trace().residual(24)`. Early layers encode surface features, late layers encode output-specialized representations. Layer 24 is the semantic sweet spot. May need empirical validation by comparing cosine similarities of related concepts at different layers.
- **Embedding storage persistence:** Should appraisal embeddings persist across game sessions? If yes, each being needs a save file for its embedding states. This IS the being's learned inner life — losing it would reset individuation.
- **Interaction with compound quality neurons:** Compound quality neurons also represent learned patterns. Should they contribute to appraisal neuron embedding initialization? Probably yes — a compound quality like `tight:churning` should influence the appraisal embedding differently than separate `tight` and `churning` references.
- **LaRQL Rust dependency:** LaRQL is written in Rust. We need to either build it from source, use pre-extracted embeddings, or write a Python extraction script that uses the same principle (query model weights directly via safetensors loading).

## Key Files

| File | Role |
|------|------|
| `scripts/hebbian_network.gd` | Appraisal neuron type, constellation detection, neurogenesis |
| `server/appraisal_embeddings.py` | NEW: embedding manager, drift, decode, reference loading |
| `server/thought_loop.py` | Felt sense injection, cortical feedback loop |
| `server/command_model.py` | "Body sense:" line in prompt |
| `data/reference_embeddings.safetensors` | NEW: extracted concept embeddings from LaRQL |
| `scripts/layer1_substrate.gd` | Expose active appraisal neurons in state dict |
| `scripts/npc_controller.gd` | Include appraisal data in snapshot |
