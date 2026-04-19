"""Phase 11 acceptance — intention-attention coupling.

Plan acceptance:
  - §5.6: same being, two intentions, two different top-K rankings on
    identical scene.
  - Bootstrap wire's influence demonstrably weakens over reward history
    (decay verification).
  - F6 attention entropy still above floor under intention-gated
    propagation.

This test covers the Python-side mechanism end-to-end:
- Selector produces different concept sets for different goals (covered in
  test_intention_attention; we re-assert the full-pipeline shape here).
- Rank-under-intention: with amplification applied, the top-K visible
  percepts under goal A differ from those under goal B on the same scene.
- Decay: the F11 CLI on a simulated trace with varying CV across intentions
  correctly identifies uniform-stuck intentions as FAIL.
- F6: amplified weights stay under the entropy floor (integration-level
  sanity; full F6 live gate runs continuously on every trace).

Run:
    python3 tests/test_phase11_acceptance.py
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from perception_rank import rank_percepts, attention_entropy, h_floor  # noqa: E402


def test_same_scene_two_goals_two_rankings(failures: list[str]) -> None:
    """With intention amplification applied to perception_salience, two
    goals that amplify different eids produce different top-K rankings on
    the SAME scene. This is the §5.6 acceptance shape in Python form."""
    visible = [
        {"id": "ent_warm_source", "name": "Oven", "distance": 3, "direction": "n"},
        {"id": "ent_rest_spot",   "name": "Bed",  "distance": 4, "direction": "e"},
        {"id": "ent_person",      "name": "Mabel", "distance": 5, "direction": "s"},
    ]
    # Baseline bottom-up salience (from Hebbian propagation weights). We
    # simulate what the rank_percepts input would be AFTER intention
    # amplification: goal A boosts oven 3x, goal B boosts bed 3x. Base
    # salience deliberately small so amplification decides the top-1.
    base = {"ent_warm_source": 0.10, "ent_rest_spot": 0.10, "ent_person": 0.12}

    # Goal A: find warmth → ent_warm_source amplified.
    goal_a = {k: v for k, v in base.items()}
    goal_a["ent_warm_source"] *= 3.0
    r_a = rank_percepts(visible, [], goal_a, top_k=3)

    # Goal B: rest → ent_rest_spot amplified.
    goal_b = {k: v for k, v in base.items()}
    goal_b["ent_rest_spot"] *= 3.0
    r_b = rank_percepts(visible, [], goal_b, top_k=3)

    top_a = r_a.visible[0]["name"] if r_a.visible else None
    top_b = r_b.visible[0]["name"] if r_b.visible else None
    if top_a == top_b:
        failures.append(f"same top-1 under different goals: a={top_a} b={top_b}")
    elif top_a != "Oven":
        failures.append(f"goal A did not surface Oven: got {top_a}")
    elif top_b != "Bed":
        failures.append(f"goal B did not surface Bed: got {top_b}")
    else:
        print(f"  PASS  two goals → two rankings (a={top_a}, b={top_b})")


def test_intention_amp_keeps_entropy_above_floor(failures: list[str]) -> None:
    """F6 gate: under intention amplification, top-K propagation weights
    must still produce entropy above `factor * log(K)`. If ONE percept is
    amplified 3x and others stay at base, the weighted distribution is
    more peaked but still above floor for reasonable amp values."""
    # Base weights (cold-start uniform-ish).
    base_weights = [0.2] * 8
    # Apply a 3x amp to one percept.
    amped = list(base_weights)
    amped[0] *= 3.0
    h = attention_entropy(amped)
    floor = h_floor(8, 0.6)
    if h < floor:
        failures.append(f"3x amplification collapses entropy below floor: h={h:.3f} floor={floor:.3f}")
    else:
        print(f"  PASS  3x amp entropy {h:.3f} ≥ floor {floor:.3f} (F6 safe)")

    # Even stronger: a 5x amp (our cap value). Still green?
    amped2 = list(base_weights)
    amped2[0] *= 5.0
    h2 = attention_entropy(amped2)
    if h2 < floor:
        failures.append(f"5x (cap) amp collapses entropy: h={h2:.3f} floor={floor:.3f}")
    else:
        print(f"  PASS  cap-amp (5x) entropy {h2:.3f} ≥ floor {floor:.3f}")


def test_f11_cli_catches_stuck_intention(failures: list[str], tmp: Path) -> None:
    """F11 decay CLI: a trace where one intention's bootstrap_variance
    stays at 0 across ≥ min-samples ticks must FAIL. A trace where all
    intentions show non-zero CV (learning has reshaped) must PASS."""
    # Failing case: intention A stuck at 0; B is learning.
    fail_records = [
        {"type": "thought", "ts": float(i), "npc": "hugo",
         "intention_state": {
             "context_neurons": {"q_warm": 45.0, "q_settled": 45.0},
             "amplification": {},
             "bootstrap_variance": {"q_warm": 0.0, "q_settled": 0.1 + 0.001 * i},
         }}
        for i in range(30)
    ]
    fail_trace = tmp / "fail.jsonl"
    with fail_trace.open("w") as f:
        for r in fail_records:
            f.write(json.dumps(r) + "\n")
    probe = REPO_ROOT / "tools" / "probe_intention_decay.py"
    proc = subprocess.run(
        [sys.executable, str(probe), str(fail_trace), "--quiet",
         "--min-cv", "0.05", "--min-samples", "10"],
        capture_output=True, text=True, timeout=15,
    )
    if proc.returncode == 0:
        failures.append(f"stuck intention should FAIL F11: {proc.stdout}{proc.stderr}")
    elif "FAIL" not in proc.stdout:
        failures.append(f"F11 verdict not FAIL: {proc.stdout}{proc.stderr}")
    else:
        print("  PASS  F11 CLI catches stuck-at-uniform intention")

    # Passing case: both intentions above CV floor.
    pass_records = [
        {"type": "thought", "ts": float(i), "npc": "hugo",
         "intention_state": {
             "context_neurons": {"q_warm": 45.0},
             "amplification": {},
             "bootstrap_variance": {"q_warm": 0.1 + 0.005 * i},
         }}
        for i in range(30)
    ]
    pass_trace = tmp / "pass.jsonl"
    with pass_trace.open("w") as f:
        for r in pass_records:
            f.write(json.dumps(r) + "\n")
    proc = subprocess.run(
        [sys.executable, str(probe), str(pass_trace), "--quiet",
         "--min-cv", "0.05", "--min-samples", "10"],
        capture_output=True, text=True, timeout=15,
    )
    if proc.returncode != 0 or "PASS" not in proc.stdout:
        failures.append(f"learning trace should PASS F11: code={proc.returncode} out={proc.stdout}")
    else:
        print("  PASS  F11 CLI passes learning trace")


def test_bootstrap_decay_shape(failures: list[str]) -> None:
    """Conceptual: a distribution of I→S weights that starts uniform has
    CV → 0; as individual weights grow the CV grows. Direct sanity check
    so the GDScript variance computation is spec-consistent."""
    import statistics
    uniform = [0.005] * 10
    cv_uniform = statistics.pstdev(uniform) / statistics.mean(uniform)
    if cv_uniform > 1e-6:
        failures.append(f"uniform CV non-zero: {cv_uniform}")

    learned = [0.005] * 8 + [0.25, 0.15]
    cv_learned = statistics.pstdev(learned) / statistics.mean(learned)
    if cv_learned < 0.5:
        failures.append(f"learned CV too low: {cv_learned}")

    # Growth direction: learned >> uniform.
    if cv_learned <= cv_uniform:
        failures.append(f"learned CV not strictly greater than uniform: {cv_learned} vs {cv_uniform}")
    else:
        print(f"  PASS  CV distinguishes uniform ({cv_uniform:.4f}) from learned ({cv_learned:.4f})")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_same_scene_two_goals_two_rankings(failures)
        test_intention_amp_keeps_entropy_above_floor(failures)
        test_f11_cli_catches_stuck_intention(failures, tmp)
        test_bootstrap_decay_shape(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
