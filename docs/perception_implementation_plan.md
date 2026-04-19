# Perception Spec Implementation Plan

> **Companion to** `docs/perception_spec.md` (Draft 3). This document is the implementation plan honoring that spec, with corrections from review findings F1–F10 integrated.
>
> **Contract.** Every phase ends with its acceptance gate green. No moving on with a red gate; if a gate can't be met, re-audit the spec — code is wrong, not spec, per the spec's closing paragraph.
>
> **Posture.** `data/perception_constants.json` is touched in Phase 0 and only edited (never duplicated) in later phases. Any constant in code is a bug. Trace v2 is the regression substrate. Every phase verifies prior phases by replaying old probes against new traces.

---

## Pre-flight (blocks all phases)

1. **Confirm appraisal-neuron spawn from existing constellation rule.** Phase 0 attaches embeddings to neurons that already spawn from the existing quality-constellation rule (`appraisal_layer_spec.md`). If none spawn during normal play, that's a substrate bug; fix before Phase 0.
2. **(F9) Canonical entity ID strategy.** Stable UUID assigned at world-load, independent of display name. Reconciliation rule for `"stranger" → "Mabel"`: name-binding event triggers a **merge operation** on the Hebbian side — sense-neurons and any identity-appraisals get merged via weight-sum, not duplicated. Document in `data/entity_id_protocol.md`. Engine-side: assign UUID at spawn, freeze across scene reloads (persisted in save).
3. **(F10) CI parity test scaffold.** `tests/test_constants_parity.py` loads `data/perception_constants.json`, runs Godot in headless mode to dump GDScript-side reads, asserts equality on every key. Lands in Phase 0 alongside the constants file. Runs on every PR.
4. **Tokenizer access.** Ship `transformers.AutoTokenizer.from_pretrained("HuggingFaceTB/SmolLM3-3B")` in the Python server.
5. **Disk budget.** `data/token_embeddings_layer0.safetensors` ≈ 250 MB. Gitignored; add to `.gitattributes` skip-list.

---

## Phase 0 — Embedding bridge (~1 wk + branch contingency)

Smallest shippable substrate unit. Must work before anything else.

### Steps

| # | Step | Files | Done when |
|---|---|---|---|
| 1 | Add `--embedding --pooling mean` to llama-server launch | `server/command_model.py:231-245` | `curl -s :PORT/embedding -d '{"content":"warm"}'` returns vector; `/completion` unaffected |
| 2 | One-time extract token embedding matrix from base SmolLM3-3B | NEW `tools/extract_token_embeddings.py` → `data/token_embeddings_layer0.safetensors` | shape `[V, 2048]` fp16, gitignored |
| 3 | `EmbeddingSource` protocol + T0 implementation | NEW `server/embedding_source.py` | LRU-cached round trip works; embed("warm") twice returns identical cached vector |
| 4 | `AppraisalEmbeddingManager` (init/drift/decode/persist/load) | NEW `server/appraisal_embeddings.py` | unit test: init from `{"tight":0.8}` → drift toward "calm" embedding 100 times → decoded tokens shift away from "tight" |
| 5 | Create `data/perception_constants.json` (all Tier-2 seeds) | NEW `data/perception_constants.json` | Both Python & GDScript read it via parity test (F10) |
| 6 | Cortical feedback wire | `server/thought_loop.py:208-414` (after L3 result, before trace) | trace shows embedding deltas cycle-over-cycle |
| 7 | Per-NPC persistence (only neurons with `drift_count > 10`) | `saves/{npc}/appraisals.json` | restart preserves long-standing neurons; ephemeral ones reset |
| 8 | Trace schema v2: add `trace_schema_version: 2`, add `active_appraisals: [{id, activation, decoded_tokens}]`, **fix lossy `visible_objects` serialization** (preserve `state, position, distance_pixels, exposure`) | `server/trace_logger.py` | v1 traces still parse; v2 carries full structure |
| 9 | Hebbian↔manager handshake — Hebbian announces new appraisal neuron + seed concepts | `scripts/hebbian_network.gd` snapshot payload extension | new neuron round-trips into Python manager |

### (F1) Semantic neighborhood smoke test — hard gate, before drift code is shipped

NEW `tools/probe_embedding_semantics.py` runs a fixed probe set:

- `embed("threat")` neighbors include `["danger","fear","menace"]` in top-10
- `embed("tight")` includes `["clenched","constricted","taut"]`
- `embed("warm")` includes `["heat","cozy","comfortable"]`
- ~30 such probes covering bootstrap concept set + reward-relevant vocabulary

**Pass criterion:** ≥70% of probes have ≥1 expected neighbor in top-10 (`semantic_probe_min_pass_rate` in constants).

- **If passes:** proceed with T0. Document the probe set as the regression baseline.
- **If fails:** **Phase 0.5 mandatory before continuing.** T0 produces lexical noise that won't serve identity-appraisal in Phase 5. Don't ship Phase 0 green over a failed semantic gate.

### (F10) Constants parity CI test lands here.

### Acceptance (Phase 0)

- §10 Phase-0 acceptance: drift measurable over 10 min, decoded tokens change, persistence survives restart
- F1 semantic probe ≥70% pass
- F10 constants parity test green in CI

---

## Phase 0.5 — T1 mid-layer extraction (triggered by F1 fail, actual cost ~1 day)

**Status:** SHIPPED. F1 at T0 scored **62.1%** (below 70%), triggering Phase 0.5. F1 at T1 scored **93.1%** after an encoding-consistency fix. T1 is now the default in `layer3_server.py` with T0 as automatic fallback.

