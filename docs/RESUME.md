# Resume Prompt — Perception Spec Implementation

Paste this into a fresh Claude Code conversation to pick up where we left off.

---

I'm implementing the perception substrate per `docs/perception_spec.md` (Draft 3) following `docs/perception_implementation_plan.md`. **Phases 0-7 + 9-12 shipped; Phase 8 tooling shipped (runtime training/deploy operator-gated). Next up is Phase 13 capstone.**

## Status — completed

| Phase | What landed | Key files |
|---|---|---|
| Pre-flight | `data/perception_constants.json` (Tier-2 seeds, 19 top-level keys), `data/entity_id_protocol.md` (F9), `tests/test_constants_parity.py` (CI parity Python ≡ Godot), `scripts/perception_constants.gd` autoload | constants drive everything; never hardcode |
| 0 | Embedding bridge — `--embedding --pooling mean` on llama-server, `server/embedding_source.py` (T0 LlamaServerEmbeddingSource), `server/appraisal_embeddings.py` (init/drift/decode/persist/load/merge), `tools/extract_token_embeddings.py`, cortical feedback wired in `server/thought_loop.py`, snapshot handshake, per-NPC persistence at `saves/{npc}/appraisals.json`, trace v2 (`active_appraisals`, `new_appraisals_this_tick`, lossy `visible_objects` fixed) | F1 hard gate failed at T0 → forced Phase 0.5 |
| 0.0 (NEW) | Appraisal-spawn was spec'd but **not implemented**; added `_check_appraisal_neurogenesis` + `_spawn_appraisal_neuron` per `appraisal_layer_spec.md §5` | `scripts/hebbian_network.gd` |
| 0.5 | T1 mid-layer extraction (layer 24 residuals via transformers, `tools/extract_token_embeddings_t1.py`), `TransformersMidLayerEmbeddingSource`. F1 gate passes 27/29 (93.1%) at T1 vs 18/29 (62.1%) at T0. **Encoding-consistency rule recorded in plan** — matrix and source must produce byte-identical vectors for single-token input. `layer3_server.py` auto-prefers T1 when matrix exists. | T1 is now default; T0 fallback only |
| 1 | Reward gate (`signal_reward(tag, magnitude)`, decay, drain), 7 engine-side emitters (drive crossings via `_check_drive_crossings`, action_succeeded at chunk-complete, rest_recovered, social_accepted, explore_discovered, threat_avoided), reward-gating modifier `(1+β·signal)` in `hebbian_update`, trace v2 `reward_events_this_tick` | F8 magnitude-sensitivity gate green (rel_delta=0.088 < 0.15) |
| 1.5 | Accelerated simulator: `scripts/accelerated_mode.gd` autoload reads `BURG_ACCEL` env, sets `Engine.time_scale` + `physics_ticks_per_second`. CLI wrapper `scripts/run_accelerated.sh`. Measured ratios: 1x→0.97, 10x→9.65, 30x→28.85 (consistent ~3% measurement undershoot from startup overhead) | LLM cadence stays wall-clock by design |
| 2 | Per-entity sensory neurogenesis. Canonical `entity_id` (deterministic SHA256-prefix of npc_name) on every NPC node, threaded through perception → snapshot. `update_per_entity_sensory()` spawns `sense_visible_{eid}`, `gc_per_entity_sensory()` after `tracker_expiry_ticks`. F9 `merge_entity_ids()` weight-sums connections + combines trackers across families | F9 stranger→named requires NO merge (neurons keyed on stable UUID) |
| 3 | Continuous distance + rate + dwell channels. `sense_dist_{eid}` with `100·exp(-d/τ)` activation (τ=4 tiles), per-neuron `prev_activation`/`rate`/`dwell` fields (dwell = EMA, α=0.05). `get_per_entity_channels()` surfaces all 6 channels per entity into snapshot/trace v2 | Refactored: `_upsert_per_entity_neuron` + `_merge_per_entity_neuron(prefix, ...)` so adding new families is trivial; `PER_ENTITY_PREFIXES = ["sense_visible_", "sense_dist_"]` |
| 4 | Distance × action-success compound emergence. `signal_action_success(verb, target_eid)` → transient `action_success_{verb}` (50→0 over 2s), distance history tracker. `check_distance_action_neurogenesis()` spawns `q_{verb}able` after N=10 samples in 60s window with receptive field = mean ± clamped(std, 0.5, 6.0). `update_qable_activations()` per-tick gaussian over current `sense_dist_*`. Wired at TOUCH/INTERACT/REST/OFFER/chunk-complete handlers in `npc_brain.gd` | Acceptance: receptive fields differ (touchable@0.55 vs approachable@5.10), generalize to new entities |
| 5 | Identity-appraisal emergence. `IdentityAppraisalTracker` (Python) accumulates F2-filtered thought embeddings per (npc, entity_id); at `encounter_threshold=5` it emits a `SpawnRequest` consumed by `AppraisalEmbeddingManager.initialize_from_thoughts` (mean-of-deque seed) and pushed to client as `spawn_identity_appraisal`. `HebbianNetwork.spawn_identity_appraisal(nid, eid)` wires sense_visible_{eid} + all active (≥30) quality neurons as incoming at weight 0.12 — no new constant, reuses existing appraisal-parent convention. F2 filter = WordNet lemma (+ proper-noun plural-strip fallback) OR cosine > 0.45. F9 `PER_ENTITY_PREFIXES` extended with `appr_identity_`. Trace v2: `new_identity_appraisals_this_tick`, `entity_thought_associations_this_tick`, `identity_appraisal_decoded`. New constant `identity_filter_min_rejection_rate=0.15` (Tier-2). | Acceptance: 3 `appr_identity_*` after 20 enc × 3 eids; max pairwise cosine 0.240 (dist>0.76); F2 rejection rate 0.247 ≥ 0.15 |
| 6 | Propagation-weight salience. `HebbianNetwork.get_outgoing_weight_sum` + `get_perception_salience` surface summed \|w\| over `sense_visible_{eid}` outgoing edges. Snapshot carries `perception_salience: {eid: float}`. `server/perception_rank.py::rank_percepts` selects top-K across both `visible` and `visible_objects` with stable input-order tiebreak (cold-start reported as `fallback`, not authored). `NPCState.build_thought_context` pre-ranks using K=`capacity.prompt_top_k_percepts` (8). `command_model.py` and `layer3_model.py` stripped of `[:6]`/`[:4]` and "Entities lead" category bias. F6 attention-entropy gate: `NPCState.attention_entropy_window` rolling deque + `rolling_entropy_mean(600.0)`; per-tick recorded in trace v2 as `attention_entropy: {tick, mean_10min, h_min, k, fallback}`. `tools/probe_attention_entropy.py` is the CI monitor — reads trace, asserts rolling 10-min mean ≥ `h_min_attention_entropy_factor * log(K)` (0.6 × log 8 ≈ 1.25). Heard percepts retain `heard[:3]` with explicit Phase 9 deferral comment. Zero new constants added. | Acceptance: 50-scene × 2-being Spearman = 0.213 (< 0.7); F6 CLI verifies PASS/FAIL/SKIP regimes and per-NPC separation |
| 7 | Flat Percept rendering + compound-gated grammar + identity phantom. `server/perception.py::render` produces spec §6.4 `You see:`/`You hear:` blocks; entity vs object rendered identically; inline tokens from Phase 5 `identity_appraisal_decoded` (computed pre-prompt now). `server/command_grammar.py` rewritten to gate verbs on active compounds: `q_touchable` for TOUCH/TAKE, `q_interactable` for INTERACT, `q_offerable` for OFFER/GIVE/SHOW; APPROACH is NEGATED by active `q_touchable` (spec §7.3). `GrammarResult` returns per-verb admission path + F4 fallback metrics. `HebbianNetwork.get_active_compounds` + `get_compound_count` surface substrate state via `layer1.get_compound_state` → snapshot `compounds`. F4 decay: `max(0, 1 - count/N)` with N=8 from constants. `command_model.py` dropped the hand-enumerated `Commands: ...` line and the verb-hint paragraph (§11.4). `server/identity_phantom.py` replaces memory-driven threat-table phantom with identity-appraisal-decoded-token → `q_{tok}` nudges (pushed as `nudge_quality` commands; client handler applies). Old `somatic_stream.gd::get_entity_threat_levels` path retired. Trace v2: `prompt_rendered`, `compounds_state`, `fallback_contribution_per_tick`, `fallback_coefficient`, `verbs_via_compound`/`verbs_via_fallback`. `tools/probe_fallback_decay.py` is the F4 CLI. Zero new constants. | Acceptance: v1/v2 scaffolding structurally absent from rendered prompt; §6.4 format + inline identity tokens present; F4 coefficient = 0 at count=N; F4 CLI verifies PASS/FAIL/SKIP |
| 8 (tooling) | v3 training corpus toolchain. `training/cognitive/maturity_classifier.py` enforces the F5 three-threshold gate (compound_count, appr_identity count, mean drift — all from `training_maturity` block). `training/cognitive/synthetic_scenarios.py` generates §15.2-style scenes from a small parameter space (4 distance bands × 3 target kinds × 5 reward contexts = 60 base scenarios, verb-coverage complete). `training/cognitive/generate_command_training_v3.py` replays traces through Phase 7's renderer, F5-gates for post-maturity, weights synthetic:replay at 2:1 from constants, emits jsonl corpus with `corpus_metadata`. `tools/probe_maturity.py` is dual-mode (`--trace` informational, `--corpus` validator with exit-1 on any pre-maturity leak). Trace v2 extended with `appraisal_drift_counts` so maturity is resolvable per-tick. Zero new constants; every threshold reads from existing `training_maturity` block. | Acceptance (tooling): F5 corpus validator PASS on generator output; synthetic coverage spans TOUCH/INTERACT/APPROACH/EXAMINE/WATCH/LOOK AT; F4+F6 CLIs still pass on post-v3 synthetic traces; corpus schema (prompt/completion/metadata) valid on every line. Runtime acceptance (GGUF verb diversity, §9.4 behavioral probes) is operator-gated — see runbook below |
| 9 | Cross-modal binding neurogenesis. `stimulus_registry.emit` gains `emitter_eid` (canonical F9 entity_id); `sensor_system.query_hearing` carries it through; `npc_controller`'s three emit sites pass `entity_id()`. `HebbianNetwork.update_per_entity_heard` spawns/refreshes `sense_heard_{eid}` from aggregated hearing activation; same-tick co-activation with `sense_visible_{eid}` ≥30 logs a co-fire event. At `cross_modal_co_fire_count`=5 within `cross_modal_window_seconds`=30 (both already in constants), `bind_{eid}` spawns wired to both modality parents at 0.12 (existing compound-parent weight; no new constant). `PER_ENTITY_PREFIXES` extended with `sense_heard_` + `bind_` for F9 merge coverage. Phase 6's heard deferral retires: `layer1.get_perception_salience_all` sums visible + heard outgoing weights, `rank_percepts` accepts heard and partitions top-K across all three; `render_hear_block` drops the [:3] cap. Trace v2 carries `cross_modal_state: {heard, bind_active, new_bind_neurons}` with per-tick drain. Zero new constants added. | Acceptance: bind_{eid} spawns after 30 encounters (Godot live + Python simulation); partial activation (visible-only, heard-only, windowed-expired) does NOT spawn; bind events land in trace; F9 merge drops deprecated sense_heard_/bind_ families; F4/F6 gates still pass |
| 10 | Temporal-texture neurogenesis. `HebbianNetwork.update_temporal_textures(dt)` reads the per-entity dwell/rate fields from Phase 3, accumulates sustained-above-threshold seconds per eid, and spawns `q_lingering_{eid}` when dwell ≥ `temporal_dwell_min` (30) continuously for `temporal_persistence_seconds` (8), `q_approaching_fast_{eid}` when rate ≥ `temporal_rate_min` (0.5). Discontinuous elevation resets the counter. Compounds wired to parent sense neuron at 0.12; category `compound_quality_temporal`; tag_text = "lingering"/"approaching_fast" directly decodes §5.5 temporal tokens. `update_temporal_activations` refreshes compound activation from parent dwell/rate each tick so they fade as the entity leaves or stops approaching. `_compound_quality_count` increments (F4 respects). `PER_ENTITY_PREFIXES` extended with both prefixes for F9. Snapshot: `temporal: {active, new_neurons}`. Phase 7 renderer inlines temporal kinds (alphabetical, leading) with identity decode within the 3-token density cap. Two new Tier-2 seeds added to `neurogenesis_thresholds`: `temporal_dwell_min`, `temporal_rate_min`. | Acceptance: 5 sustained dwell periods → 5 lingering compounds; 5 approach periods → 5 approaching; 15-min rotating session → 10 temporal neurons spanning both kinds; discontinuous dwell does NOT spawn; renderer inlines tokens per-eid and enforces density cap with temporal leading |
| 11 | Active perception via intention-attention coupling. `server/intention_attention.py::IntentionAttention` embeds the top-priority goal via existing `EmbeddingSource`, scores bootstrap concepts (cosine vs `q_{concept}` names) + active appraisal neurons (cosine vs drifted embeddings), returns top-K neuron IDs. `HebbianNetwork.pulse_intention_context` sets their activation to 40 and seeds uniform `bootstrap_intention_seed` (0.005) edges to every per-entity sense neuron. `propagate()` applies `_intention_amp_cache` per-sense (`1 + Σ I_act × w_{I→S}`, clamped at `intention_amp_cap=5.0`) to outgoing contributions. `get_intention_bootstrap_variance` returns per-intention CV of I→S weights — starts ≈0 (uniform), grows as Hebbian reshapes. `tools/probe_intention_decay.py` is F11 continuous gate: FAIL if any intention's CV stays below floor across min-samples ticks. Swapping goals clears stale intention neurons; learned edges remain. Snapshot: `intention: {context_neurons, amplification, bootstrap_variance}`. Trace v2 adds `intention_state` + `intention_context`. Three new Tier-2 seeds: `bootstrap_intention_seed`, `intention_top_k_concepts`, `intention_amp_cap`. | Acceptance: two goals produce two different top-1 rankings on same scene (Oven vs Bed); F6 entropy stays above floor under cap-level amplification (1.814 > 1.248); F11 CLI catches stuck-uniform + passes learning traces; CV mechanism distinguishes uniform from learned |
| 12 | Emergence measurement tooling. `tools/probe_magnitude_sensitivity.py` is the F8 CLI — given baseline + perturbed traces, compute Jensen-Shannon divergence on verb distributions and gate against `magnitude_sensitivity_max_kl` from constants. `tools/compare_npcs.py` unifies §9.2/§9.3/§9.4 analysis: per-NPC rollups (verb distribution, mean/min F6 entropy, mean F4 fallback, compound count, appr_identity count, mean drift, F11 CV), pairwise verb Jensen-Shannon (emergent diversity), pairwise appraisal-embedding cosine distance (read from `saves/*/appraisals.json`). Read-only, produces pretty text OR `--json` machine output. Zero new constants added. | Acceptance: all 7 required CLIs present (F1/F4/F5/F6/F8/F11/compare_npcs); mature synthetic trace passes F4+F5+F6+F11 in one sweep; cross-being §9.2.7 silhouette + §9.4 verb JS both computable from trace+saves; F8 CLI correctly fails on extreme verb divergence |

