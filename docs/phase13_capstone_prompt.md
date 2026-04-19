# Phase 13 — Capstone (Operator Runbook)

> Paste this document into a fresh Claude Code session on the host machine
> (Linux/WSL) that holds the repo, the trained v3 GGUF, and enough disk
> for a one-simulated-week trace per being. Assumes Phase 8 runtime has
> been completed — v3 LoRA trained, GGUF deployed, server pointed at it.

---

## Mission

Execute Phase 13 of `docs/perception_implementation_plan.md` — the F7
capstone. "The spec's own test." Run two beings in the accelerated sim for
one simulated week each, collect artifacts, run
`tools/run_capstone.py`, accept the green/red verdict.

The capstone is NOT "ship it." It's "the substrate is what the spec
claimed it would be." Failures here are spec defects by the plan's
closing contract — do not paper over.

## Prerequisites

1. Phase 8 runtime complete — v3 GGUF deployed, server pointed at it,
   all Phase 7 scaffolding reachable (`tests/test_phase7_acceptance.py`
   should exit 0 against the deployed model's output). If the v3 model
   doesn't exist yet, Phase 13 cannot run — the v1/v2 GGUFs cannot parse
   the Phase 7 flat-Percept prompt.
2. 32-gate local sweep green (`python3 tests/test_*.py && godot ...`).
3. Disk budget: each 1-simulated-week trace at ~1 Hz is ~600k records
   ~= 150-250 MB. Five runs (baseline-A, baseline-B, perturbation-up,
   perturbation-down, seed-probe) = ~1 GB.
4. Wall-clock budget at `BURG_ACCEL=30`: 1 simulated week = 5.6 hours.
   Five runs done sequentially = ~28 hours. Can be parallelized across
   hosts if available; otherwise schedule overnight across two days.
5. Persona files: `data/npcs/hugo.json` and `data/npcs/ivy.json` (or
   whichever two beings you pick) must have `drive_defaults` populated —
   §9.3.9 persona-prior washout needs them.

## Working agreement

Every metric is a gate. `tools/run_capstone.py` exits 1 if ANY of the
twelve metrics fails. That exit code is the verdict. No "mostly passed"
— the plan is explicit.

## Step 1 — Produce the five accelerated-sim traces

Each run is ~5.6 wall-clock hours. Run them sequentially from the repo
root. `BURG_ACCEL=30` targets roughly 30x real-time; actual speedup
measured at ~28-29x per Phase 1.5's tests.

```bash
# Baseline run — being A (Hugo) and being B (Ivy) run together in the
# same world, distinct random seeds for action-tiebreak.
BURG_ACCEL=30 ./scripts/run_accelerated.sh \
    --npcs hugo,ivy --accel 30 \
    --duration 5h36m --seed 42 \
    --out traces/capstone_baseline.jsonl

# Split into per-being traces for the orchestrator.
python3 tools/split_trace_by_npc.py \
    --in traces/capstone_baseline.jsonl \
    --out-dir traces/
# Produces traces/hugo.jsonl, traces/ivy.jsonl
```

```bash
# ±20% perturbation runs — same seed, but with the constants file
# variant-scaled. Operator creates the variant by copying
# data/perception_constants.json and multiplying specific fields by 1.20
# / 0.80 (seed fields; keep safety caps unchanged). See §9.3.10 for the
# exact perturbation scope.
cp data/perception_constants.json /tmp/perc_const_up.json
cp data/perception_constants.json /tmp/perc_const_down.json
# Edit each: ±20% on reward_magnitudes.* values.

PERCEPTION_CONSTANTS_OVERRIDE=/tmp/perc_const_up.json \
BURG_ACCEL=30 ./scripts/run_accelerated.sh \
    --npcs hugo --accel 30 --duration 5h36m --seed 42 \
    --out traces/perturb_up.jsonl

PERCEPTION_CONSTANTS_OVERRIDE=/tmp/perc_const_down.json \
BURG_ACCEL=30 ./scripts/run_accelerated.sh \
    --npcs hugo --accel 30 --duration 5h36m --seed 42 \
    --out traces/perturb_down.jsonl
```

> NOTE: If `PERCEPTION_CONSTANTS_OVERRIDE` isn't wired in the autoload
> yet, manually edit `data/perception_constants.json` between runs and
> restore afterward. The constants file is the only authoritative source
> of Tier-2 seeds, so swap the file and re-launch.

```bash
# Seed-randomization probe (§9.3.8): same being, scrambled bootstrap
# concepts. Shuffle the `embedding_bridge.bootstrap_concepts` list order
# in perception_constants.json (this reseeds the substrate's initial
# concept neurons).
PERCEPTION_CONSTANTS_OVERRIDE=/tmp/perc_const_scrambled.json \
BURG_ACCEL=30 ./scripts/run_accelerated.sh \
    --npcs hugo --accel 30 --duration 5h36m --seed 42 \
    --out traces/seed_probe.jsonl

# Reference "standard" run for the probe — same being, unscrambled:
BURG_ACCEL=30 ./scripts/run_accelerated.sh \
    --npcs hugo --accel 30 --duration 5h36m --seed 42 \
    --out traces/seed_standard.jsonl
```

**Verification after each run:**

```bash
python3 tools/probe_maturity.py --trace traces/hugo.jsonl
python3 tools/probe_maturity.py --trace traces/ivy.jsonl
```

Both must show `MATURE`. One simulated week at 1-Hz thought cadence =
~604k records — plenty to cross maturity by orders of magnitude.

## Step 2 — Collect persisted saves + graph summaries

The server's shutdown handler already persists `saves/{npc}/appraisals.json`
(Phase 0). For Phase 13's sensory-propagation and dynamic-vs-protected
metrics, we also need a `graph_summary.json` per being. Add this to the
shutdown path (or dump on demand via a test hook):

```bash
# On server shutdown, `HebbianNetwork.dump_graph_summary()` is serialized
# to saves/{npc}/graph_summary.json. Confirm the file exists post-run:
ls -la saves/hugo/graph_summary.json saves/ivy/graph_summary.json
```

If missing, invoke the dump via a headless one-shot script before
terminating the engine:

```bash
godot --headless --quit --script res://tools/dump_graph_summary.gd
```

(Operator may need to add this one-shot script per repo convention; the
tool reads layer1_substrate.gd's `dump_graph_summary()`.)

## Step 3 — Score the 50-scene probe library

The Phase 8 synthetic scenarios (`training/cognitive/synthetic_scenarios.py`)
generate 60 base scenes. Feed each being the scene's rendered prompt
through the deployed v3 GGUF and record the top verb:

```bash
python3 tools/score_scene_library.py \
    --persona hugo \
    --out traces/scene_responses_hugo.json
python3 tools/score_scene_library.py \
    --persona ivy \
    --out traces/scene_responses_ivy.json
```

Output format per file:
```json
[
    {"scene_id": "synth_0000_proximity_entity_only_reward_drive_satisfaction",
     "top_verb": "TOUCH"},
    ...
]
```

(Operator may need to author `tools/score_scene_library.py` if it doesn't
exist — it's a thin wrapper that renders each synthetic scenario's
context through `server/perception.py` and calls the command model's
generate endpoint for the top verb. Pattern matches the other probes.)

## Step 4 — F1 semantic-probe capture

```bash
python3 tools/probe_embedding_semantics.py > traces/f1_probe.txt 2>&1
```

The file contents will be passed to `run_capstone.py --f1-probe-output`;
capstone parses the `pass_rate=X.XX` line and compares to
`semantic_probe_min_pass_rate` (0.7) from constants.

## Step 5 — Run the capstone orchestrator

```bash
python3 tools/run_capstone.py \
    --being-a hugo --being-b ivy \
    --trace-a traces/hugo.jsonl --trace-b traces/ivy.jsonl \
    --saves-dir saves/ \
    --persona-a data/npcs/hugo.json \
    --persona-b data/npcs/ivy.json \
    --trace-perturb-up traces/perturb_up.jsonl \
    --trace-perturb-down traces/perturb_down.jsonl \
    --trace-seed-probe traces/seed_probe.jsonl \
    --trace-seed-standard traces/seed_standard.jsonl \
    --scene-responses-a traces/scene_responses_hugo.json \
    --scene-responses-b traces/scene_responses_ivy.json \
    --f1-probe-output traces/f1_probe.txt
```

**Output:** either `Phase 13 Capstone Verdict: GREEN` with all fifteen
metric-entries showing `[PASS]` (some metrics produce two entries for
per-being checks — perturbation, dynamic_vs_protected, F6 — so total is
15, not 12), or `RED` with the failing metrics enumerated.

Exit 0 = green. Exit 1 = red.

## If a metric fails

Each failure points at a specific spec section. **Do not edit tests.**
Do not edit the threshold. Do not re-run hoping for different RNG. The
plan's contract: failures are spec defects; re-open the spec section.

| Failing metric | Spec clause | Diagnostic |
|---|---|---|
| `identity_decoded_overlap` | §9.2.7 | Beings' identity-appraisals converged to shared tokens. Phase 5 F2 filter may be under-rejecting, or embedding drift rate too low |
| `sensory_propagation_distance` | §9.2.7 | Beings' Hebbian graphs too similar. Reward history isn't shaping attention per-being. Check F8 magnitude sensitivity |
| `verb_distribution_divergence` | §9.2.7 | Beings pick the same verbs in the same contexts. Could be undertrained v3 GGUF or too-strong grammar constraint |
| `seed_convergence` | §9.3.8 | Scrambled-seed run diverged from standard. Substrate is over-sensitive to bootstrap values — Phase 0.5 F1 territory |
| `persona_prior_washout_{a,b}` | §9.3.9 | One being's drives stayed pinned at persona defaults — experience isn't propagating to drive state |
| `perturbation_steady_state` | §9.3.10 | ±20% seed variation shifted steady-state behavior > 5%. F8-adjacent; reward-gating normalization may be failing |
| `scene_top_verb_divergence` | §9.4.11 | Beings produce same top-1 verb on > 40% of scenes. Phase 11 intention-attention may not be gating verbs enough |
| `individuation_growth` | §9.4.12 | Late-phase beings no more divergent than early-phase. Hebbian learning isn't individuating; check F4/F6 for silent regressions |
| `dynamic_vs_protected_{a,b}` | §9.4.13 | One being grew fewer dynamic neurons than the protected baseline. Neurogenesis rules under-firing; check Phase 4/5/9/10 spawn counts |
| `identity_appraisal_silhouette` | §9.4.14 | Per-entity identity-appraisals too similar across beings. Phase 5 drift rate too low or F2 filter too permissive |
| `f1_semantic_probe` | F1 | v3 training corrupted the embedding space. Re-train with lower LR or fewer epochs |
| `f6_attention_entropy_{a,b}` | F6 | One being's attention collapsed (tunnel vision). Phase 6 ranking + Phase 11 amplification interaction; check intention_amp_cap |

## When green

The plan is validated. Close out:

1. Mark Phase 13 as **SHIPPED — VERIFIED** in `docs/perception_implementation_plan.md`
   with the run's metric-by-metric values attached.
2. Update `docs/RESUME.md`: all 13 phases green.
3. Write a capstone memory entry with the final verdict, run parameters,
   and any notable per-metric values (especially those that barely
   cleared their thresholds — those are the substrate's weakest points).
4. The substrate is "what the spec claimed it would be." Future work
   belongs in follow-up specs, not patches on this one.

## When red

Red is a spec defect per the plan's closing contract. Open a new doc
(`docs/capstone_red_{date}.md`) recording:
- Which metrics failed + their measured values
- Run parameters (seeds, durations, accel)
- Which spec clauses are implicated
- Proposed spec change OR proposed substrate fix

Do not re-run until the underlying issue is addressed. Do not lower a
threshold to paper over a fail.