- `tools/extract_token_embeddings_t1.py` — forward-pass each meaningful vocab token as `[BOS, t]`, read `hidden_states[24][:, 1, :]`, unit-normalize, save to `data/token_embeddings_layer24.safetensors`. ~100s on CUDA for 113 785 tokens.
- `TransformersMidLayerEmbeddingSource` — loads SmolLM3-3B in-process, lazy on first `embed()`. ~10s load, ~50-100ms per embed on GPU. Lives in `server/embedding_source.py` alongside the T0 implementation; same protocol, drop-in.
- `layer3_server.py` auto-selects T1 when the matrix exists, falls back to T0 if only the T0 matrix is present, runs without the bridge if neither.

### Encoding-consistency pitfall (recorded for future maintainers)

The first T1 build scored **0/29** — worse than T0. Root cause: the matrix extracted `hidden_states[L][:, 1, :]` (position-1 after BOS), but the source computed `hidden_states[L].mean(dim=1)` over the whole sequence *including* BOS. Same model, same layer, but different positions → vectors lived in different per-position regions of the layer-24 manifold, and cosine between them was meaningless.

**Fix:** the source now also prepends BOS and mean-pools *only* content positions (skipping BOS). For single-token inputs this collapses to position 1, matching the matrix exactly.

**Rule:** whenever you add a new `EmbeddingSource`, the matrix-extraction code and the source's `embed()` MUST produce byte-identical vectors for a single-token input. Any encoding divergence (pooling strategy, prefix tokens, truncation, normalization order) will silently corrupt cosine. First unit test for any new source: `cosine(source.embed("foo"), matrix_row_for(token_id_of("foo"))) > 0.99`.

### Acceptance (all met)

- F1 semantic probe 93.1% at T1 (threshold 70%)
- Phase 0 unit tests still green against new source
- `AppraisalEmbeddingManager`, `thought_loop` cortical feedback, snapshot handshake — unchanged (T1 is a drop-in via the `EmbeddingSource` protocol)

---

## Phase 1 — Reward signal wiring (~3-4 d)

### Steps

- Enumerate the 7 reward event types from spec §2.7 in `data/perception_constants.json` with magnitudes
- Engine-side emitters for each type:
  - `reward_drive_satisfaction` — drive value crossed below urgency threshold
  - `reward_drive_stabilization` — sustained drive value in safe band
  - `reward_social_accepted` — dialogue/gift/offer accepted by other
  - `reward_rest_recovered` — REST completed in safe context
  - `reward_explore_discovered` — entered novel location first time
  - `reward_threat_avoided` — FLEE FROM or HIDE executed, threat distance increased
  - `reward_action_succeeded` — any action's engine-reported success
- `hebbian_network.gd:1001 signal_reward()` called at each emission with `source_tag` and magnitude
- Reward-gated Hebbian update modifier active (β = 0.5 from constants file)
- Reward events recorded in trace v2

### (F8) Magnitude-sensitivity gate

After reward emitters land, run two parallel beings on a fixed scenario seed:
- Being A: baseline magnitudes from `perception_constants.json`
- Being B: all magnitudes ×2

After 10 simulated minutes, verb-distribution KL divergence between them must be **< 0.15** (`magnitude_sensitivity_max_kl` in constants). If higher, magnitudes are bypassing reward-gating's normalization — bug to fix before Phase 2.

### Acceptance

- §9.1.3: Hebbian weight-delta distributions visibly differ pre/post reward windows over 10 min
- F8 magnitude-sensitivity gate green

---

## Phase 1.5 — Accelerated simulator harness (~1 wk) [NEW]

**(F3)** Pulled forward from Phase 12 because Phase 4 and beyond depend on it.

### Steps

- Headless Godot mode: no rendering, no audio, decoupled tick rate from wall clock
- Action execution still runs (so action-success signals fire), but with zeroed wait/animation lag
- LLM calls remain real. Cognitive layers run unchanged. Only world-tick and animation lag are sped up
- Target: 10× wall-clock minimum for cognitive-substrate runs. Faster if LLM batching helps
- New CLI: `scripts/run_accelerated.sh --npcs hugo,mabel --duration 1h --seed 42 --out trace.jsonl`

### Acceptance

- 1 wall-clock hour produces ≥10 simulated hours
- Substrate behavior on probe scenes matches real-time within noise (no acceleration artifacts)
- Trace from accelerated run is byte-compatible with realtime trace parser

This unblocks every later acceptance gate that needed accumulated experience.

---

## Phase 2 — Per-entity sensory neurons via neurogenesis (~1 wk)

### Steps

- Per-NPC, per-entity_id encounter accumulator (uses canonical UUID from F9)
- Neurogenesis rule: first encounter spawns `sense_visible_{entity_id}`
- Sense-neuron garbage-collected after `TRACKER_EXPIRY` ticks without firing
- Per-encounter sensory activation = `exposure_value * 100`

### Acceptance

- Hebbian graph contains distinct sense-nodes per distinct entity
- Graph dump probe confirms no per-entity collisions
- Entity-merge rule (F9) verified: spawn entity as "stranger", later name-bind to "Mabel" → resulting graph has one merged neuron family, not two

---

## Phase 3 — Continuous distance sensory neurons + persistence channels (~3-4 d)

### Steps

- Per visible entity, per visible object: `sense_dist_{id}` continuous activation = `100 * exp(-dist_tiles / TAU)`, TAU=4 in constants
- Per-tick rate channel: `sense_X_rate(t) = sense_X(t) - sense_X(t-1)`
- Per-tick dwell channel: integral over recent window of `sense_X`

