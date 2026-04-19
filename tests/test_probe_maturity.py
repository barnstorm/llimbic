"""Phase 8 — F5 CLI probe end-to-end.

Covers three regimes:
- mature trace: per-NPC timelines reported; exit 0.
- cold-start trace: reported as cold_start; exit 0 (informational).
- corpus with pre-maturity leak: exit 1 with leaked-examples output.
- corpus clean: exit 0.
- corpus with missing metadata: exit 1.

Run:
    python3 tests/test_probe_maturity.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROBE = REPO_ROOT / "tools" / "probe_maturity.py"

sys.path.insert(0, str(REPO_ROOT / "training" / "cognitive"))
from maturity_classifier import MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT  # noqa: E402


def write_jsonl(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def run_probe(args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(PROBE)] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return proc.returncode, (proc.stdout + proc.stderr)


def _thought(ts: float, compound_count: int, n_identity: int, mean_drift: float,
             npc: str = "hugo") -> dict:
    active = [{"id": f"appr_identity_ent_{i}", "activation": 50.0} for i in range(n_identity)]
    drift = {f"appr_identity_ent_{i}": int(mean_drift) for i in range(n_identity)}
    return {
        "type": "thought",
        "ts": ts,
        "npc": npc,
        "compounds_state": {"active": {}, "count": compound_count},
        "active_appraisals": active,
        "appraisal_drift_counts": drift,
    }


def test_trace_mature_reports_timeline(failures: list[str], tmp: Path) -> None:
    records = [
        _thought(0, 2, 1, 10),
        _thought(1, MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT),
        _thought(2, MIN_COMPOUND_NEURONS + 1, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT + 10),
    ]
    trace = tmp / "mature.jsonl"
    write_jsonl(trace, records)
    code, out = run_probe(["--trace", str(trace), "--quiet"])
    if code != 0 or "MATURE" not in out.upper() or "first_mature_ts=1" not in out:
        failures.append(f"mature trace probe failed: code={code} out={out}")
    else:
        print("  PASS  --trace on mature trace reports MATURE + crossover")


def test_trace_cold_start(failures: list[str], tmp: Path) -> None:
    records = [_thought(float(i), 1, 0, 5) for i in range(5)]
    trace = tmp / "cold.jsonl"
    write_jsonl(trace, records)
    code, out = run_probe(["--trace", str(trace), "--quiet"])
    if code != 0 or "COLD_START" not in out.upper():
        failures.append(f"cold-start probe failed: code={code} out={out}")
    else:
        print("  PASS  --trace on cold-start reports COLD_START")


def test_corpus_clean_passes(failures: list[str], tmp: Path) -> None:
    corpus_path = tmp / "corpus_pass.jsonl"
    examples = [
        {
            "prompt": "p1", "completion": "c1",
            "corpus_metadata": {
                "kind": "replay", "npc": "hugo",
                "source_ts": 100.0, "first_mature_ts": 50.0,
            },
        },
        {
            "prompt": "p2", "completion": "c2",
            "corpus_metadata": {"kind": "synthetic", "scenario_id": "synth_0001"},
        },
    ]
    with corpus_path.open("w") as f:
        for e in examples:
            f.write(json.dumps(e) + "\n")
    code, out = run_probe(["--corpus", str(corpus_path), "--quiet"])
    if code != 0:
        failures.append(f"clean corpus should PASS; got code={code} out={out}")
    else:
        print("  PASS  clean corpus exits 0")


def test_corpus_leaked_fails(failures: list[str], tmp: Path) -> None:
    corpus_path = tmp / "corpus_leak.jsonl"
    examples = [
        {
            "prompt": "p1", "completion": "c1",
            "corpus_metadata": {
                "kind": "replay", "npc": "hugo",
                "source_ts": 10.0, "first_mature_ts": 50.0,  # pre-maturity leak
            },
        },
    ]
    with corpus_path.open("w") as f:
        for e in examples:
            f.write(json.dumps(e) + "\n")
    code, out = run_probe(["--corpus", str(corpus_path), "--quiet"])
    if code == 0 or "FAIL" not in out:
        failures.append(f"leaked corpus should FAIL; got code={code} out={out}")
    else:
        print("  PASS  leaked corpus exits 1 (F5 violation)")


def test_corpus_missing_metadata_fails(failures: list[str], tmp: Path) -> None:
    corpus_path = tmp / "corpus_missing.jsonl"
    with corpus_path.open("w") as f:
        f.write(json.dumps({"prompt": "p", "completion": "c"}) + "\n")  # no metadata
    code, _ = run_probe(["--corpus", str(corpus_path), "--quiet"])
    if code == 0:
        failures.append("corpus with missing metadata should FAIL")
    else:
        print("  PASS  corpus with missing metadata exits 1")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_trace_mature_reports_timeline(failures, tmp)
        test_trace_cold_start(failures, tmp)
        test_corpus_clean_passes(failures, tmp)
        test_corpus_leaked_fails(failures, tmp)
        test_corpus_missing_metadata_fails(failures, tmp)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
