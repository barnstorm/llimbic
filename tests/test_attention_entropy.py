"""Phase 6 — F6 attention-entropy monitor + CLI probe end-to-end.

Synthesizes a trace jsonl file with three distinct entropy regimes and runs
`tools/probe_attention_entropy.py` against it:
- PASS regime: uniform-ish weights → rolling mean well above H_MIN.
- FAIL regime: tunnel-vision → rolling mean collapses below H_MIN.
- SKIP regime: not enough eligible ticks (short trace).

The CLI is the continuous F6 gate from Phase 6 onward; it has to work against
any trace without a live run.

Run:
    python3 tests/test_attention_entropy.py
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
sys.path.insert(0, str(REPO_ROOT / "tools"))

from perception_rank import attention_entropy, h_floor  # noqa: E402

PROBE = REPO_ROOT / "tools" / "probe_attention_entropy.py"


def write_trace(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def make_record(npc: str, ts: float, tick: float, mean_10min: float,
                h_min: float, k: int) -> dict:
    return {
        "trace_schema_version": 2,
        "ts": ts,
        "type": "thought",
        "npc": npc,
        "attention_entropy": {
            "tick": tick,
            "mean_10min": mean_10min,
            "h_min": h_min,
            "k": k,
            "fallback": False,
        },
    }


def run_probe(trace_path: Path, npc: str | None = None,
              extra_args: list[str] | None = None) -> tuple[int, str]:
    cmd = [sys.executable, str(PROBE), str(trace_path), "--quiet"]
    if npc:
        cmd += ["--npc", npc]
    if extra_args:
        cmd += extra_args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return proc.returncode, (proc.stdout + proc.stderr)


def test_pass_regime(failures: list[str], tmp: Path) -> None:
    """Uniform-ish weights: rolling mean well above h_min."""
    h_min = h_floor(8, 0.6)  # 1.2477
    records = []
    for i in range(100):
        # Tick entropy ≈ log(8) (uniform); rolling mean mirrors.
        tick_h = math.log(8) * 0.95
        records.append(make_record(
            npc="hugo", ts=float(i), tick=tick_h,
            mean_10min=tick_h, h_min=h_min, k=8,
        ))
    trace = tmp / "pass.jsonl"
    write_trace(trace, records)
    code, out = run_probe(trace, extra_args=["--window-seconds", "50", "--min-samples", "5"])
    if code != 0:
        failures.append(f"PASS regime should exit 0, got {code}; out={out}")
    elif "PASS" not in out:
        failures.append(f"PASS regime missing verdict in: {out}")
    else:
        print(f"  PASS  F6 CLI verdict=PASS on uniform trace")


def test_fail_regime(failures: list[str], tmp: Path) -> None:
    """Tunnel vision: rolling mean under the floor."""
    h_min = h_floor(8, 0.6)
    records = []
    for i in range(100):
        tick_h = 0.1  # far below h_min (1.25)
        records.append(make_record(
            npc="ivy", ts=float(i), tick=tick_h,
            mean_10min=tick_h, h_min=h_min, k=8,
        ))
    trace = tmp / "fail.jsonl"
    write_trace(trace, records)
    code, out = run_probe(trace, extra_args=["--window-seconds", "50", "--min-samples", "5"])
    if code == 0:
        failures.append(f"FAIL regime should exit 1, got 0; out={out}")
    elif "FAIL" not in out:
        failures.append(f"FAIL regime missing verdict in: {out}")
    else:
        print(f"  PASS  F6 CLI verdict=FAIL on tunnel trace")


def test_skip_regime(failures: list[str], tmp: Path) -> None:
    """Short trace: not enough ticks to be eligible."""
    h_min = h_floor(8, 0.6)
    records = [make_record(
        npc="mabel", ts=0.0, tick=0.5, mean_10min=0.5, h_min=h_min, k=8,
    )]
    trace = tmp / "skip.jsonl"
    write_trace(trace, records)
    code, out = run_probe(trace, extra_args=["--window-seconds", "600", "--min-samples", "10"])
    # Skip is acceptable (exit 0) — no eligible windows.
    if code not in (0,):
        failures.append(f"SKIP regime: unexpected exit {code}; out={out}")
    elif "SKIP" not in out:
        failures.append(f"SKIP regime: verdict not SKIP; out={out}")
    else:
        print(f"  PASS  F6 CLI verdict=SKIP on short trace")


def test_multi_npc_fail_propagates(failures: list[str], tmp: Path) -> None:
    """One failing NPC → overall gate fail even if the others pass."""
    h_min = h_floor(8, 0.6)
    records = []
    for i in range(100):
        records.append(make_record("hugo", float(i), math.log(8) * 0.95, math.log(8) * 0.95, h_min, 8))
        records.append(make_record("ivy",  float(i), 0.1,                0.1,                h_min, 8))
    trace = tmp / "mixed.jsonl"
    write_trace(trace, records)
    code, out = run_probe(trace, extra_args=["--window-seconds", "50", "--min-samples", "5"])
    if code == 0:
        failures.append(f"multi-NPC one-fail should exit 1; got 0; out={out}")
    elif "FAIL  ivy" not in out or "PASS  hugo" not in out:
        failures.append(f"multi-NPC verdict split wrong in: {out}")
    else:
        print(f"  PASS  F6 CLI per-NPC verdict separation works")


def test_compute_attention_entropy_plumbing(failures: list[str]) -> None:
    """Smoke: the per-tick entropy function the CLI reads matches the live
    computation. (The CLI reads the trace-recorded value, not recomputes,
    but this test confirms the recorded value comes from the same code path.)"""
    weights = [0.5, 0.3, 0.2]
    h = attention_entropy(weights)
    expected = -sum(p * math.log(p) for p in [0.5, 0.3, 0.2])
    if abs(h - expected) > 1e-9:
        failures.append(f"attention_entropy divergence: {h} vs {expected}")
    else:
        print("  PASS  attention_entropy computes Shannon entropy correctly")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        print("test_pass_regime:");                  test_pass_regime(failures, tmp)
        print("test_fail_regime:");                  test_fail_regime(failures, tmp)
        print("test_skip_regime:");                  test_skip_regime(failures, tmp)
        print("test_multi_npc_fail_propagates:");    test_multi_npc_fail_propagates(failures, tmp)
        print("test_compute_attention_entropy_plumbing:")
        test_compute_attention_entropy_plumbing(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