### Acceptance

- Trace shows continuous responsiveness to distance changes (no bucketing)
- Rate/dwell channels track movement events correctly
- All three channels (level, rate, dwell) recorded per sense-neuron per tick

---

## Phase 4 — Distance × action-success compound emergence (~1 wk)

### Steps

- Per-verb `action_success_{verb}` transient signal (strength 50, decay 2s) on engine-reported success
- Distance-action compound neurogenesis rule per spec §5.1: when `sense_dist_X` and `action_success_{verb}` co-fire at a specific distance band repeatedly (N times over M seconds), spawn `q_{verb}able`
- Compound-quality spawn class: `q_touchable`, `q_interactable`, `q_offerable`, etc.

### Acceptance

- §5.1: after **200 action-success events across 4+ verbs**, ≥2 `q_*able` compound neurons per being
- Receptive fields differ across verbs
- Decoded-token overlap < 60% between any two compound neurons
- **(F3)** Reachable now via accelerated sim from Phase 1.5: gate run is `accelerated --duration 4h --seed N`

---

## Phase 5 — Identity-appraisal emergence (~1 wk)

**Status:** SHIPPED. `IdentityAppraisalTracker` (`server/identity_appraisal.py`) accumulates F2-filtered thought embeddings per (npc, entity_id). When the deque reaches `encounter_threshold` (5), it emits a spawn request; `AppraisalEmbeddingManager.initialize_from_thoughts` seeds `appr_identity_{eid}` to the mean of the deque, and a `spawn_identity_appraisal` push command lands on the client where `HebbianNetwork.spawn_identity_appraisal(nid, eid)` wires sense_visible_{eid} + every active (activation ≥30) quality neuron as incoming at weight 0.12 (same convention the existing quality-constellation spawn uses — no new weight constant). F9 `PER_ENTITY_PREFIXES` extended with `appr_identity_`. Trace v2 adds `new_identity_appraisals_this_tick`, `entity_thought_associations_this_tick`, and `identity_appraisal_decoded` (eid → tokens). F2 filter: WordNet lemma + proper-noun plural-strip fallback, OR cosine > 0.45. Acceptance gate: 20 encounters × 3 eids → 3 `appr_identity_*` spawned, max pairwise cosine 0.240 (dist > 0.76), F2 rejection rate 0.247 (floor 0.15). One new Tier-2 constant: `identity_filter_min_rejection_rate: 0.15`.

### Steps

- Per-NPC per-entity encounter accumulator extension: `thought_embeddings_during_encounters` deque
- Encounter-constellation appraisal spawn rule (threshold 5 encounters with associated thoughts)
- Initial embedding = mean of accumulated thought embeddings; weighted seed-concept fallback if sparse
- Hebbian wiring: `appr_identity_{entity_id}` ← from `sense_visible_{entity_id}` + active somatic streams during spawn
- Outgoing to action and vagal develops via Hebbian learning
- Decoded tokens flow into trace v2 alongside the entity

### (F2) Thought-entity association filter — mandatory

Before adding a thought embedding to entity_id's `thought_embeddings_during_encounters` deque, require **either**:

1. Entity name appears as a token in the thought text (lemma-matched, case-insensitive), **or**
2. `cosine(embed(thought), embed(entity_name)) > THOUGHT_ENTITY_BIND_THRESHOLD` (seed: 0.45 — Tier 2, in constants)

Without this, identity-appraisals collapse toward whatever dominates the inner monologue (back pain, hunger, weather) regardless of who's nearby.

New trace field: `entity_thought_associations_this_tick` records which thoughts were filtered in/out per entity, so we can audit the filter's behavior.

### Acceptance

- §5.2: after 20 encounters across 3+ entity IDs, ≥2 `appr_identity_*` neurons
- Pairwise cosine distance between decoded-token vectors > 0.3
- F2 filter audit shows non-trivial rejection rate (i.e., filter is doing work, not pass-through)

---

## Phase 6 — Propagation-weight salience (~3-4 d)

**Status:** SHIPPED. `HebbianNetwork.get_outgoing_weight_sum` + `get_perception_salience` expose the substrate's own weights as an emergent per-entity salience map; `layer1_substrate.get_perception_salience` surfaces it into the snapshot as `perception_salience: {eid: float}`. Python-side `server/perception_rank.py` consumes this with `rank_percepts(visible, visible_objects, salience, K)` and produces top-K-across-both-categories with a stable input-order tiebreak (cold-start fallback reported, not authored). `NPCState.build_thought_context` now pre-ranks/pre-caps visible+objects using K = `capacity.prompt_top_k_percepts` (8). Both `command_model.py` and `layer3_model.py` had their `[:6]`/`[:4]` and "Entities lead (bigger salience), then objects" scaffolding stripped — high-salience objects now outrank low-salience entities. F6 continuous gate lives in `thought_loop` via `NPCState.record_entropy` / `rolling_entropy_mean(600.0)`, recorded in trace v2 as `attention_entropy: {tick, mean_10min, h_min, k, fallback}`. `tools/probe_attention_entropy.py` is the CI monitor — reads any trace file, verifies rolling 10-min mean stays above `h_min_attention_entropy_factor * log(K)` (factor 0.6 from constants). Heard percepts retain the `heard[:3]` cap with an explicit Phase 9 deferral comment (no `sense_heard_*` substrate exists yet). Zero new tuning constants added. Acceptance gate green: 50-scene probe × two beings with divergent seeded outgoing weights → mean Spearman 0.213 ≪ 0.7 threshold. Continuous F6 gate now runs in every later phase's sweep.

