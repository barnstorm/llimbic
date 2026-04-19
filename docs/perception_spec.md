# Perception Protocol: Emergent Substrate for Individuation

> **Status.** Draft 3. Replaces draft 2. The central shift: where draft 2 hand-authored affordance layers, salience weights, and IdentityProfile fields, draft 3 makes each of these emergent from a learning rule and commits pre-seeded values to a required decay path. The game engine is reframed as an experimental harness, not a product surface.

## 0. Preface — the substrate failure observed

`/tmp/burg_trace_1776399898.jsonl`, 351 thoughts, 2 NPCs, v1 model:

| Observation | Value |
|---|---|
| Visible entities per thought | 0.02 avg |
| Heard events / objects per thought | 0.00 / 0.00 |
| Verb distribution | GO TO: 63%; SAY/TAKE/TOUCH/INTERACT/OFFER/REST/HIDE: 0 |
| Somatic co-firing | `chest:tight+gut:tight+throat:tight+muscles:tight`: 93% of thoughts |
| Grounding | Hugo sees Mabel at 0.6 tiles → thinks "My stomach is growling. Need to find something to eat." |
| Recent thoughts | Verbatim repetition across consecutive thought cycles |
| Trace fidelity | `visible_objects: ['Notice Board']` — structure lost |

Every number is diagnostic. The substrate does not produce differentiated perception, differentiated body state, grounded thought, verb diversity, or per-being signal. This is not a prompt-engineering problem. It is a substrate problem.

## 1. The three-tier commitment

Every design element in this document is placed in exactly one of three tiers:

**Tier 1 — Substrate (irreducible).** Properties of the organism that cannot be learned without themselves assuming something to learn. Fixed forever. Examples: drives, body regions, the Hebbian learning rule itself, the embedding-space bridge mechanism.

**Tier 2 — Bootstrap seed.** Starting values required to begin operation. Every Tier-2 value has a **decay path** — a specified mechanism by which experience overrides it. A seed without a decay path is Tier-1 in disguise and must be relabeled. Seeds with decay paths are fine: they are priors; experience is the likelihood; given enough observation, posteriors wash the priors out.

**Tier 3 — Emergent.** What the substrate produces given time and experience. Not specified as content — specified as the learning mechanism that produces it. "Affordance layers" is not Tier 3; "affordance compound neurons emerge from (distance × action-success) co-firing" is Tier 3.

Draft 2 failed this discipline. Affordance thresholds, salience weights, IdentityProfile fields, drive affinities, concept seed lists — all presented as constants, all in fact Tier 3 content wearing Tier 1 clothes. Draft 3 corrects.

The contract: **for any Tier-2 seed, we must be able to demonstrate that a being exposed to sufficient experience exhibits behavior independent of that seed's value.** That demonstration is part of acceptance (§9.3).

## 2. Tier 1 — the irreducible substrate

### 2.1 Sensors

Pixel-space FOV cone (96px), raycasting, hearing range (80px) as currently implemented (`SensorSystem`). Per-frame output for each NPC:

```
raw_visible_entities: [{entity_id, position, distance_pixels, exposure, doing}, …]
raw_visible_objects:  [{object_id, name, state, position, distance_pixels, exposure}, …]
raw_heard_events:     [{source, text, position, distance_pixels}, …]
raw_glimpsed_structures: [{direction, distance_pixels, structure_class}, …]
```

Pixel → tile conversion is a display-space concern. Distance is a continuous float. Direction is a continuous 2D unit vector (cardinalization is a decoder concern, not a sensor concern).

**Nothing is bucketed at the sensor.** Buckets are decoded outputs of emergent mechanisms or bootstrap seeds, not sensor outputs.

### 2.2 Drives

Four homeostatic drives on [0, 100]: `energy`, `hunger`, `social_need`, `safety`. Update rules are physical: energy depletes over time and recovers with REST/CONSUME food; hunger rises over time and falls with CONSUME food; social_need rises in solitude and falls with social interaction; safety rises with `vagal_ventral > threshold` sustained and falls with threat exposure.

Drives are substrate because **reward is defined as drive-deltas**. Without a fixed drive definition, reward has no meaning, and reward-gated learning has nothing to train on.

### 2.3 Body regions

Seven: `chest, gut, skin, muscles, head, throat, body`. Assigned to quality neurons as polysemic regions (the existing `hebbian_network.gd:221-259` pattern). These are anatomical priors — the being's body has a physical structure that must exist before qualities can be felt "somewhere."

### 2.4 Hebbian learning rule

Co-activation above threshold strengthens the connection:

```
Δw_ij = η · pre_i · post_j · (max(0, pre_i - θ) · max(0, post_j - θ))
```

With reward-gating modifier:

```
Δw_ij *= (1 + β · recent_reward_signal)
```

Where `recent_reward_signal` decays with a short time constant after each reward event. Reward-gating is what allows the substrate to learn not just *what fires together* but *what fires together and was followed by good outcomes*.

Parameters (η, θ, β, decay) are Tier 2 — bootstrap constants with tuning latitude, not emergent.

### 2.5 Neurogenesis rules

The rules for *when* new neurons spawn are substrate. The content of those neurons (what they represent, what they connect to) is emergent.

Current rules (`hebbian_network.gd`):

- Stress neurogenesis: frustration sustained → dynamic stress neuron
- Novelty neurogenesis: low familiarity + exposure duration → novelty neuron
- Reward neurogenesis: reward signal + co-active path → reward neuron
- Vagal bridge: sustained vagal-action co-activity → vagal bridge
- Compound quality: paired quality co-firing → compound quality neuron

**Extensions required for this spec:**

- **Identity-encounter neurogenesis** — N encounters with the same entity_id + thought co-occurrence → per-identity appraisal neuron (§5.2)
- **Distance-action neurogenesis** — continuous distance-sensory co-firing with action-success → distance-affordance compound neuron (§5.1)
- **Cross-modal neurogenesis** — visual-sensory and auditory-sensory for same entity_id co-firing → binding neuron (§5.4)
- **Persistence neurogenesis** — sensory activation sustained across N ticks → dwell-sensitive neuron (§5.5)

Each extension is a *rule*, not content. The being discovers the content.

### 2.6 Appraisal bridge mechanism

The mechanism — not the content, not the vocabulary — is substrate. Three operations:

1. **Extract** a thought or concept's representation as a vector in LLM latent space.
2. **Drift** per-being appraisal embeddings toward extracted thought vectors.
3. **Decode** an appraisal embedding back to nearest tokens for prompt injection.

These three operations are non-negotiable. Without them, emergent individuation at the perception layer cannot exist. See §3.