## Test sweep — all 32 green

```bash
python3 tests/test_constants_parity.py
python3 tests/test_appraisal_manager.py
python3 tests/test_identity_appraisal.py
python3 tests/test_perception_rank.py
python3 tests/test_attention_entropy.py
python3 tests/test_phase6_acceptance.py
python3 tests/test_perception_renderer.py
python3 tests/test_command_grammar_v7.py
python3 tests/test_fallback_decay.py
python3 tests/test_phase7_acceptance.py
python3 tests/test_maturity_classifier.py
python3 tests/test_probe_maturity.py
python3 tests/test_v3_generator.py
python3 tests/test_phase8_acceptance.py
python3 tests/test_phase9_acceptance.py
python3 tests/test_phase10_acceptance.py
python3 tests/test_intention_attention.py
python3 tests/test_phase11_acceptance.py
python3 tests/test_probe_magnitude_sensitivity.py
python3 tests/test_compare_npcs.py
python3 tests/test_phase12_acceptance.py
godot --path . --headless --quit --script res://tests/test_appraisal_spawn.gd
godot --path . --headless --quit --script res://tests/test_reward_gate.gd
godot --path . --headless --quit --script res://tests/test_f8_magnitude_sensitivity.gd
godot --path . --headless --quit --script res://tests/test_per_entity_sensory.gd
godot --path . --headless --quit --script res://tests/test_distance_channels.gd
godot --path . --headless --quit --script res://tests/test_distance_action_compound.gd
godot --path . --headless --quit --script res://tests/test_identity_appraisal_spawn.gd
godot --path . --headless --quit --script res://tests/test_propagation_salience.gd
godot --path . --headless --quit --script res://tests/test_cross_modal_neurogenesis.gd
godot --path . --headless --quit --script res://tests/test_temporal_texture_neurogenesis.gd
godot --path . --headless --quit --script res://tests/test_intention_pulse.gd
```