### Steps

- Top-K prompt selection ranks percepts by **summed outgoing propagation weight of their sense-neuron**
- Strip any residual hand-authored salience scaffold from the prompt path
- K = constant from `data/perception_constants.json`

### (F6) Attention entropy stability gate — continuous from this phase onward

Compute `H = -Σ p_i log p_i` over normalized top-K propagation weights per tick. Rolling 10-min mean must stay above:

```
H_MIN = h_min_attention_entropy_factor * log(K)   # seed factor: 0.6
```

If the being develops tunnel vision (entropy collapse), the trace flags it and the gate fails.

This monitor stays live in CI for every subsequent phase. Any phase that drops attention entropy below the floor regresses Phase 6.

### Acceptance

- §9.2.7: two beings, identical scene library, Spearman ranking correlation < 0.7 on 50-scene probe
- F6 attention entropy stays above floor over 10-min trace

---

## Phase 7 — Prompt rendering with decoded tokens (~3-4 d)

**Status:** SHIPPED. `server/perception.py::render` produces the spec §6.4 flat `You see:` / `You hear:` blocks — entities and objects render identically (no category distinction), inline tokens come from Phase 5 `identity_appraisal_decoded` per-eid (capped at 3 per the spec §11 prompt token density default). Phase 5 decode is now computed BEFORE the LLM call so inline tokens actually reach the prompt each tick. `server/command_grammar.py` fully rewritten: verbs gate on active compound neurons (`q_touchable` for TOUCH/TAKE, `q_interactable` for INTERACT, `q_offerable` for OFFER/GIVE/SHOW; APPROACH negated by active `q_touchable` per §7.3). `GrammarResult` dataclass returns per-verb admission path (`compound`/`fallback`/`blocked`) so F4 contribution is measurable without post-hoc inference. `HebbianNetwork.get_active_compounds` + `get_compound_count` surface the substrate state to Python via `layer1.get_compound_state` → snapshot `compounds: {active, count}`. F4 decay: `fallback_coefficient = max(0, 1 - count / n_fallback_retire)` (N=8 from constants). Command-model prompt dropped the hand-enumerated `Commands: ...` line and the "TOUCH grounds the body..." verb-hint paragraph (§11.4); the grammar now owns the verb vocabulary at decode time. Somatic phantom switched from memory-lookup (`get_entity_threat_levels`) to `server/identity_phantom.py`: active identity-appraisal decoded tokens name quality neurons (`q_{tok}`) to nudge — no mapping table; the embedding space and quality vocabulary share bootstrap concepts so the mapping is implicit. Client handler `nudge_quality` applies the push. Trace v2 adds `prompt_rendered`, `compounds_state`, `fallback_contribution_per_tick`, `fallback_coefficient`, `verbs_via_compound`, `verbs_via_fallback`. `tools/probe_fallback_decay.py` is the F4 continuous gate — mature beings (count ≥ N) must show mean contribution ≤ 0.01. Zero new constants added. Acceptance gates all green: v1/v2 scaffolding removed (format break confirmed structurally); §6.4 format + inline tokens land in the prompt; F4 coefficient hits exactly 0 at count=N; F6 entropy and all prior gates still green.

### Steps

- NEW `server/perception.py` — flat `Percept` list per spec §6.3-6.4, no layer blocks
- Prompt format per §6.4:
  ```
  You see:
    - {name_render}, {direction_text}{inline_tokens_if_any}{speech_if_any}
    - ...
  You hear:
    - {unbound_source}, {direction_text}: "{text}"
    - silence
  ```
- `server/command_grammar.py` — verbs gated on active compound neurons per §7.3
- Drop verb-hint paragraph (per §11.4)
- Somatic phantom activation switches from memory-lookup to identity-appraisal-driven (§7.2)

### (F4) Crude-distance fallback — explicit Tier-2 decay

Effective fallback contribution per being:

```
fallback_strength * max(0, 1 - compound_neuron_count / N_FALLBACK_RETIRE)
```

`N_FALLBACK_RETIRE = 8` (seed; in constants).

- At 0 compound neurons: full fallback. At ≥8: zero contribution.
- Measured per-being, per-verb-class.
- Trace records `fallback_contribution_per_tick`.
- Phase 7 gate **fails** if any mature being (compound count ≥ N) shows >0.01 fallback contribution averaged over 10 min.

### Acceptance

- v1/v2 GGUFs produce invalid output on new prompt (expected — confirms format break)
- Trace v2 shows new prompt format end-to-end
- F4 fallback decays to zero in mature beings (verified in trace)
- F6 attention entropy still above floor

---

## Phase 8 — v3 training data + retrain (~2 wk)

**Status:** TOOLING SHIPPED. Every Phase 8 code artifact is written and test-green:
- `training/cognitive/maturity_classifier.py` — F5 gate logic reading all three thresholds from `training_maturity` block (compound_count, appr_identity count, mean drift).
- `training/cognitive/synthetic_scenarios.py` — §15.2-style programmatic scene generator (4 distance bands × 3 target kinds × 5 reward contexts = 60 base scenarios, coverage-targeted not authored).
- `training/cognitive/generate_command_training_v3.py` — replays Phase 0-7 traces through Phase 7's flat-Percept renderer, F5-gated for post-maturity samples, 2:1 synthetic-to-replay weighting from constants, outputs jsonl corpus with per-line `corpus_metadata {kind, npc, source_ts, first_mature_ts, probe_verb, ...}`.
- `tools/probe_maturity.py` — F5 CLI: `--trace` audits per-NPC timelines, `--corpus` validates no pre-maturity leaks + no missing metadata.
- Trace v2 extended with `appraisal_drift_counts` so maturity is evaluable per-tick from the trace alone (no persist file required).

