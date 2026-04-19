"""Phase 12 — F8 magnitude-sensitivity CLI test.

Synthesizes two traces — baseline and perturbed — and runs the CLI against
both PASS and FAIL regimes.

Run:
    python3 tests/test_probe_magnitude_sensitivity.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROBE = REPO_ROOT / "tools" / "probe_magnitude_sensitivity.py"


def write_trace(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def run_probe(args: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(PROBE)] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return proc.returncode, (proc.stdout + proc.stderr)


def _rec(npc: str, command: str, ts: float) -> dict:
    return {"type": "thought", "ts": ts, "npc": npc, "command": command}


def test_similar_distributions_pass(failures: list[str], tmp: Path) -> None:
    """Baseline + perturbed with nearly-identical verb mixes → PASS."""
    verbs = ["WAIT", "WANDER", "LOOK AT", "APPROACH", "SAY"]
    baseline = [_rec("hugo", verbs[i % len(verbs)], float(i)) for i in range(100)]
    # Perturbed: identical order → zero divergence.
    perturbed = [_rec("hugo", verbs[i % len(verbs)], float(i)) for i in range(100)]
    b_path = tmp / "b.jsonl"; p_path = tmp / "p.jsonl"
    write_trace(b_path, baseline); write_trace(p_path, perturbed)
    code, out = run_probe([str(b_path), str(p_path), "--quiet"])
    if code != 0 or "PASS" not in out:
        failures.append(f"identical distributions should PASS; got code={code} out={out}")
    else:
        print("  PASS  identical distributions → PASS verdict")


def test_divergent_distributions_fail(failures: list[str], tmp: Path) -> None:
    """Baseline all WAIT, perturbed all APPROACH → large divergence → FAIL."""
    baseline = [_rec("hugo", "WAIT", float(i)) for i in range(100)]
    perturbed = [_rec("hugo", "APPROACH", float(i)) for i in range(100)]
    b_path = tmp / "b.jsonl"; p_path = tmp / "p.jsonl"
    write_trace(b_path, baseline); write_trace(p_path, perturbed)
    code, out = run_probe([str(b_path), str(p_path), "--quiet", "--max-kl", "0.1"])
    if code == 0 or "FAIL" not in out:
        failures.append(f"divergent distributions should FAIL; got code={code} out={out}")
    else:
        print("  PASS  divergent distributions → FAIL verdict")


def test_no_overlap_skips(failures: list[str], tmp: Path) -> None:
    """Baseline is hugo's trace, perturbed is mabel's → no overlap → SKIP."""
    baseline = [_rec("hugo", "WAIT", float(i)) for i in range(10)]
    perturbed = [_rec("mabel", "WAIT", float(i)) for i in range(10)]
    b_path = tmp / "b.jsonl"; p_path = tmp / "p.jsonl"
    write_trace(b_path, baseline); write_trace(p_path, perturbed)
    code, out = run_probe([str(b_path), str(p_path), "--quiet"])
    # Skip should not fail the gate.
    if "SKIP" not in out:
        failures.append(f"non-overlapping NPCs should SKIP; got out={out}")
    else:
        print("  PASS  non-overlapping NPCs → SKIP verdict")


def test_threshold_from_constants(failures: list[str], tmp: Path) -> None:
    """Omitting --max-kl should default to magnitude_sensitivity_max_kl (0.15)."""
    # Mildly divergent distributions (~0.08 JS); default threshold 0.15 should pass.
    baseline = [_rec("hugo", "WAIT", float(i)) for i in range(80)] + [_rec("hugo", "WANDER", float(i)) for i in range(20)]
    perturbed = [_rec("hugo", "WAIT", float(i)) for i in range(70)] + [_rec("hugo", "WANDER", float(i)) for i in range(30)]
    b_path = tmp / "b.jsonl"; p_path = tmp / "p.jsonl"
    write_trace(b_path, baseline); write_trace(p_path, perturbed)
    code, out = run_probe([str(b_path), str(p_path), "--quiet"])
    if "PASS" not in out:
        failures.append(f"mild divergence should PASS with default threshold: {out}")
    if "threshold=0.1500" not in out:
        failures.append(f"default threshold not 0.15: {out}")
    else:
        print("  PASS  default threshold sourced from constants (0.1500)")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_similar_distributions_pass(failures, tmp)
        test_divergent_distributions_fail(failures, tmp)
        test_no_overlap_skips(failures, tmp)
        test_threshold_from_constants(failures, tmp)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