### 2.7 Reward event vocabulary

Homeostatically defined, enumerated:

```
reward_drive_satisfaction    // drive_value crossed below urgency_threshold
reward_drive_stabilization   // sustained drive_value in safe band
reward_social_accepted       // dialogue/gift/offer accepted by other
reward_rest_recovered        // REST completed in safe context
reward_explore_discovered    // entered novel location first time
reward_threat_avoided        // FLEE FROM or HIDE executed, threat_entity_distance increased
reward_action_succeeded      // any action's engine-reported success
```

Each event carries a magnitude in [0, 1]. Beings don't learn what counts as reward — evolution fixed that. Beings learn *what predicts* reward.

`hebbian_network.gd:1001 signal_reward()` is declared but never called today. Wiring it is Tier 1 substrate completion, not an addition.

### 2.8 Action grammar

The verb vocabulary and parameter shapes (`server/command_grammar.py`) are substrate because they define the interface contract with the game engine. A being can learn *when* to invoke verbs, not *what verbs exist*.

### 2.9 LLM latent space

The LLM's internal representation space is substrate — it's the shared coordinate system within which all beings' appraisal embeddings drift. We don't train the LLM per-being. One model, one latent space, many trajectories through it.

## 3. The embedding bridge — Tier 1 implementation

Phase 0 of this spec delivers this component. Nothing else is implementable without it.

### 3.1 Tier commitment

We commit to T0 (input-layer embeddings via llama-server `/embedding` endpoint). Mid-layer extraction (T1) and direct soft-prompt injection (T2) are deferred. The `EmbeddingSource` interface is tier-agnostic so upgrade paths remain open without rewriting consumers.

### 3.2 Server configuration change

`server/command_model.py:233-245` launches llama-server without `--embedding`. Add the flag and `--pooling mean`:

```python
subprocess.Popen([
    self._llama_bin,
    "-m", self.gguf_path,
    "--port", str(COMMAND_SERVER_PORT),
    "--ctx-size", "2048",
    "-t", "8",
    "-np", "2",
    "--embedding", "--pooling", "mean",
    "--log-disable",
], ...)
```

`/completion` and `/embedding` coexist on the same port in current llama.cpp. One process, both endpoints.

### 3.3 Token embedding matrix

One-time extraction from base SmolLM3-3B:

```python
# tools/extract_token_embeddings.py
from safetensors.torch import load_file, save_file
import torch
from transformers import AutoModel

model = AutoModel.from_pretrained("HuggingFaceTB/SmolLM3-3B", torch_dtype=torch.float16)
emb = model.embed_tokens.weight.detach().cpu().numpy()  # [vocab_size, hidden_dim]
save_file({"token_embeddings": torch.tensor(emb)}, "data/token_embeddings_layer0.safetensors")
# ~250 MB for SmolLM3-3B vocab at hidden_dim 2048 in fp16
```

Loaded once at server start; used for nearest-token decode via cosine similarity. Cosine against full 50k vocabulary at 2048 dims ≈ 50ms per decode with numpy; can be cached per-neuron when the neuron's embedding hasn't drifted significantly since last decode.

### 3.4 `EmbeddingSource` interface

```python
# server/embedding_source.py

class EmbeddingSource(Protocol):
    def embed(self, text: str) -> np.ndarray: ...
    def embed_batch(self, texts: list[str]) -> np.ndarray: ...

class LlamaServerEmbeddingSource:
    """T0 implementation — llama-server /embedding endpoint."""
    def __init__(self, port: int):
        self.port = port
        self._session = requests.Session()
        self._cache = LRUCache(maxsize=2048)  # concept embeddings

    def embed(self, text: str) -> np.ndarray:
        if text in self._cache:
            return self._cache[text]
        r = self._session.post(
            f"http://127.0.0.1:{self.port}/embedding",
            json={"content": text}, timeout=5,
        )
        v = np.array(r.json()["embedding"])
        v /= np.linalg.norm(v) + 1e-9
        self._cache[text] = v
        return v

    def embed_batch(self, texts: list[str]) -> np.ndarray:
        return np.vstack([self.embed(t) for t in texts])
```

Later `TransformersMidLayerEmbeddingSource` replaces this with layer-24 residual extraction; consumers don't change.

### 3.5 `AppraisalEmbeddingManager`

```python
# server/appraisal_embeddings.py

@dataclass
class AppraisalState:
    neuron_id: str
    embedding: np.ndarray         # current, unit-norm
    birth_embedding: np.ndarray   # where it started
    drift_count: int              # cycles that fed cortical feedback
    last_decoded_tokens: list[str] | None
    last_decoded_at: float        # for decode caching

class AppraisalEmbeddingManager:
    def __init__(self, source: EmbeddingSource, token_embeddings: np.ndarray,
                 tokenizer, filter_vocab: set[int] | None = None):
        self.source = source
        self.token_embeddings = token_embeddings  # [V, H], unit-norm rows
        self.tokenizer = tokenizer
        self.filter_vocab = filter_vocab  # optionally restrict decode to meaningful tokens
        self.states: dict[str, dict[str, AppraisalState]] = {}  # npc → neuron_id → state

    def initialize(self, npc: str, neuron_id: str, seed_concepts: dict[str, float]):
        """seed_concepts: {concept_text: weight}.  e.g., {'tight': 0.8, 'pounding': 0.6}
        Weight-normalized mean of concept embeddings becomes initial position.
        """
        vectors, weights = [], []
        for concept, w in seed_concepts.items():
            if w > 0:
                vectors.append(self.source.embed(concept))
                weights.append(w)
        if not vectors:
            emb = np.random.randn(self.token_embeddings.shape[1]).astype(np.float32)
        else:
            ws = np.array(weights); ws /= ws.sum()
            emb = sum(w * v for w, v in zip(ws, vectors))
        emb = emb / (np.linalg.norm(emb) + 1e-9)
        self.states.setdefault(npc, {})[neuron_id] = AppraisalState(
            neuron_id=neuron_id,
            embedding=emb,
            birth_embedding=emb.copy(),
            drift_count=0,
            last_decoded_tokens=None,
            last_decoded_at=0.0,
        )

    def drift(self, npc: str, neuron_id: str, activation: float,
              thought_embedding: np.ndarray, drift_rate: float = 0.01,
              gravity_rate: float = 0.001):
        st = self.states.get(npc, {}).get(neuron_id)
        if st is None:
            return
        r = drift_rate * (activation / 100.0)
        st.embedding = (1 - r) * st.embedding + r * thought_embedding
        st.embedding = (1 - gravity_rate) * st.embedding + gravity_rate * st.birth_embedding
        st.embedding /= (np.linalg.norm(st.embedding) + 1e-9)
        st.drift_count += 1
        st.last_decoded_tokens = None  # invalidate cache

    def decode(self, npc: str, neuron_id: str, top_k: int = 3) -> list[str]:
        st = self.states.get(npc, {}).get(neuron_id)
        if st is None:
            return []
        if st.last_decoded_tokens is not None:
            return st.last_decoded_tokens
        sims = self.token_embeddings @ st.embedding
        if self.filter_vocab is not None:
            mask = np.full_like(sims, -np.inf)
            mask[list(self.filter_vocab)] = 0
            sims = sims + mask
        top_ids = np.argpartition(-sims, top_k)[:top_k]
        top_ids = top_ids[np.argsort(-sims[top_ids])]
        tokens = [self.tokenizer.decode([int(i)]).strip() for i in top_ids]
        # Filter garbage (punctuation, control, too short)
        tokens = [t for t in tokens if len(t) > 1 and any(c.isalpha() for c in t)]
        st.last_decoded_tokens = tokens[:top_k]
        st.last_decoded_at = time.time()
        return st.last_decoded_tokens

    def persist(self, npc: str, path: str):
        data = {}
        for nid, st in self.states.get(npc, {}).items():
            data[nid] = {
                "embedding": st.embedding.tolist(),
                "birth_embedding": st.birth_embedding.tolist(),
                "drift_count": st.drift_count,
            }
        with open(path, "w") as f:
            json.dump(data, f)

    def load(self, npc: str, path: str):
        if not os.path.exists(path):
            return
        with open(path) as f:
            data = json.load(f)
        self.states.setdefault(npc, {})
        for nid, d in data.items():
            self.states[npc][nid] = AppraisalState(
                neuron_id=nid,
                embedding=np.array(d["embedding"], dtype=np.float32),
                birth_embedding=np.array(d["birth_embedding"], dtype=np.float32),
                drift_count=d["drift_count"],
                last_decoded_tokens=None,
                last_decoded_at=0.0,
            )
```