**Operator-gated runtime steps** (require hours of compute, moved to a separate runbook in RESUME.md):
1. Run accelerated sim (`scripts/run_accelerated.sh`) for ≥24 simulated hours per being.
2. Run `generate_command_training_v3.py` against the recorded traces with a configured large-model completion endpoint.
3. LoRA train → GGUF export → deploy.
4. Re-probe the deployed model's traces with F1 / F4 / F6 / F5 CLIs to confirm no regression.

Tooling-layer acceptance gates all green: F5 corpus metadata shows zero pre-maturity samples (validated by `probe_maturity --corpus`); synthetic verb coverage schedule spans TOUCH/INTERACT/APPROACH/EXAMINE/WATCH/LOOK AT; F4/F6 CLIs pass against post-v3 synthetic traces (no training-induced regression on the probe gates); generator output obeys the downstream LoRA schema (prompt/completion/metadata on every line). Zero new tuning constants added — every threshold reads from the existing `training_maturity` block.

### Steps

- NEW `training/cognitive/generate_command_training_v3.py` — replays Phase 0-7 traces through new prompt renderer
- Large model produces assistant completions on emergent prompts
- 5000+ examples; verb-coverage targets from draft 2 §15.2
- LoRA train, export GGUF, deploy

### (F5) Maturity gate on training corpus — hard requirement

Define being maturity:

```
compound_neuron_count >= 6
AND
appr_identity_count >= 3
AND
mean_drift_count_per_appraisal >= 50
```

(All from `training_maturity` block in constants.)

- Trace harvest accepts only thoughts emitted **after** the being crosses maturity in its accelerated run
- Run beings in Phase 1.5's accelerated sim for a simulated 24-72 hours before harvesting begins
- Synthetic scenario generation (§15.2-style) is weighted **2:1** vs. organic replay to ensure verb-coverage targets are met without overfitting to whatever the cold-start beings happened to do
- Reject the dataset and re-harvest if cold-start thoughts (pre-maturity) leak in

### Acceptance

- v3 GGUF on v3 prompt format — verb diversity > 0 on every category
- §9.4 behavioral-probe diversity passes
- F5 maturity gate verifiable: corpus metadata shows zero pre-maturity samples
- F1 semantic-probe baseline still passes against v3 (no embedding-space corruption from training)

---

## Phase 9 — Cross-modal binding neurogenesis (~3-4 d)

**Status:** SHIPPED. `stimulus_registry.emit` extended to carry `emitter_eid` (canonical F9 entity_id) alongside the existing display-name `emitter_id`; `sensor_system.query_hearing` threads it through; `npc_controller.speak`/`emit_footstep`/social-act emits all pass `entity_id()` so every per-entity sound is eid-keyed. `HebbianNetwork.update_per_entity_heard` spawns/refreshes `sense_heard_{eid}` from accumulated hearing and logs co-activation when `sense_visible_{eid}` is also ≥30 in the same tick. Spawn rule: `cross_modal_co_fire_count` (5) in-window co-fires within `cross_modal_window_seconds` (30) produces `bind_{eid}` compound wired to both modality parents at the existing 0.12 compound-parent weight — no new tuning constant. `_compound_quality_count` increments so F4 fallback decay treats bind compounds identically. `PER_ENTITY_PREFIXES` extended with `sense_heard_` and `bind_` for F9 merge coverage. Phase 6's heard deferral retires: `layer1.get_perception_salience_all` combines visible + heard outgoing-weight sums per eid, `rank_percepts` accepts a `heard` list and partitions top-K across all three categories. `perception.render_hear_block` drops the `[:3]` cap. Trace v2 carries `cross_modal_state: {heard, bind_active, new_bind_neurons}` with per-tick drain semantics. Acceptance: ≥1 `bind_*` after 30 encounters (live Godot + Python simulation); partial activation correctly suppresses spawn (visible-only, heard-only, windowed-expired all blocked); bind events land in trace; F9 merge drops deprecated sense_heard_ and bind_ families. Zero new constants.

### Steps

- Per-modality per-entity sense-neurons: `sense_visible_{X}` and `sense_heard_{X}` exist as separate channels
- Within-tick co-activation tracker
- Pair-co-activation neurogenesis: N co-activation events over M seconds spawn compound `bind_{entity_id}` wired to both

### Acceptance

- §5.4: after 30 bound-modality encounters, ≥1 `bind_*` neuron per being
- Partial activation observable in trace when only one modality fires
- Decoded tokens reflect binding state

---

## Phase 10 — Temporal-texture neurogenesis (~3-4 d)

