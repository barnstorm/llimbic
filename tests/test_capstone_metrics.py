"""Phase 13 — capstone_metrics unit tests.

One test per metric, each feeding synthetic inputs to verify the
compute + threshold logic. Integration is covered by
test_phase13_acceptance.py.

Run:
    python3 tests/test_capstone_metrics.py
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from capstone_metrics import (  # noqa: E402
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


def write_jsonl(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def _thought(ts: float, npc: str = "hugo", command: str = "WAIT", *,
             drives: dict | None = None,
             identity_decoded: dict | None = None,
             attention_tick: float = 1.5,
             attention_h_min: float = 1.24) -> dict:
    return {
        "type": "thought", "ts": ts, "npc": npc, "command": command,
        "drives": drives or {"energy": 80, "hunger": 20, "safety": 80, "social_need": 30},
        "identity_appraisal_decoded": identity_decoded or {},
        "attention_entropy": {"tick": attention_tick, "mean_10min": attention_tick,
                              "h_min": attention_h_min, "k": 8, "fallback": False},
    }


def test_identity_decoded_overlap(failures: list[str], tmp: Path) -> None:
    a = tmp / "a.jsonl"; b = tmp / "b.jsonl"
    write_jsonl(a, [_thought(0, identity_decoded={"ent_mabel": ["warm", "familiar", "settled"]})])
    # Same eid, disjoint tokens — Jaccard = 0 → passes (< 0.60).
    write_jsonl(b, [_thought(0, npc="ivy",
                             identity_decoded={"ent_mabel": ["tight", "prickling", "alien"]})])
    r = identity_decoded_overlap(a, b)
    if not r.passed or r.value is None or r.value >= 0.60:
        failures.append(f"disjoint decode should PASS: {r}")
    else:
        print(f"  PASS  decode overlap: {r.value:.2f} < 0.60")

    # Same eid, same tokens — overlap = 1 → fails.
    write_jsonl(b, [_thought(0, npc="ivy",
                             identity_decoded={"ent_mabel": ["warm", "familiar", "settled"]})])
    r = identity_decoded_overlap(a, b)
    if r.passed:
        failures.append(f"identical decode should FAIL: {r}")
    else:
        print(f"  PASS  identical decode: {r.value:.2f} fails gate")


def test_sensory_propagation_distance(failures: list[str]) -> None:
    # Orthogonal sensory profiles → distance ≈ 1.0.
    graph_a = {"neurons": {"sense_visible_ent_1": {"out_abs_sum": 1.0},
                            "sense_visible_ent_2": {"out_abs_sum": 0.0}}}
    graph_b = {"neurons": {"sense_visible_ent_1": {"out_abs_sum": 0.0},
                            "sense_visible_ent_2": {"out_abs_sum": 1.0}}}
    r = sensory_propagation_distance(graph_a, graph_b)
    if not r.passed or r.value is None or r.value <= 0.20:
        failures.append(f"orthogonal graphs should PASS: {r}")
    else:
        print(f"  PASS  orthogonal sense graphs: distance {r.value:.2f} > 0.20")

    # Identical → distance ≈ 0 → fails.
    r = sensory_propagation_distance(graph_a, graph_a)
    if r.passed:
        failures.append(f"identical graphs should FAIL: {r}")
    else:
        print(f"  PASS  identical sense graphs fail (distance ≈ 0)")


def test_verb_distribution_divergence(failures: list[str], tmp: Path) -> None:
    a = tmp / "a.jsonl"; b = tmp / "b.jsonl"
    # Pure WAIT vs pure APPROACH → JS ≈ log(2) ≈ 0.69 → passes > 0.40.
    write_jsonl(a, [_thought(i, command="WAIT") for i in range(50)])
    write_jsonl(b, [_thought(i, npc="ivy", command="APPROACH") for i in range(50)])
    r = verb_distribution_divergence(a, b)
    if not r.passed or r.value <= 0.40:
        failures.append(f"divergent verbs should PASS: {r}")
    else:
        print(f"  PASS  verb divergence {r.value:.3f} > 0.40")


def test_seed_convergence(failures: list[str], tmp: Path) -> None:
    # Very similar distributions → JS ≈ 0 → passes < 0.10.
    a = tmp / "a.jsonl"; b = tmp / "b.jsonl"
    write_jsonl(a, [_thought(i, command=["WAIT", "WANDER"][i % 2]) for i in range(50)])
    write_jsonl(b, [_thought(i, command=["WAIT", "WANDER"][i % 2]) for i in range(50)])
    r = seed_convergence(a, b)
    if not r.passed:
        failures.append(f"identical runs should converge: {r}")
    else:
        print(f"  PASS  identical runs converge (JS {r.value:.3f} < 0.10)")


def test_persona_prior_washout(failures: list[str], tmp: Path) -> None:
    persona = tmp / "persona.json"
    with persona.open("w") as f:
        json.dump({"drive_defaults": {"energy": 80, "hunger": 20,
                                      "safety": 80, "social_need": 30}}, f)

    # Drives pinned to prior → zero drift early + late → fails.
    trace = tmp / "pinned.jsonl"
    write_jsonl(trace, [_thought(i, drives={"energy": 80, "hunger": 20,
                                             "safety": 80, "social_need": 30})
                        for i in range(60)])
    r = persona_prior_washout(trace, persona, min_encounters=20)
    if r.passed:
        failures.append(f"pinned drives should FAIL washout: {r}")
    else:
        print("  PASS  pinned drives fail washout (no experience-driven drift)")

    # Early matches prior; late diverges → passes.
    early = [_thought(i, drives={"energy": 80, "hunger": 20, "safety": 80, "social_need": 30})
             for i in range(20)]
    late = [_thought(i + 20, drives={"energy": 40, "hunger": 60, "safety": 40, "social_need": 70})
            for i in range(40)]
    trace_good = tmp / "drift.jsonl"
    write_jsonl(trace_good, early + late)
    r = persona_prior_washout(trace_good, persona, min_encounters=20)
    if not r.passed:
        failures.append(f"drifting drives should PASS washout: {r}")
    else:
        print(f"  PASS  drifting drives pass washout (late>early Δ={r.value:.1f})")


def test_perturbation_steady_state(failures: list[str], tmp: Path) -> None:
    # Three near-identical distributions → all pairwise JS ≈ 0 → passes < 0.05.
    b = tmp / "b.jsonl"; u = tmp / "u.jsonl"; d = tmp / "d.jsonl"
    for path in (b, u, d):
        write_jsonl(path, [_thought(i, command=["WAIT", "WANDER", "LOOK AT"][i % 3])
                           for i in range(60)])
    r = perturbation_steady_state(b, u, d)
    if not r.passed:
        failures.append(f"identical triad should PASS perturbation: {r}")
    else:
        print(f"  PASS  identical perturbations stay within 5% (worst JS {r.value:.4f})")

    # Wildly different perturbed → worst > 0.05 → fails.
    write_jsonl(u, [_thought(i, command="APPROACH") for i in range(60)])
    r = perturbation_steady_state(b, u, d)
    if r.passed:
        failures.append(f"divergent perturbation should FAIL: {r}")
    else:
        print("  PASS  divergent perturbation correctly FAILS")


def test_scene_top_verb_divergence(failures: list[str]) -> None:
    # Completely different top verbs across 20 scenes → 100% divergence.
    scenes_a = [(f"scene_{i}", "TOUCH") for i in range(20)]
    scenes_b = [(f"scene_{i}", "APPROACH") for i in range(20)]
    r = scene_top_verb_divergence(scenes_a, scenes_b)
    if not r.passed:
        failures.append(f"all-different top-1 should PASS: {r}")
    else:
        print(f"  PASS  scene divergence {r.value:.2f} ≥ 0.60")

    # Same top verbs → 0 divergence → fails.
    r = scene_top_verb_divergence(scenes_a, scenes_a)
    if r.passed:
        failures.append(f"identical scenes should FAIL: {r}")
    else:
        print("  PASS  identical scenes correctly FAIL divergence")


def test_individuation_growth(failures: list[str], tmp: Path) -> None:
    a = tmp / "a.jsonl"; b = tmp / "b.jsonl"
    # Early: both WAIT (no divergence). Late: A approaches, B flees.
    a_records = [_thought(i, command="WAIT") for i in range(30)] \
              + [_thought(i + 30, command="APPROACH") for i in range(30)]
    b_records = [_thought(i, npc="ivy", command="WAIT") for i in range(30)] \
              + [_thought(i + 30, npc="ivy", command="FLEE") for i in range(30)]
    write_jsonl(a, a_records); write_jsonl(b, b_records)
    r = individuation_growth(a, b, split_point_seconds=30.0)
    if not r.passed or r.value is None or r.value <= 0:
        failures.append(f"individuation should grow: {r}")
    else:
        print(f"  PASS  individuation grew (Δ = {r.value:.3f})")


def test_dynamic_vs_protected(failures: list[str]) -> None:
    r = dynamic_vs_protected({"dynamic_count": 50, "protected_count": 20})
    if not r.passed:
        failures.append("50 > 20 should pass")
    r = dynamic_vs_protected({"dynamic_count": 10, "protected_count": 30})
    if r.passed:
        failures.append("10 > 30 should fail")
    print("  PASS  dynamic_vs_protected handles both directions")


def test_identity_appraisal_silhouette(failures: list[str]) -> None:
    # Orthogonal embeddings for shared eid → distance 1.0 → passes > 0.3.
    embs_a = {"appr_identity_ent_mabel": np.array([1.0, 0.0, 0.0], dtype=np.float32)}
    embs_b = {"appr_identity_ent_mabel": np.array([0.0, 1.0, 0.0], dtype=np.float32)}
    r = identity_appraisal_silhouette(embs_a, embs_b)
    if not r.passed or r.value <= 0.30:
        failures.append(f"orthogonal embeddings should PASS: {r}")
    else:
        print(f"  PASS  orthogonal embeddings dist {r.value:.2f} > 0.30")

    # Identical → distance ≈ 0 → fails.
    r = identity_appraisal_silhouette(embs_a, embs_a)
    if r.passed:
        failures.append(f"identical embeddings should FAIL: {r}")
    else:
        print("  PASS  identical embeddings correctly FAIL silhouette")


def test_f1_semantic_probe_status(failures: list[str]) -> None:
    # Parsing a fake probe output.
    r = f1_semantic_probe_status("probe complete\npass_rate=0.85\n")
    if not r.passed:
        failures.append(f"pass_rate=0.85 should PASS: {r}")
    r = f1_semantic_probe_status("probe complete\npass_rate=0.55\n")
    if r.passed:
        failures.append(f"pass_rate=0.55 should FAIL: {r}")
    r = f1_semantic_probe_status(None)
    if r.passed:
        failures.append("missing probe output should FAIL")
    print("  PASS  F1 parsing + threshold logic")


def test_f6_attention_entropy_ok(failures: list[str], tmp: Path) -> None:
    # Entropy well above h_min.
    trace = tmp / "healthy.jsonl"
    import math
    h_min = 0.6 * math.log(8)
    write_jsonl(trace, [_thought(float(i), attention_tick=math.log(8) * 0.95,
                                 attention_h_min=h_min)
                        for i in range(30)])
    r = f6_attention_entropy_ok(trace, window_seconds=30.0, min_samples=5)
    if not r.passed:
        failures.append(f"healthy entropy should PASS: {r}")
    else:
        print("  PASS  healthy entropy trace passes F6")

    # Tunnel vision — entropy below floor.
    trace2 = tmp / "tunnel.jsonl"
    write_jsonl(trace2, [_thought(float(i), attention_tick=0.1,
                                  attention_h_min=h_min)
                         for i in range(30)])
    r = f6_attention_entropy_ok(trace2, window_seconds=30.0, min_samples=5)
    if r.passed:
        failures.append(f"tunnel-vision entropy should FAIL: {r}")
    else:
        print("  PASS  tunnel vision correctly FAILS F6")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_identity_decoded_overlap(failures, tmp)
        test_sensory_propagation_distance(failures)
        test_verb_distribution_divergence(failures, tmp)
        test_seed_convergence(failures, tmp)
        test_persona_prior_washout(failures, tmp)
        test_perturbation_steady_state(failures, tmp)
        test_scene_top_verb_divergence(failures)
        test_individuation_growth(failures, tmp)
        test_dynamic_vs_protected(failures)
        test_identity_appraisal_silhouette(failures)
        test_f1_semantic_probe_status(failures)
        test_f6_attention_entropy_ok(failures, tmp)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