### 3.6 Cortical feedback loop

Per thought cycle, after LLM generation:

```python
# server/thought_loop.py additions

async def _run_thought_cycle(self, npc_name: str):
    # ... existing: context build, L2 coloring, L3 generation ...

    if thought_result.get("thoughts"):
        think_text = thought_result["thoughts"][0]
        thought_emb = self.embedding_source.embed(think_text)

        active_appraisals = self._get_active_appraisals(npc_name)  # from Hebbian
        for neuron_id, activation in active_appraisals.items():
            self.appraisal_manager.drift(
                npc=npc_name, neuron_id=neuron_id,
                activation=activation, thought_embedding=thought_emb,
            )
```

### 3.7 Per-NPC persistence

Identity and body appraisal embeddings are the being's learned inner life. Losing them across sessions erases individuation. Persist to `saves/{npc_name}/appraisals.json` on session close; load on start.

Rule: persist only appraisal neurons with `drift_count > 10` — long-standing associations. Shorter-lived neurons reset per session as a soft forgetting mechanism.

### 3.8 What T0 doesn't give us

Input-layer embeddings are lexical-contextual, not deeply semantic. "tight" and "pounding" are similar only insofar as they appear in similar surface contexts in SmolLM3's training data. At T1 (layer 24), they would cluster by somatic-emotional role. At T0 they cluster by token co-occurrence.

Practical implication: per-being individuation WILL be measurable at T0 (beings whose thoughts differ will drift into different input-space regions), but the *semantic character* of those regions will be noisier than at T1. This is an explicit tradeoff for shipping Phase 0 quickly.

## 4. Tier 2 — bootstrap seeds with decay paths

Every value here is a starting condition, not a permanent rule. Each line specifies the decay mechanism.

### 4.1 Initial Hebbian topology

**Seed.** Base neurons exist at birth (drives, sensory, qualities with anatomical region assignments, action, vagal). Initial connection weights per `hebbian_network.gd:221-259`.

**Decay.** Reward-gated Hebbian learning strengthens predictive pathways and weakens unpredictive ones. Connections with sustained near-zero co-activation atrophy (decay term in propagation). Over long play, topology shifts substantially from seed.

### 4.2 Initial seed concepts for appraisal neuron birth

**Seed.** When an appraisal neuron spawns from a quality constellation, its embedding is initialized as a weighted mean of concept embeddings drawn from a small bootstrap concept set: `[tight, loose, warm, heavy, settled, churning, pounding, hollow, prickling, open, clear, foggy, buzzing, numb]`. Only the tokens appearing in the spawning constellation's labels are used as seeds.

**Decay.** Cortical feedback drift (§3.6) moves the embedding every cycle the neuron fires. After ~100 drift cycles, the influence of initial position on current position is approximately `(1 - 0.01)^100 ≈ 0.37`. After 500 cycles, ≈ 0.007. Initial position is asymptotically forgotten.

Acceptance test: a being with altered bootstrap seed concepts (scrambled mapping) reaches the same behavioral distribution as a being with standard seeds after sufficient play.

### 4.3 Initial persona-given entity priors

**Seed.** Authored persona files may set initial `trust` (and optionally preliminary `threat`, `warmth`) for specific entity IDs, via the existing `memory_system.gd` relationships dict.

**Decay.** Reward-driven updates (§5.2) override persona values as encounters accumulate. After ~30 encounters with consistent reward signal, experiential priors dominate persona priors. Beings trained to "distrust Guard" via persona but rewarded for positive Guard interactions will drift toward trust.

### 4.4 Initial reward-gating rate β

**Seed.** β = 0.5 — reward signal doubles Hebbian updates at peak.

**Decay.** Not strictly decaying; β stays fixed unless tuning reveals learning instability. Classified Tier 2 because the value is defensible but arbitrary; if play shows pathological learning, β becomes a Tier-3 target (meta-learned per being). Deferred meta-learning.

### 4.5 Initial neurogenesis thresholds

**Seed.** The existing thresholds in `hebbian_network.gd` (quality constellation min 2, sustained time 8 occurrences in 30s; appraisal constellation min 3, 6s sustained; stress >75 for >3s; novelty <30 for >5s).

**Decay.** These are spawn rates, not content. They affect how *quickly* the being develops new neurons, not what those neurons represent. Still Tier 2 because fast-forwarding for experiments may need aggressive thresholds. Tune per experiment; baseline values stand.

### 4.6 Initial FOV / hearing thresholds

**Seed.** 96px / 80px. Engine-side sensor constants.

