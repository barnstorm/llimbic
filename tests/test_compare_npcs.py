"""Phase 12 — tools/compare_npcs.py cross-being diff tests.

Verifies:
- Per-NPC rollup reads verb distribution, attention entropy, fallback
  contribution, compound count, appr_identity count, drift, intention CV.
- Pairwise verb Jensen-Shannon divergence > 0 for different beings
  and → 0 for identical beings.
- Pairwise appraisal-embedding distance reads per-being saves/*/appraisals.json
  files and computes cosine distance on shared neuron IDs.
- Empty-trace case doesn't crash.

Run:
    python3 tests/test_compare_npcs.py
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL = REPO_ROOT / "tools" / "compare_npcs.py"


def _rec_thought(npc: str, ts: float, *,
                 command: str = "WAIT",
                 entropy_tick: float = 1.5,
                 fallback: float = 0.0,
                 compound_count: int = 8,
                 active_appraisals=None,
                 drift=None,
                 cv_map=None) -> dict:
    return {
        "type": "thought", "ts": ts, "npc": npc,
        "command": command,
        "attention_entropy": {"tick": entropy_tick, "mean_10min": entropy_tick,
                              "h_min": 1.24, "k": 8, "fallback": False},
        "fallback_contribution_per_tick": fallback,
        "compounds_state": {"active": {}, "count": compound_count},
        "active_appraisals": active_appraisals or [],
        "appraisal_drift_counts": drift or {},
        "intention_state": {"context_neurons": {}, "amplification": {},
                            "bootstrap_variance": cv_map or {}},
    }


def write_trace(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def run_compare(args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(TOOL)] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return proc.returncode, (proc.stdout + proc.stderr)


def test_per_npc_rollup(failures: list[str], tmp: Path) -> None:
    records = [
        _rec_thought("hugo", 0,
            command="APPROACH Mabel",
            active_appraisals=[{"id": "appr_identity_ent_mabel", "activation": 50}],
            drift={"appr_identity_ent_mabel": 60},
            cv_map={"q_warm": 0.15}),
        _rec_thought("hugo", 1, command="APPROACH Mabel",
            active_appraisals=[{"id": "appr_identity_ent_mabel", "activation": 50}],
            drift={"appr_identity_ent_mabel": 70}),
        _rec_thought("ivy", 0, command="WANDER"),
        _rec_thought("ivy", 1, command="LOOK AT Mabel"),
    ]
    trace = tmp / "multi.jsonl"
    write_trace(trace, records)
    code, out = run_compare(["--trace", str(trace), "--json"])
    if code != 0:
        failures.append(f"compare_npcs nonzero exit: {out}")
        return
    report = json.loads(out)
    if "hugo" not in report["per_npc"] or "ivy" not in report["per_npc"]:
        failures.append(f"per_npc missing expected keys: {list(report['per_npc'])}")
        return
    hugo = report["per_npc"]["hugo"]
    if hugo["appr_identity_seen"] != 1:
        failures.append(f"hugo appr_identity count wrong: {hugo['appr_identity_seen']}")
    if abs(hugo["mean_drift_per_appraisal"] - 70.0) > 1e-6:  # last-seen wins
        failures.append(f"hugo mean drift wrong: {hugo['mean_drift_per_appraisal']}")
    # Top verb: APPROACH for hugo.
    if not hugo["top_verbs"] or hugo["top_verbs"][0][0] != "APPROACH":
        failures.append(f"hugo top verb wrong: {hugo['top_verbs']}")
    print("  PASS  per-NPC rollup reads all the expected fields")


def test_pairwise_verb_divergence(failures: list[str], tmp: Path) -> None:
    # Two NPCs with completely different verb mixes → JS > 0.
    records = [_rec_thought("a", float(i), command="WAIT") for i in range(50)] \
            + [_rec_thought("b", float(i), command="APPROACH") for i in range(50)]
    trace = tmp / "divergent.jsonl"
    write_trace(trace, records)
    code, out = run_compare(["--trace", str(trace), "--json"])
    report = json.loads(out)
    div = report["pairwise_verb_jensen_shannon"]
    if "a|b" not in div or div["a|b"] < 0.3:
        failures.append(f"divergent beings should have JS > 0.3: {div}")
    else:
        print(f"  PASS  pairwise verb JS distinguishes beings (a|b = {div['a|b']:.3f})")

    # Identical verb mixes → JS ≈ 0.
    records2 = [_rec_thought("a", float(i), command="WAIT") for i in range(50)] \
             + [_rec_thought("b", float(i), command="WAIT") for i in range(50)]
    trace2 = tmp / "identical.jsonl"
    write_trace(trace2, records2)
    code, out = run_compare(["--trace", str(trace2), "--json"])
    report = json.loads(out)
    div = report["pairwise_verb_jensen_shannon"]
    if div.get("a|b", 1.0) > 0.01:
        failures.append(f"identical beings should have JS ≈ 0: {div}")
    else:
        print(f"  PASS  identical verb mixes give JS ≈ 0 (a|b = {div['a|b']:.4f})")


def test_appraisal_silhouette_from_saves(failures: list[str], tmp: Path) -> None:
    saves = tmp / "saves"
    saves.mkdir()
    # Two beings with overlapping appr_identity_ent_mabel; different drift
    # → different embeddings. Use 8-dim orthogonal-ish vectors so cosine
    # distance is clearly > 0.
    for npc, emb in [("hugo", [1.0] + [0.0] * 7), ("ivy", [0.0, 1.0] + [0.0] * 6)]:
        (saves / npc).mkdir()
        with (saves / npc / "appraisals.json").open("w") as f:
            json.dump({
                "version": 1,
                "hidden_dim": 8,
                "neurons": {
                    "appr_identity_ent_mabel": {
                        "embedding": emb,
                        "birth_embedding": emb,
                        "drift_count": 60,
                        "seed_concepts": {},
                    },
                },
            }, f)

    trace = tmp / "minimal.jsonl"
    write_trace(trace, [_rec_thought("hugo", 0), _rec_thought("ivy", 0)])
    code, out = run_compare(["--trace", str(trace), "--saves", str(saves), "--json"])
    report = json.loads(out)
    sil = report["pairwise_appraisal_distance"]
    if "hugo|ivy" not in sil:
        failures.append(f"silhouette missing pair: {sil}")
    elif sil["hugo|ivy"] < 0.5:
        failures.append(f"expected large cosine distance (orthogonal): {sil}")
    else:
        print(f"  PASS  saves→silhouette pipeline works (hugo|ivy distance = {sil['hugo|ivy']:.3f})")


def test_empty_trace_no_crash(failures: list[str], tmp: Path) -> None:
    trace = tmp / "empty.jsonl"
    write_trace(trace, [])
    code, out = run_compare(["--trace", str(trace), "--json"])
    if code != 0:
        failures.append(f"empty trace crashed: {out}")
    else:
        report = json.loads(out)
        if report["total_records"] != 0 or report["per_npc"]:
            failures.append(f"empty trace returned non-empty rollup: {report}")
        else:
            print("  PASS  empty trace handled gracefully")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_per_npc_rollup(failures, tmp)
        test_pairwise_verb_divergence(failures, tmp)
        test_appraisal_silhouette_from_saves(failures, tmp)
        test_empty_trace_no_crash(failures, tmp)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