CLI gates run against any recorded trace:

```bash
python3 tools/probe_attention_entropy.py <trace.jsonl> --quiet  # F6
python3 tools/probe_fallback_decay.py <trace.jsonl> --quiet     # F4
python3 tools/probe_maturity.py --trace <trace.jsonl> --quiet   # F5 audit
python3 tools/probe_maturity.py --corpus <corpus.jsonl> --quiet # F5 corpus validator
python3 tools/probe_intention_decay.py <trace.jsonl> --quiet    # F11
python3 tools/probe_magnitude_sensitivity.py <base.jsonl> <perturbed.jsonl> --quiet  # F8
python3 tools/compare_npcs.py --trace <trace.jsonl> [--saves saves/]  # cross-being diff
```

## Phase 8 runtime runbook (operator-gated)

Tooling for v3 training is shipped and test-green. Completing Phase 8 end-to-end requires these operator steps, each taking minutes to hours:

```bash
# 1. Record ≥ 24 simulated hours per being with accelerated sim.
BURG_ACCEL=30 ./scripts/run_accelerated.sh --npcs hugo,mabel,ivy \
    --duration 24h --seed 42 --out /tmp/trace_phase8.jsonl

# 2. Audit maturity: every NPC in the trace must have crossed F5.
python3 tools/probe_maturity.py --trace /tmp/trace_phase8.jsonl

# 3. Generate v3 corpus (plug in a configured large-model completion endpoint).
python3 training/cognitive/generate_command_training_v3.py \
    --trace /tmp/trace_phase8.jsonl --out training/cognitive/corpus_v3.jsonl \
    --synthetic-ratio 2.0 --min-examples 5000

# 4. Validate corpus — must exit 0 with zero leaks.
python3 tools/probe_maturity.py --corpus training/cognitive/corpus_v3.jsonl --quiet

# 5. LoRA train on corpus_v3.jsonl → GGUF export → point llama-server at new model.

# 6. Record a post-deploy trace and re-probe F1/F4/F6 plus a fresh §9.4 behavioral run.
python3 tools/probe_embedding_semantics.py   # F1, pre-existing
python3 tools/probe_attention_entropy.py <new_trace>
python3 tools/probe_fallback_decay.py <new_trace>
```

