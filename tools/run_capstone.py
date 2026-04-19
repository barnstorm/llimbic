"""tools/run_capstone.py — Phase 13 capstone orchestrator (F7).

Per docs/perception_implementation_plan.md Phase 13: "The spec's own test."
This tool runs the full twelve-metric measurement battery on a completed
two-being capstone scenario and emits the green/red verdict.

The actual accelerated-sim runs that produce the input artifacts are
operator-gated (see docs/phase13_capstone_prompt.md). This orchestrator is
the offline analysis step that runs AFTER those artifacts exist.

Inputs:
    --being-a       <npc_name>                 the first being's NPC name
    --being-b       <npc_name>                 the second being's NPC name
    --trace-a       <path.jsonl>               trace jsonl for being A (1 sim week)
    --trace-b       <path.jsonl>               trace jsonl for being B (1 sim week)
    --saves-dir     <path>                     saves/ dir with {npc}/appraisals.json
                                               AND {npc}/graph_summary.json per being
    --persona-a     <path.json>                data/npcs/{a}.json — for §9.3.9 washout
    --persona-b     <path.json>                data/npcs/{b}.json — for §9.3.9 washout
    --trace-perturb-up   <path.jsonl>          baseline +20% perturbation (§9.3.10)
    --trace-perturb-down <path.jsonl>          baseline -20% perturbation (§9.3.10)
    --trace-seed-probe     <path.jsonl>        scrambled-seed replicate (§9.3.8)
    --trace-seed-standard  <path.jsonl>        standard-seed replicate for same being (§9.3.8)
    --scene-responses-a  <path.json>           [{scene_id, top_verb}, ...] for A (§9.4.11)
    --scene-responses-b  <path.json>           [{scene_id, top_verb}, ...] for B (§9.4.11)
    --f1-probe-output    <path.txt>            captured output of probe_embedding_semantics.py
    --split-seconds      <float>               early/late split point for §9.4.12 individuation growth
                                               (default: midpoint of trace-a's timestamps)
    --json                                     emit machine-readable JSON

Output:
    A pretty report with per-metric pass/fail + overall green/red verdict.
    Exit 0 = green (all twelve metrics pass), 1 = red (≥ one metric fails).

This tool HAS NO opinion about the acceptance gates — every threshold is
spec-sourced in `capstone_metrics.py`. A failure means "the spec says X
should hold, this being X does not" — that's a spec defect per the plan's
closing contract, not a tooling bug. Do not paper over.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from capstone_metrics import (  # noqa: E402
    MetricResult,
    iter_thought_records,
    load_appraisal_embeddings, load_graph_summary,
    identity_decoded_overlap,
    sensory_propagation_distance,
    verb_distribution_divergence,
    seed_convergence,
    persona_prior_washout,
    perturbation_steady_state,
    scene_top_verb_divergence,
    individuation_growth,
    dynamic_vs_protected,
    identity_appraisal_silhouette,
    f1_semantic_probe_status,
    f6_attention_entropy_ok,
)


def _auto_split_seconds(trace_path: Path) -> float:
    ts_min = float("inf"); ts_max = -float("inf")
    for rec in iter_thought_records(trace_path):
        ts = float(rec.get("ts", 0.0))
        ts_min = min(ts_min, ts); ts_max = max(ts_max, ts)
    if ts_min == float("inf"):
        return 0.0
    return (ts_min + ts_max) / 2.0


def _load_scene_responses(path: Path | None) -> list[tuple[str, str]]:
    if path is None or not path.exists():
        return []
    with path.open() as f:
        data = json.load(f)
    return [(str(e.get("scene_id")), str(e.get("top_verb"))) for e in data if e.get("top_verb")]


def _load_probe_output(path: Path | None) -> str | None:
    if path is None or not path.exists():
        return None
    return path.read_text()


def run_capstone(
    being_a: str, being_b: str,
    trace_a: Path, trace_b: Path,
    saves_dir: Path,
    persona_a: Path, persona_b: Path,
    trace_perturb_up: Path | None = None,
    trace_perturb_down: Path | None = None,
    trace_seed_probe: Path | None = None,
    trace_seed_standard: Path | None = None,
    scene_responses_a: Path | None = None,
    scene_responses_b: Path | None = None,
    f1_probe_output: Path | None = None,
    split_seconds: float | None = None,
) -> tuple[list[MetricResult], str]:
    """Run all twelve metrics; return (results, verdict)."""
    results: list[MetricResult] = []

    embs_a = load_appraisal_embeddings(saves_dir / being_a)
    embs_b = load_appraisal_embeddings(saves_dir / being_b)
    graph_a = load_graph_summary(saves_dir / being_a)
    graph_b = load_graph_summary(saves_dir / being_b)

    split = split_seconds if split_seconds is not None else _auto_split_seconds(trace_a)

    # §9.2.7 triad (metrics 1, 2, 3)
    results.append(identity_decoded_overlap(trace_a, trace_b))
    results.append(sensory_propagation_distance(graph_a, graph_b))
    results.append(verb_distribution_divergence(trace_a, trace_b))

    # §9.3.8 seed-randomization convergence: two SAME-class runs (same
    # being, scrambled bootstrap seeds) must converge. Operator supplies
    # a standard + probe trace; if omitted, mark metric FAIL with reason.
    if trace_seed_probe and trace_seed_standard:
        results.append(seed_convergence(trace_seed_probe, trace_seed_standard))
    else:
        results.append(MetricResult(
            name="seed_convergence",
            passed=False, value=None,
            detail={"reason": "seed probe/standard traces not supplied"},
            threshold="< 0.10 (Jensen-Shannon)",
        ))

    # §9.3.9 persona washout (per being — we run it twice and combine).
    washout_a = persona_prior_washout(trace_a, persona_a)
    washout_a.name = "persona_prior_washout_a"
    washout_b = persona_prior_washout(trace_b, persona_b)
    washout_b.name = "persona_prior_washout_b"
    results.append(washout_a)
    results.append(washout_b)

    # §9.3.10 perturbation — only runnable if the operator captured the
    # +20%/-20% runs.
    if trace_perturb_up and trace_perturb_down:
        results.append(perturbation_steady_state(trace_a, trace_perturb_up, trace_perturb_down))
    else:
        results.append(MetricResult(
            name="perturbation_steady_state",
            passed=False, value=None,
            detail={"reason": "perturbation traces not supplied"},
            threshold="< 0.05 worst pairwise JS",
        ))

    # §9.4.11 top-1-verb divergence.
    sr_a = _load_scene_responses(scene_responses_a)
    sr_b = _load_scene_responses(scene_responses_b)
    if sr_a and sr_b:
        results.append(scene_top_verb_divergence(sr_a, sr_b))
    else:
        results.append(MetricResult(
            name="scene_top_verb_divergence",
            passed=False, value=None,
            detail={"reason": "scene response files not supplied"},
            threshold="≥ 0.60",
        ))

    # §9.4.12 individuation growth.
    results.append(individuation_growth(trace_a, trace_b, split))

    # §9.4.13 dynamic vs protected — per being; both must pass.
    dvp_a = dynamic_vs_protected(graph_a); dvp_a.name = "dynamic_vs_protected_a"
    dvp_b = dynamic_vs_protected(graph_b); dvp_b.name = "dynamic_vs_protected_b"
    results.append(dvp_a)
    results.append(dvp_b)

    # §9.4.14 identity-appraisal silhouette.
    results.append(identity_appraisal_silhouette(embs_a, embs_b))

    # F1 (Metric 11)
    results.append(f1_semantic_probe_status(_load_probe_output(f1_probe_output)))

    # F6 (Metric 12) — per trace; both must pass.
    f6_a = f6_attention_entropy_ok(trace_a); f6_a.name = "f6_attention_entropy_a"
    f6_b = f6_attention_entropy_ok(trace_b); f6_b.name = "f6_attention_entropy_b"
    results.append(f6_a)
    results.append(f6_b)

    all_pass = all(r.passed for r in results)
    return results, ("green" if all_pass else "red")


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 13 capstone orchestrator")
    parser.add_argument("--being-a", required=True)
    parser.add_argument("--being-b", required=True)
    parser.add_argument("--trace-a", required=True, type=Path)
    parser.add_argument("--trace-b", required=True, type=Path)
    parser.add_argument("--saves-dir", required=True, type=Path)
    parser.add_argument("--persona-a", required=True, type=Path)
    parser.add_argument("--persona-b", required=True, type=Path)
    parser.add_argument("--trace-perturb-up", type=Path, default=None)
    parser.add_argument("--trace-perturb-down", type=Path, default=None)
    parser.add_argument("--trace-seed-probe", type=Path, default=None)
    parser.add_argument("--trace-seed-standard", type=Path, default=None)
    parser.add_argument("--scene-responses-a", type=Path, default=None)
    parser.add_argument("--scene-responses-b", type=Path, default=None)
    parser.add_argument("--f1-probe-output", type=Path, default=None)
    parser.add_argument("--split-seconds", type=float, default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    results, verdict = run_capstone(
        being_a=args.being_a, being_b=args.being_b,
        trace_a=args.trace_a, trace_b=args.trace_b,
        saves_dir=args.saves_dir,
        persona_a=args.persona_a, persona_b=args.persona_b,
        trace_perturb_up=args.trace_perturb_up,
        trace_perturb_down=args.trace_perturb_down,
        trace_seed_probe=args.trace_seed_probe,
        trace_seed_standard=args.trace_seed_standard,
        scene_responses_a=args.scene_responses_a,
        scene_responses_b=args.scene_responses_b,
        f1_probe_output=args.f1_probe_output,
        split_seconds=args.split_seconds,
    )

    payload = {
        "verdict": verdict,
        "metrics": [
            {
                "name": r.name,
                "passed": r.passed,
                "value": r.value,
                "threshold": r.threshold,
                "detail": r.detail,
            }
            for r in results
        ],
    }

    if args.json:
        print(json.dumps(payload, indent=2, default=str))
    else:
        print(f"=== Phase 13 Capstone Verdict: {verdict.upper()} ===\n")
        for r in results:
            print(f"  [{r.verdict}] {r.name}")
            if r.value is not None:
                print(f"          value: {r.value}")
            print(f"          threshold: {r.threshold}")
            if r.detail:
                for k, v in r.detail.items():
                    print(f"          {k}: {v}")
            print()
        passed_count = sum(1 for r in results if r.passed)
        print(f"Summary: {passed_count}/{len(results)} metrics passed")

    return 0 if verdict == "green" else 1


if __name__ == "__main__":
    sys.exit(main())
