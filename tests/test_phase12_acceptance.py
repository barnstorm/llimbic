"""Phase 12 acceptance — emergence measurement tooling.

Plan acceptance:
  - All §9.3 (decay) and §9.4 (emergence) metrics computable from trace +
    persisted state.
  - All F1, F4, F5, F6, F8 monitors expose CLIs for ad-hoc analysis.
    (F11 also shipped in Phase 11; added here for completeness.)

This test confirms, via a synthetic multi-NPC trace, that every metric the
plan's capstone (Phase 13) will consume is reachable through the shipped
CLI surface. It doesn't re-test the correctness of each individual probe
(those have their own unit tests); it confirms the TOOLING LAYER is
complete — no metric on the Phase 13 checklist requires a new tool.

Run:
    python3 tests/test_phase12_acceptance.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _rec(npc: str, ts: float, *, command: str = "WAIT",
         entropy: float = 1.5, fallback: float = 0.0,
         compound_count: int = 8, identity_count: int = 3,
         drift_mean: float = 60.0,
         cv: float | None = 0.2) -> dict:
    active = [{"id": f"appr_identity_ent_{i}", "activation": 50.0} for i in range(identity_count)]
    drift = {f"appr_identity_ent_{i}": int(drift_mean) for i in range(identity_count)}
    istate = {"context_neurons": {"q_warm": 45.0}, "amplification": {},
              "bootstrap_variance": ({"q_warm": cv} if cv is not None else {})}
    return {
        "type": "thought", "ts": ts, "npc": npc, "command": command,
        "attention_entropy": {"tick": entropy, "mean_10min": entropy,
                              "h_min": 1.24, "k": 8, "fallback": False},
        "fallback_contribution_per_tick": fallback,
        "compounds_state": {"active": {}, "count": compound_count},
        "active_appraisals": active,
        "appraisal_drift_counts": drift,
        "intention_state": istate,
    }


def write_trace(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def run_cli(tool: str, args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(REPO_ROOT / "tools" / tool)] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return proc.returncode, (proc.stdout + proc.stderr)


def test_all_clis_present(failures: list[str]) -> None:
    """Phase 12 acceptance: every monitor has a CLI."""
    expected = {
        "probe_embedding_semantics.py",  # F1
        "probe_fallback_decay.py",        # F4
        "probe_maturity.py",              # F5
        "probe_attention_entropy.py",     # F6
        "probe_magnitude_sensitivity.py", # F8  — NEW in Phase 12
        "probe_intention_decay.py",       # F11
        "compare_npcs.py",                # NEW in Phase 12
    }
    tools_dir = REPO_ROOT / "tools"
    missing = expected - {p.name for p in tools_dir.glob("*.py")}
    if missing:
        failures.append(f"missing CLIs: {missing}")
    else:
        print(f"  PASS  all {len(expected)} required CLIs present")


def test_all_gates_green_on_mature_trace(failures: list[str], tmp: Path) -> None:
    """A trace of a mature, well-learning being must pass every continuous
    gate (F4/F5/F6/F11). That's the Phase 13 capstone pre-flight."""
    trace = tmp / "mature.jsonl"
    records = [
        _rec(
            "hugo", float(i),
            command=["WAIT", "WANDER", "APPROACH Mabel", "LOOK AT", "SAY hi"][i % 5],
            entropy=1.5, fallback=0.0,
            compound_count=8, identity_count=3,
            drift_mean=60.0,
            cv=0.1 + 0.01 * i,  # growing over time → F11 happy
        )
        for i in range(60)
    ]
    write_trace(trace, records)

    # F4
    code, out = run_cli("probe_fallback_decay.py", [str(trace), "--quiet", "--window-seconds", "30"])
    if code != 0:
        failures.append(f"F4 FAIL on mature trace: {out}")

    # F6
    code, out = run_cli("probe_attention_entropy.py",
                        [str(trace), "--quiet", "--window-seconds", "30", "--min-samples", "10"])
    if code != 0:
        failures.append(f"F6 FAIL on mature trace: {out}")

    # F11
    code, out = run_cli("probe_intention_decay.py",
                        [str(trace), "--quiet", "--min-cv", "0.05", "--min-samples", "20"])
    if code != 0:
        failures.append(f"F11 FAIL on mature trace: {out}")

    # F5 corpus validator — build a tiny corpus from the trace's maturity timestamps.
    corpus = tmp / "tiny_corpus.jsonl"
    with corpus.open("w") as f:
        f.write(json.dumps({
            "prompt": "p", "completion": "c",
            "corpus_metadata": {"kind": "replay", "npc": "hugo",
                                "source_ts": 50.0, "first_mature_ts": 0.0},
        }) + "\n")
    code, out = run_cli("probe_maturity.py", ["--corpus", str(corpus), "--quiet"])
    if code != 0:
        failures.append(f"F5 corpus validator FAIL: {out}")
    if not failures:
        print("  PASS  mature trace passes F4 + F5 + F6 + F11 in one sweep")


