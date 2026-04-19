"""Phase 7 — F4 fallback-decay CLI probe end-to-end test.

Synthesizes a trace with three regimes — mature-clean (PASS), mature-leaky
(FAIL), cold-start only (SKIP) — and runs `tools/probe_fallback_decay.py`
against it.

Run:
    python3 tests/test_fallback_decay.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROBE = REPO_ROOT / "tools" / "probe_fallback_decay.py"


def _n_retire() -> int:
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        return int(json.load(f)["n_fallback_retire"])


def write_trace(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def make_record(npc: str, ts: float, compound_count: int,
                fallback_contribution: float) -> dict:
    return {
        "trace_schema_version": 2,
        "ts": ts,
        "type": "thought",
        "npc": npc,
        "compounds_state": {"active": {}, "count": compound_count},
        "fallback_contribution_per_tick": fallback_contribution,
    }


def run_probe(trace_path: Path, extra_args: list[str] | None = None) -> tuple[int, str]:
    cmd = [sys.executable, str(PROBE), str(trace_path), "--quiet"]
    if extra_args:
        cmd += extra_args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return proc.returncode, (proc.stdout + proc.stderr)


def test_mature_clean_passes(failures: list[str], tmp: Path) -> None:
    n = _n_retire()
    # Being at count=N+1 emits 0 contribution every tick (the substrate
    # is doing its job — compounds decided every verb).
    records = [make_record("hugo", float(i), n + 1, 0.0) for i in range(50)]
    trace = tmp / "pass.jsonl"
    write_trace(trace, records)
    code, out = run_probe(trace, ["--window-seconds", "30"])
    if code != 0 or "PASS" not in out:
        failures.append(f"mature-clean should PASS; got code={code} out={out}")
    else:
        print("  PASS  mature being with zero contribution → PASS")


def test_mature_leaky_fails(failures: list[str], tmp: Path) -> None:
    n = _n_retire()
    # Being at count=N+1 but fallback still contributing 0.1 — substrate bug.
    records = [make_record("ivy", float(i), n + 1, 0.1) for i in range(50)]
    trace = tmp / "fail.jsonl"
    write_trace(trace, records)
    code, out = run_probe(trace, ["--window-seconds", "30", "--threshold", "0.01"])
    if code == 0 or "FAIL" not in out:
        failures.append(f"mature-leaky should FAIL; got code={code} out={out}")
    else:
        print("  PASS  mature being with leaking fallback → FAIL")


def test_cold_start_skips(failures: list[str], tmp: Path) -> None:
    n = _n_retire()
    # Being never reaches N — not testable.
    records = [make_record("mabel", float(i), max(0, n - 2), 0.7) for i in range(20)]
    trace = tmp / "skip.jsonl"
    write_trace(trace, records)
    code, out = run_probe(trace, ["--window-seconds", "30"])
    if code != 0 or "SKIP" not in out:
        failures.append(f"cold-start should SKIP; got code={code} out={out}")
    else:
        print("  PASS  cold-start trace → SKIP (not mature enough to test)")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_mature_clean_passes(failures, tmp)
        test_mature_leaky_fails(failures, tmp)
        test_cold_start_skips(failures, tmp)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