**Decay.** These are physical body constraints, not learned perception. Technically Tier 1. Listed here only because a designer may want to explore short-sighted or long-sighted beings for specific experiments — in which case they become Tier 2 (scenario-specific). For the default being, treat as Tier 1.

### 4.7 Initial appraisal neuron MAX per being

**Seed.** 12 per being (per `appraisal_layer_spec.md`).

**Decay.** Not decaying. This is a capacity constraint. Can expand in future phases if memory budget allows. Tier 2 because it's a tuning parameter, not a learning target.

### 4.8 Initial salience — absent

**Not seeded.** Salience does not have an authored starting value. It emerges as propagation weight from sensory neurons, initially uniform (default Hebbian connections to downstream), diverging as reward-gated learning reinforces rewarding pathways. See §5.3.

## 5. Tier 3 — emergent mechanisms

Each subsection specifies the mechanism that produces an emergent property. The content of the property is *not* spec'd because it is not ours to decide.

### 5.1 Affordance as compound-neuron emergence

**What the previous spec called "affordance layers" (reach/near/view/far/glimpse)** is not authored. It emerges as the receptive field of compound quality neurons tuned to verb-specific distances.

**Substrate surface needed:**

- **Continuous distance sensory neurons, per visible entity/object.** Added to the Hebbian substrate: when entity ID X is visible, a sensory neuron `sense_dist_X` activates with value `100 * exp(-dist/τ)` where dist is in tiles and τ = 4 (tuning). At dist=0, activation = 100. At dist=4, activation = 37. At dist=16, activation = 2. Smooth, no buckets.
- **Per-verb action-success signals.** When a verb executes on a target and the engine reports success: emit a transient reward-class signal `action_success_{verb}`, strength 50, decay 2s.
- **Reward-gated Hebbian neurogenesis — distance-action compound:** when `sense_dist_X` and `action_success_{verb}` co-fire at a specific distance band repeatedly (N times over M seconds), spawn a compound neuron `q_{verb}able` whose receptive field is the empirically-successful distance range.

**Emergence:** After sufficient trials, a being develops `q_touchable`, `q_interactable`, `q_offerable`, etc. Each has a distance-sensory receptive field tuned to where that verb has empirically succeeded. The being's "reach" is a Gaussian response of `q_touchable`, not a threshold.

**Decoded appearance in prompt:** when `q_touchable` is firing above threshold on percept X, it is an active appraisal neuron; its decoded tokens ("close", "within", "reach") appear inline in the percept. The word "reach" in the prompt is decoded, not authored. Different beings develop subtly different tokens because their drift histories differ.

**Per-being differentiation:** a being that has mostly succeeded at TAKE from very close distances will have a `q_touchable` with a tighter receptive field. A being that has succeeded from slightly further (perhaps with different arm-reach priors) will have a wider one. Both work; neither is "correct."

**Acceptance.** After 200 action-success events distributed across 4+ verbs, the being has at least 2 distinct `q_*able` compound neurons. Their decoded token sets differ (shared token overlap < 60%).

### 5.2 Identity as outer-appraisal emergence

**What the previous spec called IdentityProfile (threat/warmth/surprise/trust)** is not authored. It emerges as per-entity appraisal neurons whose embedding trajectories are shaped by thoughts the being had while encountering that entity.

**Substrate surface needed:**

- **Per-entity encounter accumulator.** Per NPC, per entity_id: `{encounter_count, first_seen, last_seen, cumulative_seen_duration, thought_embeddings_during_encounters}` — the last is a small deque of recent thought vectors associated with this entity.
- **Encounter-constellation neurogenesis rule.** When an entity_id accumulates `ENCOUNTER_THRESHOLD` encounters (seed value: 5), each with an associated thought, spawn an appraisal neuron `appr_identity_{entity_id}`. Initial embedding = mean of accumulated thought embeddings; falls back to weighted mean of seed concepts (entity role, typical layer the being encountered them at) if thought log is sparse.
- **Hebbian wiring.** `appr_identity_{entity_id}` is wired incoming from `sense_visible_{entity_id}` and from the somatic streams active during its spawning encounters. Outgoing to action and vagal neurons develops via Hebbian learning — the being learns to respond to this specific entity based on what happened during encounters.

**Emergence:** Per-being identity representations. Two beings, same entity, different representations — because the thoughts they had during encounters differed. No "threat" field was authored; if this being tends to be threatened by that entity, the decoded tokens skew toward danger-region words. If their encounters were benign, the decoded tokens skew toward warmth or neutral.

**Decoded appearance:** when Mabel is visible and `appr_identity_Mabel` is firing, its decoded tokens become inline attributes of Mabel in the prompt — "Mabel, northeast, walking, {decoded tokens}" → "Mabel, northeast, walking, familiar warmth, settled".

**Per-being differentiation:** Hugo's Mabel-appraisal diverges from Ivy's Mabel-appraisal because Hugo thought different things during his Mabel-encounters than Ivy did.