def test_cross_being_metrics_computable(failures: list[str], tmp: Path) -> None:
    """§9.3 decay + §9.4 emergence — both should be computable from a
    multi-being trace + saves dir via compare_npcs.py."""
    trace = tmp / "multi.jsonl"
    records = []
    # Two beings with different verb distributions + different intention CVs.
    for i in range(30):
        records.append(_rec("hugo", float(i), command="APPROACH Mabel",
                            cv=0.2 + 0.001 * i))
        records.append(_rec("ivy", float(i), command="FLEE FROM Hugo",
                            cv=0.15 + 0.001 * i))
    write_trace(trace, records)

    # saves/ dir with divergent appraisal embeddings.
    saves = tmp / "saves"
    saves.mkdir()
    for npc, vec in [("hugo", [1.0] + [0.0] * 7), ("ivy", [0.0, 1.0] + [0.0] * 6)]:
        (saves / npc).mkdir()
        with (saves / npc / "appraisals.json").open("w") as f:
            json.dump({
                "version": 1, "hidden_dim": 8,
                "neurons": {
                    "appr_identity_ent_mabel": {
                        "embedding": vec, "birth_embedding": vec,
                        "drift_count": 60, "seed_concepts": {},
                    },
                },
            }, f)

    code, out = run_cli("compare_npcs.py",
                        ["--trace", str(trace), "--saves", str(saves), "--json"])
    if code != 0:
        failures.append(f"compare_npcs failed: {out}")
        return
    report = json.loads(out)
    if len(report["per_npc"]) != 2:
        failures.append(f"expected 2 beings, got {list(report['per_npc'])}")
    # §9.4: verb-distribution divergence between the two beings.
    if report["pairwise_verb_jensen_shannon"].get("hugo|ivy", 0.0) < 0.1:
        failures.append(f"§9.4 verb divergence too low: {report['pairwise_verb_jensen_shannon']}")
    # §9.2.7: appraisal silhouette cosine distance.
    if report["pairwise_appraisal_distance"].get("hugo|ivy", 0.0) < 0.5:
        failures.append(f"§9.2.7 appraisal distance too low: {report['pairwise_appraisal_distance']}")
    if not failures:
        print("  PASS  cross-being §9.2/§9.4 metrics all computable via compare_npcs")


def test_f8_magnitude_sensitivity_cli_gates_via_constants(failures: list[str], tmp: Path) -> None:
    """F8 CLI must gate on magnitude_sensitivity_max_kl from constants."""
    base = [_rec("hugo", float(i), command="WAIT") for i in range(50)]
    perturbed = [_rec("hugo", float(i), command="APPROACH") for i in range(50)]
    b_path = tmp / "b.jsonl"
    p_path = tmp / "p.jsonl"
    write_trace(b_path, base)
    write_trace(p_path, perturbed)
    code, out = run_cli("probe_magnitude_sensitivity.py",
                        [str(b_path), str(p_path), "--quiet"])
    # JS between pure WAIT and pure APPROACH is max (log 2 ≈ 0.693), way
    # over 0.15. F8 must FAIL.
    if code == 0 or "FAIL" not in out:
        failures.append(f"F8 did not FAIL on extreme verb divergence: {out}")
    else:
        print("  PASS  F8 CLI correctly FAILS on large verb divergence")


def main() -> int:
    failures: list[str] = []
    test_all_clis_present(failures)
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_all_gates_green_on_mature_trace(failures, tmp)
        test_cross_being_metrics_computable(failures, tmp)
        test_f8_magnitude_sensitivity_cli_gates_via_constants(failures, tmp)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