## Up next — Phase 13 (Capstone validation, ~1 wk)

Per `docs/perception_implementation_plan.md` Phase 13 (F7 — "the test of the spec"):

**Setup:** two beings, distinct personas (e.g. Hugo, Ivy), shared world, distinct random seeds for action-tiebreak; run 1 simulated week each in accelerated sim; capture full trace v2.

**Measurement battery (all from Phase 12 tools, all must pass):**
- Identity-appraisal decoded-token overlap on shared entities (§9.2.7): < 60%
- Sensory-propagation cosine distance between beings (§9.2.7): > 0.2
- Behavioral verb-distribution KL between beings (§9.2.7): > 0.4
- Seed-randomization probe being convergence (§9.3.8): within 10% of standard
- Persona-prior falsification washout (§9.3.9): converges after ≥30 encounters
- ±20% seed perturbation steady-state behavior delta (§9.3.10): < 5%
- Top-1-verb divergence on 50-scene probe library (§9.4.11): ≥ 60%
- t=1-week individuation > t=0 individuation (§9.4.12): strictly greater
- Dynamic-neuron count > protected-neuron count at t=1 wk (§9.4.13): strictly greater
- Per-entity identity-appraisal cluster silhouette (§9.4.14): > 0.3
- F1 semantic-neighborhood probe still passes: no embedding-space corruption
- F6 attention-entropy stability: no collapse events in either trace