**Acceptance.** After 20 encounters distributed across 3+ entity IDs, the being has at least 2 `appr_identity_*` neurons. The pairwise cosine distances between their decoded-token vectors are > 0.3 (differentiated; they don't all decode to the same tokens).

### 5.3 Salience as propagation-weight emergence

**What the previous spec called a salience function with weighted factors** is not authored. It emerges as the natural consequence of reward-gated Hebbian learning on the sensory→downstream pathways.

**Substrate surface needed:**

- **All sensory neurons project downstream uniformly at birth** (seed weights roughly equal, with small random perturbation).
- **Reward-gated Hebbian strengthens sensory→{quality, action, vagal} connections whose pre-activation preceded reward.** Sensory neurons whose firing predicts reward grow stronger outgoing weights. Their activations propagate more strongly into the network.
- **No separate salience function.** The being "pays attention" to percept X proportionally to the outgoing propagation weight of `sense_X`. High propagation = lots of downstream influence = "salient." Low propagation = quiet influence = "unsalient."

**Emergence:** Two beings in identical sensory fields produce different downstream states because their sensory→downstream weights differ. A guard-trained being's `sense_visible_armed_entity` has strong outgoing weights (reward history on attending to armed entities). A healer-trained being has strong outgoing weights on `sense_visible_wounded_entity`. Neither being has a "salience weight vector" — the weights live in the Hebbian graph.

**Top-K filtering for prompt:** the LLM's prompt is context-limited, so something must select. The selection rule: rank percepts by the summed outgoing weight of their sense-neuron, take top K. **K is a hard limit; ranking is emergent.**

**Per-being differentiation:** what each being "sees first" in a crowd differs. The individuation substrate is the Hebbian graph itself.

**Acceptance.** After 30 minutes of reward-accumulating play, two beings with different reward histories produce measurably different top-K orderings given identical synthetic percept scenes. Ranking correlation (Spearman) < 0.7 on a 50-scene probe.

### 5.4 Cross-modal binding as co-activation emergence

**What the previous spec called cross-modal binding with authored rules** is not authored. It emerges as co-activation neurogenesis between visual and auditory sensory channels.

**Substrate surface needed:**

- **Distinct visual-sensory and auditory-sensory neurons per entity ID.** `sense_visible_X` and `sense_heard_X` exist as separate sensory channels, both activated by their respective modality when source=X.
- **Within-tick co-activation tracking.** When both neurons fire within the same tick window.
- **Pair-co-activation neurogenesis.** N co-activation events over M seconds spawn a compound `bind_{entity_id}` neuron wired to both.

**Emergence:** A being that has heard Mabel's voice while seeing Mabel N times spawns `bind_Mabel`. When only visual or only auditory fires, `bind_Mabel` partially activates — less strongly than when both fire. This provides the "voice matches face" percept without any authored binding rule.

**Decoded appearance:** when `bind_Mabel` fires at full strength alongside `appr_identity_Mabel`, the prompt renders Mabel with a unified percept. When only one modality is present, the prompt tags uncertainty — not by an authored rule but because the partial binding produces weaker appraisal activation, which decodes to less-confident tokens.

**Acceptance.** After 30 encounters with at least one entity producing both visual and auditory percepts, the being has at least 1 `bind_*` compound neuron.

### 5.5 Temporal texture as persistence-sensitive emergence

**What the previous spec called velocity / dwell / familiarity fields** is not authored. It emerges from persistence-sensitive sensory neurons and neurogenesis from sustained firing patterns.

**Substrate surface needed:**

- **Persistence channel on each sensory neuron.** Alongside `sense_dist_X(t)`, derivatives and integrals are cheap: `sense_dist_X_rate(t) = sense_dist_X(t) - sense_dist_X(t-1)`; `sense_dist_X_dwell(t) = integral over recent window of sense_dist_X`. Both are substrate-cheap continuous channels, computed per tick.
- **Neurogenesis on sustained firing.** A compound neuron spawns when `sense_X_dwell` has been high for T seconds — `q_X_lingering`.
- **Neurogenesis on rapid change.** A compound neuron spawns when `sense_X_rate` has been high for T seconds — `q_X_approaching_fast`.

**Emergence:** Beings develop categorical responses to temporal patterns they've experienced. One being might develop `q_threat_approaching_fast` (if fast-approaching threats were rewarded-to-avoid). Another might not develop it because their experience didn't include fast-approaching threats.

**Decoded appearance:** `q_X_approaching_fast` firing on percept X makes its decoded tokens include rapid-approach words — without any rule that says "if approach_rate > 0.4, render 'approaching fast.'"

**Acceptance.** After a 15-minute session that includes at least 5 approach events and 5 dwell events, the being has at least 2 temporal-texture neurons (`q_*_lingering` or `q_*_approaching_*`).

### 5.6 Active perception as intention-attention coupling emergence

**What the previous spec called intention-driven salience boost** is not authored. It emerges from a Hebbian coupling between intention-context neurons and sensory-propagation weights.

**Substrate surface needed:**

- **Intention-context neurons.** When the L3 executive sets an intention (`Goal:` field), the intention's text is embedded; its nearest-concept-in-the-Hebbian-graph neurons activate (e.g., "find food" activates neurons whose decoded tokens are food-related).
- **Intention-gated Hebbian.** When intention-neuron I and sensory-neuron S co-fire, and subsequently action-success occurs, the I→S-propagation pathway strengthens (not just sense→action; the modulation is specifically under-this-intention).
- **At each sensory tick, propagation from sense-neurons is multiplied by (1 + contribution from currently-active intention neurons).** So a being "looking for food" propagates food-sense neurons more strongly than other sense neurons.

**Bootstrap wire.** One seed wire: the intention-neuron's output connects uniformly to the sense-modulation pathway. This is Tier 2 (seed) — the Hebbian learning reshapes it to reward-correlated pairs. With enough reward signal, the initial uniform wire is replaced by learned intention-specific modulations.

**Emergence:** "Hungry beings see food more saliently" is not coded; it emerges from `sense_food × intention_hunger_active × reward_eat_succeeded` co-firing history. Two hungry beings exposed to the same scene attend differently based on which food types they've been rewarded by.

**Acceptance.** After reward history includes 20+ `(intention, sense)` pairs, the top-K ranking of an identical scene differs when the being's current intention differs (same being, two intentions, two different K-rankings).

## 6. Data shape

### 6.1 Sensor output

Unchanged. Continuous, pixel-space, per-frame.

### 6.2 Hebbian sensory activations

Per tick, computed by the perception module from sensor output:

```python
sensory_activations = {
    f"sense_visible_{entity_id}": v_intensity,  # 0-100
    f"sense_dist_{entity_id}": 100 * exp(-dist_tiles / TAU),
    f"sense_heard_{entity_id}": h_intensity,
    # … one entry per visible entity, heard source, visible object
}
```

No categorical layer keys. Just continuous-activation sense-neurons.

### 6.3 Percept for prompt

Constructed at prompt-render time, not at sensor-read time:

```python
@dataclass
class Percept:
    entity_id: str
    name_render: str                        # decoded: may be "Mabel" or "someone"
    direction_text: str                     # decoded from direction_vec (cardinal is a safe default decoder)
    inline_tokens: list[str]                # decoded from active appraisal neurons touching this entity
    speech: str | None                      # from heard events bound by bind_* neuron firing
```

`inline_tokens` is the emergence surface. It contains whatever decoded tokens the being's currently-firing appraisal neurons produce. For a being with `q_touchable` firing and `appr_identity_Mabel` firing and `bind_Mabel` firing: `inline_tokens = ["close", "familiar", "warmth"]` (example — depends on the actual drift trajectory).

### 6.4 Prompt rendering

No hand-authored layer blocks. No hand-authored categorical structure. The percept rendering is:

```
You see:
  - {name_render}, {direction_text}{inline_tokens_if_any}{speech_if_any}
  - {name_render}, {direction_text}{inline_tokens_if_any}
  - ...

You hear:
  - {unbound_source}, {direction_text}: "{text}"  (for unbound heard events)
  - silence                                         (if no heard events)
```

Ordering within `You see:` is by top-K emergent salience (§5.3). Entity vs. object is not categorically distinguished — a brick oven and a person both render as entities; their inline tokens differentiate them via appraisal decoding.

The prompt is lean. The meaning comes from decoded tokens, not from authored structure.

### 6.5 Trace record

Per thought cycle, write:

```jsonc
{
  "trace_schema_version": 2,
  "type": "thought",
  "timestamp": 1776399898.12,
  "npc": "Hugo",
  "sensory_activations": { ... full dict of sense-neuron activations ... },
  "active_appraisals": [
    {"id": "q_touchable", "activation": 72.0, "decoded_tokens": ["close", "within", "reach"]},
    {"id": "appr_identity_Mabel", "activation": 64.0, "decoded_tokens": ["familiar", "warmth"]},
    ...
  ],
  "active_qualities": {"q_tight": 45.0, "q_warm": 30.0, ...},
  "prompt_rendered": "full text of user prompt",
  "thought": "...",
  "command": "APPROACH Mabel",
  "reward_events_this_tick": ["action_success_APPROACH"],
  "neurogenesis_events_this_tick": [],
  ...
}
```

Full fidelity. Nothing is summarized away. A v3 training regenerator can replay from this trace without information loss.

## 7. Integration with existing subsystems

### 7.1 Hebbian substrate

- Add per-entity, per-object sensory neurons spawned by encounter neurogenesis.
- Add continuous distance sensory neurons per visible target.
- Add persistence/rate channels per sense-neuron.
- Wire `signal_reward()` — end-to-end. Receive reward events from engine, feed to Hebbian update modifier.
- Add compound-neuron neurogenesis rules per §5.1, §5.4, §5.5.

### 7.2 Somatic stream

- Remove uniform phantom activation. Replace with `appr_identity_{entity_id}` activation driving somatic nudges based on the decoded-token profile — high-threat-decode entities nudge prickling; high-warmth-decode nudge warmth. This moves phantom activation from authored threat-memory lookup to emergent appraisal-decoded state.
- Object `quality_nudges` fire on compound-neuron activation (e.g., `q_touchable` firing on a hot hearth nudges `q_warm`), not on location entry.

### 7.3 Verb grammar — preserved substrate

Verbs and parameters stay substrate. The grammar gates verbs on what the being's sensory state makes meaningful:

- `TOUCH target`: requires `q_touchable` active on target
- `TAKE item`: requires `q_touchable` active on an inventoriable object
- `APPROACH target`: requires target visible AND `q_touchable` NOT firing (already close → no approach)
- `SAY … TO target`: requires `q_speechable` active on target (if emergent; otherwise fallback to visible)
- ...

This collapses draft 2's hand-authored layer-to-verb mapping. The mapping is now: verb ↔ compound neuron activation. Which distances produce compound activation is emergent. The gate fires when the emergent compound neuron says the verb is affordable.

Fallback for being's first hours (before any `q_*able` has emerged): use the distance sensory activation directly as a crude affordance signal — if `sense_dist_X > 50`, verbs assuming proximity are available; otherwise, verbs assuming distance are available. Decay: once `q_touchable` (or counterpart) is firing reliably, the crude fallback is overridden.

### 7.4 Trace logger

Schema version 2 (see §6.5). Old traces remain v1-readable; new traces carry full structure. Tooling checks version and routes appropriately.

### 7.5 Training (v3 fine-tune)

Training data is generated from Phase 0+ traces, which carry emergent content. The generator replays traces through the new prompt renderer (which uses decoded tokens) and has a large model produce assistant completions. The model trained on these will learn to consume decoded tokens — its verb competence does not depend on authored layer names because none exist in the training input.

Volume and verb coverage targets from draft 2 §15.2 still apply. Scenario sampling changes: scenarios specify situations (entity present at distance D with reward context R), the perception module runs a short simulated being through them to produce the decoded percept, and the generator fine-tunes on those.

## 8. The appraisal layer is no longer optional

Draft 2 treated appraisal as a future phase. Draft 3 makes it Phase 0. Consequence: the appraisal mechanism ships before anything else in this document. `server/appraisal_embeddings.py` and the embedding bridge exist before the first compound neuron spawns.

The quality-constellation appraisal spawn rule from `appraisal_layer_spec.md` remains. The extensions in §5 add:
- Encounter-based appraisal spawn (identity)
- Distance-action-based compound spawn (affordance — note this is a compound quality, not an appraisal; appraisal remains reserved for higher-order emergent categories)
- Sustained-firing compound spawn (temporal texture — also compound quality)

Appraisal is for *patterns of patterns*. Compound quality is for *patterns of primitives*. The distinction matters for capacity: MAX_APPRAISAL=12, MAX_COMPOUND is higher. Apprasial carries embedding; compound carries region+quality parents.

## 9. Acceptance criteria

Four tiers. All must pass for the spec to be considered working. Draft 2 had three tiers; draft 3 adds a fourth — **decay verification**.

### 9.1 Compliance (engineering hygiene)

1. `--embedding` flag is active on command server; `/embedding` returns vectors.
2. Token embedding matrix loaded at server start; cosine decode works on a test neuron.
3. `signal_reward()` is called on reward events; Hebbian graph reflects reward-gated strengthening after 10 minutes of play.
4. Trace schema version 2 records full sensory activations, active appraisals, decoded tokens, and reward events.
5. `data/perception_constants.json` is the source for any Tier 2 seed value read by both Python and GDScript.

### 9.2 Individuation (substrate richness)

6. After 30 minutes of varied-world play, a being has spawned at least:
   - 2 compound quality neurons with distinct receptive fields
   - 2 identity-appraisal neurons (distinct entities)
   - 1 cross-modal binding neuron (if exposed to bound modalities)
7. Two beings with different personas, same world, diverge by:
   - Identity-appraisal decoded-token overlap < 60% on shared entities
   - Sensory propagation-weight vector cosine distance > 0.2
   - Behavioral-probe verb-distribution KL > 0.4

### 9.3 Decay (pre-seeds wash out)

8. A being given randomized bootstrap seed concepts (§4.2) reaches behavioral distributions within 10% of a standard-seeded being after sufficient play. Measured by verb-distribution KL and identity-appraisal-decode distribution.
9. A being with a falsified persona prior (wrong trust for a specific entity) converges its identity-appraisal-decoded tokens toward the experiential truth after 30+ encounters with that entity. The seed prior has been "washed out."
10. Tier 2 seed values can be perturbed by ±20% without changing the being's steady-state behavior more than 5% (measured by verb distribution divergence at session end).

### 9.4 Emergence (behavioral divergence)

11. Same-scene probe test: two beings with different reward histories produce different top-1 verbs on ≥60% of probe scenes.
12. Temporal emergence: a being's behavior at t=0 (fresh session) and t=1 week (simulated) differs measurably; more importantly, t=1-week behavior is more differentiated from other beings' t=1-week behavior than t=0 was differentiated. Divergence grows.
13. Hebbian dynamic-neuron count at t=1 week exceeds protected-neuron count — more is learned than seeded.
14. Appraisal embeddings cluster: across beings, identity-appraisal embeddings for the same entity occupy distinct regions (silhouette score > 0.3 per entity).

## 10. Phased implementation

Each phase is independently shippable. Each produces a measurable acceptance signal. Phases are ordered by dependency.

### Phase 0 — the embedding bridge

Smallest shippable substrate unit. Must work before anything else.

- Enable `--embedding` on command server
- Extract `data/token_embeddings_layer0.safetensors` from base SmolLM3-3B
- Implement `server/embedding_source.py` (LlamaServerEmbeddingSource)
- Implement `server/appraisal_embeddings.py` (Manager)
- Wire cortical feedback in `server/thought_loop.py`
- Persist per-NPC appraisal state to `saves/{npc}/appraisals.json`

Acceptance: cortical feedback drifts appraisal embeddings measurably over 10 minutes; decoded tokens change over time; persistence survives restart.

Cost: ~1 week.

### Phase 1 — reward signal wiring

- Enumerate reward event types in code
- Wire engine-side emitters for each type (consume, give, rest, dialogue success, flee success, explore success)
- `hebbian_network.gd:signal_reward()` is called at each emission, with source tag and magnitude
- Reward-gated Hebbian update modifier active

Acceptance: reward-gating visibly affects Hebbian weight evolution (measured by weight-delta distributions pre- and post-reward events in the trace).

Cost: ~3-4 days.

### Phase 2 — per-entity sensory neurons via neurogenesis

- Encounter accumulator per NPC per entity_id
- Neurogenesis rule: first encounter spawns `sense_visible_{entity_id}` sense neuron
- Sense-neuron garbage-collected after `TRACKER_EXPIRY` ticks without firing
- Per-encounter sensory activation = exposure_value * 100

Acceptance: per-being, per-entity sensory channel exists; the Hebbian graph shows distinct sense-nodes for distinct entities.

Cost: ~1 week.

### Phase 3 — continuous distance sensory neurons and persistence channels

- Per visible entity, per visible object: `sense_dist_{id}` continuous activation
- Persistence/rate channels computed per tick for each sense-neuron

Acceptance: sense-neuron activation traces show continuous responsiveness to distance; rate/dwell channels track correctly.

Cost: ~3-4 days.

### Phase 4 — compound-neuron emergence from distance × action-success

- Action-success signals emit per verb
- Neurogenesis rule per §5.1
- Compound-quality spawn when pattern stabilizes

Acceptance: after 200 action-success events across 4+ verbs, at least 2 `q_*able` compound neurons exist per being. Their receptive fields differ across verbs.

Cost: ~1 week.

### Phase 5 — identity-appraisal emergence

- Encounter-thought association tracking
- Encounter-constellation appraisal spawn rule per §5.2
- Decoded tokens flow into prompt

Acceptance: per-being `appr_identity_{entity}` neurons spawn; decoded tokens differ across beings on shared entities.

Cost: ~1 week.

### Phase 6 — propagation-weight salience (no separate function)

- Ranking: outgoing sense-neuron propagation-weight used for top-K prompt selection
- Remove any residual hand-authored salience scaffolding from the prompt path

Acceptance: top-K ordering differs between beings with different reward histories on identical scenes (§9.2).

Cost: ~3-4 days.

### Phase 7 — prompt rendering with decoded tokens

- `render_prompt()` emits percepts with `name_render + direction_text + inline_tokens`
- No layer blocks; percepts merged into a flat ordered list by emergent salience
- Grammar gates verbs on active compound neurons (with crude fallback for early phases)

Acceptance: v1/v2 GGUFs produce invalid output on the new prompt (expected; they weren't trained on it).

Cost: ~3-4 days.

### Phase 8 — v3 training data and retrain

- Generator replays traces from Phases 0-6 into the new prompt format
- Large model produces assistant completions against the emergent prompts
- 5000+ examples, verb-coverage targets from draft 2 §15.2
- Retrain, export GGUF, deploy

Acceptance: v3 GGUF produces diverse verbs on the v3 prompt format; behavioral-probe diversity §9.4 passes.

Cost: ~2 weeks including generation, training, iteration.

### Phase 9 — cross-modal binding neurogenesis

- Per-modality per-entity sense-neurons (auditory + visual, per entity_id)
- Co-activation detector and binding-neuron spawn

Acceptance: beings exposed to bound modalities develop `bind_*` neurons; prompt reflects binding state via decoded tokens.

Cost: ~3-4 days.

### Phase 10 — temporal-texture neurogenesis

- Persistence/rate-compound spawn rules
- Decoded-token flow into prompt

Acceptance: temporal-pattern neurons spawn; prompt decodes "lingering", "approaching fast" tokens for appropriate situations.

Cost: ~3-4 days.

### Phase 11 — active perception via intention-attention coupling

- Intention embedding extraction
- Bootstrap uniform wire + Hebbian reshaping
- Intention-gated sensory propagation

Acceptance: same being with different active intentions produces different top-K rankings on same scene (§5.6).

Cost: ~1 week.

### Phase 12 — emergence measurement tooling

- Hebbian-graph diff tool (Frobenius distance, edge-wise deltas)
- Verb-distribution KL tool
- Appraisal-embedding silhouette tool
- Decay verification probe (randomize seeds, measure steady-state convergence)
- Behavioral-probe harness (synthetic scene library + test-verb-distribution)

Acceptance: all §9.3 and §9.4 metrics computable from trace and persisted state.

Cost: ~1 week.

### Running total

~10-12 weeks, assuming focused work and no architectural detours. Phases 0-2 deliver the substrate floor; Phases 3-7 deliver the first emergent content; Phase 8 ships a working v3 model; Phases 9-12 harden individuation surfaces and measurement.

## 11. Open questions

1. **Decay-rate calibration.** Drift rate 0.01, gravity 0.001 are defensible defaults. Too slow → long warmup before individuation is measurable. Too fast → cortical-feedback noise dominates. Tune after Phase 0 measurement.

2. **Token decode filter.** Should decode be restricted to a "meaningful token" subset (skip punctuation, short tokens, numbers)? Lean yes — produces cleaner prompts. The filter vocabulary is Tier 2 (authored starter, decaying by not-being-used). Decide during Phase 0 implementation.

3. **Reward magnitude calibration.** Drive satisfaction events vary in magnitude. Hunger-crossing should reward more than a trivial explore bonus. Authored magnitudes are Tier 2; the emergent rewards-over-time distribution is what matters. Tune in Phase 1.

4. **Verb-hint paragraph (from draft 2).** If verbs are gated by emergent compound neurons, does the prompt still need prose hints? Probably not — the model learns verb meaning from dataset examples that reflect the compound-neuron firing. Drop in Phase 8; A/B if evidence is mixed.

5. **T1 upgrade trigger.** Under what measured condition do we promote T0 → T1 (mid-layer embeddings)? Lean: if per-being individuation at T0 is statistically present but semantically coarse, and if decode tokens feel lexically-coincidental rather than semantically-grounded, upgrade. Measure after Phase 5.

6. **Pre-seed experiment vs production mode.** The user's note that pre-seeds are acceptable as experimental fast-forward implies two operating modes: "pure emergence" (minimal seeds, long simulated time) and "fast-forward" (richer seeds, immediate behavior). The spec supports both via the decay commitment. A `--fast-forward` flag could set richer seed values for short experiments; acceptance §9.3 still applies to validate that seeds wash out given real play.

7. **LLM context pressure.** As compound neurons accumulate, each percept may activate many appraisal neurons, each producing decoded tokens. The prompt could bloat. Top-K on decoded-token density per percept (keep only top 3 tokens per active appraisal) is a protocol choice. Decide during Phase 7.

8. **Save file schema evolution.** Appraisal embeddings persisted per being are hidden_dim × count. If hidden_dim changes (model upgrade) or topology changes (neurogenesis expansion), save files from older sessions become invalid. Need versioning + migration.

9. **Measurement time scale.** "After 1 week simulated time" is the emergence horizon. At current cadence (2s snapshot, 2-8s thought), 1 week = ~100k thought cycles. Real-time this is 25+ hours of continuous play. Harness should support accelerated simulation for measurement runs — tick-rate speedup without action execution lag.

10. **When does this stop being perception?** Several emergent mechanisms blur into cognition (identity, temporal patterns). At some point, the perception/cognition boundary becomes less useful than the stream architecture from `cognitive_model.md`. This spec owns sensory stream end-to-end; appraisal straddles sensory and executive. Future specs may reorganize.

## 12. Chesterton-fence audit — preserved from draft 2

These fences remain preserved. Rationale carried from draft 2 §20. Any modification must re-audit:

| Mechanism | File | Preserved because |
|---|---|---|
| `scene` field suppression from LLM | `command_model.py:59-61` | Smallville dataset leakage — prose place names poison Burg grounding |
| `relationships.trust` as authoritative dialogue scalar | `memory_system.gd:24,110-123,473-486` | Social propagation depends on single number; identity-appraisal extends, doesn't replace |
| Existing salience neuron for thought-loop urgency | `hebbian_network.gd:117` | Different function than perception salience; namespace rather than collide |
| FOV/hearing range | `SensorSystem` constants | Sensor-side body constraint |
| 8-cardinal direction decoder | `npc_controller.gd:610-629` | Works; continuous `direction_vec` extends without displacing |
| `available_items` fallback when emergent affordance is absent | new (§7.3) | Prevents cold-start paralysis before compound neurons emerge |
| Persona prior trust values | `data/personas/` | Allow scenario-specific starting conditions; decay guaranteed by §9.3 |

These are not changed by draft 3.

## 13. Deprecations — unchanged from draft 2 audit

- v1/v2 training data schemas (training artifacts only; no runtime dep)
- v2 GGUF (training artifact; not promoted)
- Lossy `visible_objects` trace serialization (bug)
- Silent `exposure` discard in snapshot (bug)

## 14. Key files

| File | Role | Phase |
|---|---|---|
| `server/embedding_source.py` | NEW — `EmbeddingSource` protocol + `LlamaServerEmbeddingSource` | 0 |
| `server/appraisal_embeddings.py` | NEW — `AppraisalEmbeddingManager` | 0 |
| `tools/extract_token_embeddings.py` | NEW — one-time token embedding matrix extraction | 0 |
| `data/token_embeddings_layer0.safetensors` | NEW — static decode matrix | 0 |
| `server/command_model.py` | add `--embedding --pooling mean` to launch args | 0 |
| `server/thought_loop.py` | cortical feedback loop integration | 0 |
| `saves/{npc}/appraisals.json` | per-being persisted state | 0 |
| `scripts/hebbian_network.gd` | wire `signal_reward()`; neurogenesis rule extensions | 1-5, 9, 10 |
| `scripts/layer1_substrate.gd` | continuous distance sensory neurons; per-entity sense-neurons | 2, 3 |
| `scripts/perception.gd` | extend with tracker; feed compound-neuron state into prompt render | 3+ |
| `server/perception.py` | NEW — prompt render from decoded tokens | 7 |
| `server/command_grammar.py` | emergent affordance gating (with fallback) | 7 |
| `server/trace_logger.py` | schema v2 | 0 (alongside bridge) |
| `scripts/somatic_stream.gd` | phantom activation from identity-appraisal, not memory | 5 |
| `training/cognitive/generate_command_training_v3.py` | replay emergent traces | 8 |
| `tools/compare_npcs.py` | NEW — cross-being divergence analysis | 12 |
| `data/perception_constants.json` | Tier-2 seed values | 0 |
| `docs/perception_spec.md` | THIS FILE | — |
| `docs/appraisal_layer_spec.md` | cross-reference updates (§5 extensions) | 0-5 |
| `docs/cognitive_model.md` | sensory-stream implementation reference | 7+ |

## 15. How to read this document

Section 2 (substrate) lists what cannot change. Section 4 (bootstrap) lists what starts as constants but must decay. Section 5 (emergent) lists what the being discovers; no content is prescribed, only the learning rule.

If you find yourself authoring a constant while implementing, verify its tier:
- If it's a physical property of the body or the learning rule, it's Tier 1 — defensible.
- If it's a starting value that experience must override, it's Tier 2 — it needs a decay path in §4 or §11.
- If it's a category name, a threshold for semantic meaning, a pre-defined feature, or a fixed weight — it belongs in Tier 3, and you've caught yourself making a shortcut. Move it to a learning rule.

The goal is a being whose inner life — perception, identity, body state, attention, action preference — is its own, not the designer's. Every authored shortcut reduces the being's inner life by that much.

---

*This spec is the contract. Anywhere code contradicts it, the code is wrong. Anywhere the spec is wrong, the spec gets revised here — not worked around in implementation. The test of the spec is not its internal elegance but the beings it produces: if two beings running this substrate for a simulated week are not measurably distinct, the spec is wrong.*