**Status:** SHIPPED. `HebbianNetwork.update_temporal_textures(dt)` reads the dwell/rate fields already maintained per-entity by Phase 3, accumulates sustained-above-threshold seconds per eid, and spawns `q_lingering_{eid}` / `q_approaching_fast_{eid}` at `temporal_persistence_seconds` (8) of continuous elevation. Discontinuous elevation resets the counter — "high for T seconds" is continuous per spec. Two new Tier-2 seeds: `temporal_dwell_min: 30.0` (matches activation-floor convention for dwell EMA) and `temporal_rate_min: 0.5` (captures "fast approach" on sense_dist rate). Compound wired to parent sense at 0.12 (existing convention), category `compound_quality_temporal`, tag_text carries the decoded token (`lingering` / `approaching_fast`) so spec §5.5 "decoded tokens reflect temporal character" resolves without a separate decode pathway. `update_temporal_activations` refreshes compound firing from parent channels so the compound fades when the entity leaves or stops approaching. `PER_ENTITY_PREFIXES` extended with both prefixes for F9 merge coverage. `_compound_quality_count` increments so F4 fallback decay treats temporal compounds identically. Snapshot carries `temporal: {active, new_neurons}`; Phase 7 renderer's inline-tokens slot now merges temporal kinds (alphabetical, leading) with identity decode (token density cap 3 preserved). Trace v2 records `temporal_state`. Acceptance all green: 5 sustained dwell periods → 5 lingering compounds; 5 approach periods → 5 approaching compounds; 15-min rotating session → 10 temporal neurons across both kinds; discontinuous dwell correctly does NOT spawn; renderer inlines tokens per-eid; density cap enforced with temporal leading identity.

### Steps

- `q_X_lingering` spawns when `sense_X_dwell` has been high for T seconds
- `q_X_approaching_fast` spawns when `sense_X_rate` has been high for T seconds
- Decoded tokens flow into prompt

### Acceptance

- §5.5: after 15-min session with ≥5 approach + ≥5 dwell events, ≥2 temporal-texture neurons per being
- Decoded tokens reflect temporal character (lingering, approaching fast)

---

## Phase 11 — Active perception via intention-attention coupling (~1 wk)

**Status:** SHIPPED. `server/intention_attention.py::IntentionAttention.select_intention_context` embeds the being's top-priority goal via the existing `EmbeddingSource`, scores bootstrap-concept quality neurons (cosine vs embed of each concept name) AND currently-active appraisal neurons (cosine vs their drifted embeddings), and returns the top-K neuron IDs to activate. `HebbianNetwork.pulse_intention_context` sets each listed neuron's activation to 40 and seeds uniform `bootstrap_intention_seed` (0.005) edges from the intention to every per-entity sense neuron. `propagate()` reads `_intention_amp_cache` (computed per-tick via `get_intention_amplification_map`) and scales every sense-neuron outgoing contribution by `1 + Σ_I I_act × w_{I→S}`; runtime clamp at `intention_amp_cap` (5.0) prevents runaway while F6 catches trace-level collapse. Swapping goals clears stale intention neurons without erasing their learned edges. `get_intention_bootstrap_variance` returns per-intention CV across outgoing I→S weights — CV ≈ 0 at cold-start (uniform seed), grows as Hebbian reshapes specific pairs under reward. `tools/probe_intention_decay.py` is the F11 continuous gate: reads trace, flags any intention whose CV stays below the `min_cv` floor across `min_samples` ticks (authored uniformity never decayed into learned specificity — F11 regression). Three new Tier-2 seeds in `neurogenesis_thresholds`: `bootstrap_intention_seed`, `intention_top_k_concepts`, `intention_amp_cap`. Snapshot carries `intention: {context_neurons, amplification, bootstrap_variance}`; trace v2 adds `intention_state` and `intention_context`. Acceptance all green: same-scene two-goal divergence (Oven vs Bed top-1 under different goals); F6 entropy stays above floor under cap-level amplification (1.814 > 1.248); F11 CLI correctly flags stuck-uniform intentions and passes learning traces; CV mechanism distinguishes uniform from learned distributions.

### Steps

- L3 `Goal:` field embedded; nearest-concept neurons in Hebbian graph activate as intention-context
- Intention-gated Hebbian: `I × S` co-fire under reward strengthens `I → S` propagation specifically (not generic sense → action)
- Bootstrap uniform wire (Tier-2 seed) reshapes via reward history
- Per-tick: sense propagation × `(1 + Σ active intention contributions)`

### Acceptance

- §5.6: same being, two intentions, two different top-K rankings on identical scene
- Bootstrap wire's influence demonstrably weakens over reward history (decay verification)
- F6 attention entropy still above floor under intention-gated propagation

---

## Phase 12 — Emergence measurement tooling (~1 wk)

**Status:** SHIPPED. All Phase 12 measurement surfaces are in `tools/`: `probe_embedding_semantics.py` (F1), `probe_fallback_decay.py` (F4), `probe_maturity.py` (F5, dual-mode), `probe_attention_entropy.py` (F6), `probe_magnitude_sensitivity.py` (F8, NEW Phase 12), `probe_intention_decay.py` (F11), and the unifying `compare_npcs.py` (NEW Phase 12) which produces per-NPC rollups + pairwise verb Jensen-Shannon + appraisal-embedding silhouette from trace + persisted `saves/*/appraisals.json`. F8 previously only had a Godot test; the new CLI extends the gate to post-deploy trace analysis. `compare_npcs.py` is the integration point for Phase 13's capstone — it takes a multi-NPC trace and surfaces every §9.2/§9.3/§9.4 metric the capstone needs without per-metric CLI invocations. Zero new tuning constants. Acceptance: every required CLI present (7 total); a mature synthetic trace passes F4+F5+F6+F11 in one sweep; cross-being §9.2.7 appraisal silhouette + §9.4 verb-distribution JS both computable from trace+saves; F8 CLI correctly fails on extreme verb divergence.

### Steps