**Verdict:**
- Green = spec validated; the substrate produces measurably distinct beings.
- Red = re-open spec sections corresponding to failed metric. Do not paper over.

Capstone is *not* "ship it." It's "the substrate is what the spec claimed it would be." Failures here are spec defects, by the document's own contract.

Depends on: Phase 8 runtime (v3 LoRA GGUF) — if that hasn't been executed yet, the capstone runs on the v2 model with Phase 7's new prompt format, which will produce invalid commands (Phase 7 acceptance confirmed v1/v2 can't parse the new prompt). Schedule the v3 training run before attempting capstone.

## Working agreements (recorded from this conversation)

1. **Spec is the contract.** When acceptance gates fail, spec is right and code is wrong — not the other way. F1 failure at T0 is the canonical example.
2. **Honor the gates.** Don't ship Phase X green over a failed gate just because the surface metric passes. The 10 review findings (F1–F10) are integrated in `perception_implementation_plan.md`.
3. **Constants live in `data/perception_constants.json`** — only place. Both Python and Godot read from it. Parity test enforces. Adding a constant means adding it to the JSON + the parity test's REQUIRED_NESTED_KEYS.
4. **Per-entity neurons key on `entity_id`** (canonical UUID, F9), never on display name. New per-entity families register in `PER_ENTITY_PREFIXES`.
5. **Encoding consistency for any new EmbeddingSource:** matrix extraction and `embed()` MUST produce byte-identical vectors for a single-token input. First unit test for any new source: `cosine(source.embed("foo"), matrix_row_for(token_id_of("foo"))) > 0.99`.
6. **Test sweeps run cleanly between phases.** When something regresses (e.g. Phase 3 made GC remove 2 neurons not 1), update the prior phase's test to match the new substrate behavior, not the other way.
7. **A pile of fixed ____ is an antipattern.** When proposing a phase, don't invent new thresholds/weights/categories the plan doesn't already seed in `perception_constants.json`. Reuse existing spawn/wiring conventions (e.g. Phase 5 wires identity-appraisal incoming at 0.12 because that's the weight the existing quality-constellation spawn uses — not because the plan specifies it). Lemma-match in F2 is real lemmatization (WordNet) + a proper-noun plural-strip fallback because WordNet doesn't know proper-noun plurals — this is a correctness gap to watch for in future phases that lean on lemmas.

## Key open questions for Phase 13

- **Accelerated-sim 1-week runs.** Capstone spec is "1 simulated week each in accelerated sim". At Phase 1.5's measured ~30x, that's ~5.6 hours per being of wall-clock. Two beings = ~11 hours. Plan budget allowance.
- **v3 model dependency.** Phase 8 runtime gated; if v3 hasn't been trained, the capstone either skips or runs on the v2 model on the OLD prompt format. Skip is cleaner — document the cap-stone as "v3-or-bust" and don't run until `docs/phase8_colab_prompt.md` has been executed.
- **§9.3 perturbation setup.** `±20% seed perturbation steady-state behavior delta` requires THREE runs: baseline + perturbed-up + perturbed-down. The perturbation targets are values in `perception_constants.json`; build a variant-constants file per run.
- **Persona-prior falsification washout (§9.3.9).** Each persona's initial biases (from `data/npcs/*.json` drive_defaults) need to demonstrably wash out after N encounters. Requires a controlled scenario where a being's drives conflict with its persona's schedule.
- **50-scene probe library (§9.4.11).** Reuse `training/cognitive/synthetic_scenarios.py` (60 scenarios × multiple personas). Already covers the verb space; maturity isn't needed for probe purposes — just scoring.
- **Capstone CLI wrapper.** Should build a `tools/run_capstone.py` that orchestrates the accelerated runs, collects traces, runs the full measurement battery via the existing probes + compare_npcs, and emits the green/red verdict. Right now those are separate CLIs — unifying them ensures the capstone is reproducible.

Read `docs/perception_implementation_plan.md` Phase 13 in full and propose an implementation plan, then ask before writing code.