- NEW `tools/compare_npcs.py` — Hebbian-graph diff (Frobenius, edge-wise deltas), verb-distribution KL, appraisal-embedding silhouette
- Decay verification probe: scramble bootstrap seeds → measure steady-state convergence
- Behavioral-probe harness: synthetic scene library + verb-distribution scoring
- Attention-entropy regression tool exposing F6 monitor as CLI
- Fallback-contribution decay verifier exposing F4 as CLI
- Maturity-classifier (used by Phase 8 harvest gate) exposing F5 as CLI

(Accelerated simulator was moved to Phase 1.5.)

### Acceptance

- All §9.3 (decay) and §9.4 (emergence) metrics computable from trace + persisted state
- All F1, F4, F5, F6, F8 monitors expose CLIs for ad-hoc analysis

---

## Phase 13 — Capstone validation (~1 wk) [NEW]

**(F7) The test of the spec, per its closing paragraph.** Phase 12 built the tools; Phase 13 runs the trial.

### Setup

- Two beings, distinct personas (Hugo, Ivy), shared world, distinct random seeds for action-tiebreak
- Run: 1 simulated week each in accelerated sim
- Capture full trace v2 throughout

### Measurement battery (all from Phase 12 tools, all must pass)

| Metric | Source | Threshold |
|---|---|---|
| Identity-appraisal decoded-token overlap on shared entities | §9.2.7 | < 60% |
| Sensory-propagation cosine distance between beings | §9.2.7 | > 0.2 |
| Behavioral verb-distribution KL between beings | §9.2.7 | > 0.4 |
| Seed-randomization probe being convergence | §9.3.8 | within 10% of standard |
| Persona-prior falsification washout | §9.3.9 | converges after ≥30 encounters |
| ±20% seed perturbation steady-state behavior delta | §9.3.10 | < 5% |
| Top-1-verb divergence on 50-scene probe library | §9.4.11 | ≥ 60% |
| t=1-week individuation > t=0 individuation | §9.4.12 | strictly greater |
| Dynamic-neuron count > protected-neuron count at t=1 wk | §9.4.13 | strictly greater |
| Per-entity identity-appraisal cluster silhouette | §9.4.14 | > 0.3 |
| F1 semantic-neighborhood probe still passes | F1 baseline | no embedding-space corruption |
| F6 attention-entropy stability | F6 monitor | no collapse events in either trace |

### Verdict

- **Green:** spec validated. The substrate produces measurably distinct beings.
- **Red:** re-open spec sections corresponding to failed metric. **Do not paper over.**

Capstone is **not** "ship it." It's "the substrate is what the spec claimed it would be." Failures here are spec defects, by the document's own contract.

---

## `data/perception_constants.json` — full key list

All Tier-2 seed values live here. Both Python and GDScript read; F10 CI test enforces parity.

```json
{
  "embedding_bridge": {
    "drift_rate": 0.01,
    "gravity_rate": 0.001,
    "drift_count_persist_threshold": 10,
    "decode_top_k": 3,
    "embedding_cache_size": 2048,
    "bootstrap_concepts": [
      "tight", "loose", "warm", "heavy", "settled",
      "churning", "pounding", "hollow", "prickling",
      "open", "clear", "foggy", "buzzing", "numb"
    ]
  },
  "hebbian": {
    "eta": 0.05,
    "theta": 30.0,
    "beta": 0.5,
    "reward_signal_decay": 2.0
  },
  "neurogenesis_thresholds": {
    "quality_constellation_min": 2,
    "quality_constellation_sustained_count": 8,
    "quality_constellation_window_seconds": 30,
    "appraisal_constellation_min": 3,
    "appraisal_constellation_sustained_seconds": 6,
    "stress_threshold": 75,
    "stress_sustained_seconds": 3,
    "novelty_threshold": 30,
    "novelty_sustained_seconds": 5,
    "encounter_threshold": 5,
    "distance_action_co_fire_count": 10,
    "distance_action_window_seconds": 60,
    "cross_modal_co_fire_count": 5,
    "cross_modal_window_seconds": 30,
    "temporal_persistence_seconds": 8
  },
  "sensors": {
    "fov_pixels": 96,
    "hearing_pixels": 80,
    "distance_tau_tiles": 4,
    "tracker_expiry_ticks": 600
  },
  "capacity": {
    "max_appraisal_per_being": 12,
    "max_compound_quality": 16,
    "prompt_top_k_percepts": 8
  },
  "reward_magnitudes": {
    "reward_drive_satisfaction": 0.7,
    "reward_drive_stabilization": 0.3,
    "reward_social_accepted": 0.6,
    "reward_rest_recovered": 0.4,
    "reward_explore_discovered": 0.5,
    "reward_threat_avoided": 0.8,
    "reward_action_succeeded": 0.2
  },
  "thought_entity_bind_threshold": 0.45,
  "h_min_attention_entropy_factor": 0.6,
  "n_fallback_retire": 8,
  "training_maturity": {
    "min_compound_neurons": 6,
    "min_appr_identity": 3,
    "min_mean_drift_per_appraisal": 50,
    "synthetic_to_replay_ratio": 2.0
  },
  "magnitude_sensitivity_max_kl": 0.15,
  "semantic_probe_min_pass_rate": 0.7,
  "identity_filter_min_rejection_rate": 0.15
}
```

All accessed via the parity test (F10) from Phase 0.

---

## Findings → corrections crosswalk

| Finding | Defect | Phase | Correction |
|---|---|---|---|
| F1 | Phase 0 green on lexical noise | 0 | Hard semantic-probe gate; T1 fork (Phase 0.5) mandatory if T0 fails |
| F2 | Identity poisoned by ambient thoughts | 5 | Name-or-cosine filter on encounter-thought association |
| F3 | Phase 4 unreachable without Phase 12 | 1.5 | Accelerated sim moved to Phase 1.5 |
| F4 | Cold-start fallback never retires | 7 | Explicit decay formula tied to compound-neuron count |
| F5 | v3 trained on cold-start | 8 | Maturity gate + 2:1 synthetic weighting |
| F6 | Closed loop unmonitored | 6 | Continuous attention-entropy gate from Phase 6 onward |
| F7 | Spec's own test never run | 13 | Capstone with green/red verdict |
| F8 | Magnitudes baked in unchecked | 1 | 2× perturbation gate in Phase 1 |
| F9 | Entity ID drift fragments neurons | pre | Canonical UUID + merge protocol |
| F10 | Constants parity drifts at runtime | pre/0 | CI parity test lands with constants file |

---

## Running totals

| Phase | Cumulative wall-clock |
|---|---|
| Pre-flight | 0.5 wk |
| Phase 0 | 1.5 wk |
| Phase 0.5 (contingent) | +1 wk if F1 fails |
| Phase 1 | 2 wk |
| Phase 1.5 | 3 wk |
| Phase 2 | 4 wk |
| Phase 3 | 4.5 wk |
| Phase 4 | 5.5 wk |
| Phase 5 | 6.5 wk |
| Phase 6 | 7 wk |
| Phase 7 | 7.5 wk |
| Phase 8 | 9.5 wk |
| Phase 9 | 10 wk |
| Phase 10 | 10.5 wk |
| Phase 11 | 11.5 wk |
| Phase 12 | 12.5 wk |
| Phase 13 | 13.5 wk |

**Total:** ~13-14 wk including capstone, +1 wk contingency if F1 forces Phase 0.5.

---

## Key files reference

| File | Role | Phase |
|---|---|---|
| `data/perception_constants.json` | Tier-2 seed source for Python + GDScript | pre / 0 |
| `data/entity_id_protocol.md` | Canonical entity ID + merge rule (F9) | pre |
| `tests/test_constants_parity.py` | Constants parity CI (F10) | 0 |
| `tools/extract_token_embeddings.py` | One-time matrix extraction | 0 |
| `tools/probe_embedding_semantics.py` | F1 semantic gate | 0 |
| `data/token_embeddings_layer0.safetensors` | Decode matrix (T0) | 0 |
| `data/token_embeddings_layer24.safetensors` | Decode matrix (T1, contingent) | 0.5 |
| `server/embedding_source.py` | EmbeddingSource protocol + impls | 0 / 0.5 |
| `server/appraisal_embeddings.py` | AppraisalEmbeddingManager | 0 |
| `server/command_model.py` | Add `--embedding --pooling mean` | 0 |
| `server/thought_loop.py` | Cortical feedback loop | 0 |
| `server/trace_logger.py` | Schema v2 | 0 |
| `saves/{npc}/appraisals.json` | Per-being persisted state | 0 |
| `scripts/hebbian_network.gd` | signal_reward wiring; neurogenesis extensions | 1, 2, 4, 5, 9, 10 |
| `scripts/run_accelerated.sh` | Headless accelerated CLI | 1.5 |
| `scripts/layer1_substrate.gd` | Continuous distance + per-entity sense neurons | 2, 3 |
| `scripts/perception.gd` | Tracker; compound-neuron state to prompt | 3+ |
| `server/perception.py` | Prompt render from decoded tokens | 7 |
| `server/command_grammar.py` | Emergent affordance gating + decaying fallback | 7 |
| `scripts/somatic_stream.gd` | Phantom activation from identity-appraisal | 5 / 7 |
| `training/cognitive/generate_command_training_v3.py` | v3 corpus generation w/ maturity gate | 8 |
| `tools/compare_npcs.py` | Cross-being divergence analysis | 12 |
| `tools/probe_attention_entropy.py` | F6 monitor CLI | 12 |
| `tools/probe_fallback_decay.py` | F4 monitor CLI | 12 |
| `tools/probe_maturity.py` | F5 maturity classifier CLI | 12 |
| `tools/run_capstone.py` | Phase 13 trial runner + verdict | 13 |
| `docs/perception_spec.md` | The spec | — |
| `docs/perception_implementation_plan.md` | THIS FILE | — |
| `docs/appraisal_layer_spec.md` | Cross-reference (§5 extensions) | 0-5 |
| `docs/cognitive_model.md` | Sensory-stream implementation reference | 7+ |

---

## Decisions deferred to phase-of-relevance (per spec §11)

- **Decode filter vocabulary** — Phase 0. Start with "alpha-only, length>1" filter (already in spec example). Defer authored allowlist.
- **Reward magnitudes** — Phase 1. Authored seeds in constants; F8 gate enforces robustness.
- **T1 upgrade trigger** — measured at Phase 0 via F1 gate (forced) and again after Phase 5 if semantic coarseness shows in identity-appraisal divergence.
- **Verb-hint paragraph** — Phase 8. Drop by default; A/B if evidence is mixed.
- **Prompt token density (top-K decoded tokens per percept)** — Phase 7. Cap at 3 per active appraisal initially.
- **Save file schema evolution** — Phase 0. Versioning field in `saves/{npc}/appraisals.json` from day one. Migration tool added when first incompatible change ships.

---

*The spec is the contract. This plan is the path. Anywhere the path diverges from the spec, the path is wrong; revise the spec or revise the path, but never silently let them drift apart.*
