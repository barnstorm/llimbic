"""F4 fallback-contribution decay CLI probe — Phase 7 of
perception_implementation_plan.md.

Gate: "any mature being (compound count ≥ N_FALLBACK_RETIRE) shows >0.01
fallback contribution averaged over 10 min" → F4 FAIL.

Reads a trace jsonl file, groups records by NPC, and for each being computes:
- current compound_count (per-tick snapshot)
- rolling 10-min mean of fallback_contribution_per_tick over the **mature
  segment** (ticks where compound_count >= N)

Verdict:
- PASS: mature segment exists AND mean ≤ 0.01
- FAIL: mature segment exists AND mean > 0.01 (substrate regression — the
  fallback did not retire even though emergent compounds are present)
- SKIP: no mature segment in trace window (being is cold-start, not testable)

Exit 0 = gate PASS or SKIP, 1 = FAIL.

Usage:
    python3 tools/probe_fallback_decay.py <trace.jsonl> [--npc NAME]
                                           [--window-seconds 600]
                                           [--threshold 0.01]
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_n_fallback_retire() -> int:
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        return int(json.load(f).get("n_fallback_retire", 8))


def iter_thought_records(path: Path):
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "thought":
                continue
            yield rec


def audit_npc(name: str, samples: list[dict], window_s: float,
              threshold: float, n_retire: int) -> dict:
    """`samples` = ordered list of {ts, count, contribution}."""
    if not samples:
        return {"npc": name, "verdict": "skip", "reason": "no_samples"}
    mature = [s for s in samples if s["count"] >= n_retire]
    if not mature:
        return {
            "npc": name,
            "verdict": "skip",
            "reason": "not_mature",
            "max_count_seen": max(s["count"] for s in samples),
            "n_retire": n_retire,
        }

    # Mean contribution across the mature segment.
    mean_contribution = sum(s["contribution"] for s in mature) / len(mature)
    max_contribution = max(s["contribution"] for s in mature)

    # Rolling 10-min mean — look for any window-sized mature stretch whose
    # mean exceeds the threshold. We take the stricter of: (a) overall mature
    # mean, (b) worst rolling window mean.
    worst_rolling = 0.0
    if mature:
        mature.sort(key=lambda s: s["ts"])
        # Sliding window
        left = 0
        running_sum = 0.0
        for right, s in enumerate(mature):
            running_sum += s["contribution"]
            cutoff = s["ts"] - window_s
            while left <= right and mature[left]["ts"] < cutoff:
                running_sum -= mature[left]["contribution"]
                left += 1
            n = right - left + 1
            rolling_mean = running_sum / n if n else 0.0
            worst_rolling = max(worst_rolling, rolling_mean)

    fail = (mean_contribution > threshold) or (worst_rolling > threshold)
    return {
        "npc": name,
        "verdict": "fail" if fail else "pass",
        "mature_samples": len(mature),
        "mean_contribution": float(mean_contribution),
        "max_contribution": float(max_contribution),
        "worst_rolling_window_mean": float(worst_rolling),
        "threshold": float(threshold),
        "n_retire": n_retire,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="F4 fallback-decay gate probe")
    parser.add_argument("trace", help="Path to trace jsonl")
    parser.add_argument("--npc", default=None)
    parser.add_argument("--window-seconds", type=float, default=600.0)
    parser.add_argument("--threshold", type=float, default=0.01,
                        help="Max allowed fallback_contribution for mature beings")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    path = Path(args.trace)
    if not path.exists():
        print(f"ERROR: {path} not found", file=sys.stderr)
        return 2

    n_retire = _load_n_fallback_retire()

    per_npc: dict[str, list[dict]] = defaultdict(list)
    for rec in iter_thought_records(path):
        npc = rec.get("npc", "?")
        if args.npc and npc != args.npc:
            continue
        contrib = rec.get("fallback_contribution_per_tick")
        if contrib is None:
            continue
        compounds = rec.get("compounds_state") or {}
        count = int(compounds.get("count", 0))
        per_npc[npc].append({
            "ts": float(rec.get("ts", 0.0)),
            "count": count,
            "contribution": float(contrib),
        })

    if not per_npc:
        print(f"WARN: no thought records with fallback_contribution_per_tick in {path}")
        return 2

    overall_fail = False
    for npc, samples in sorted(per_npc.items()):
        samples.sort(key=lambda s: s["ts"])
        result = audit_npc(npc, samples, args.window_seconds, args.threshold, n_retire)
        if result["verdict"] == "fail":
            overall_fail = True
        if args.quiet:
            print(f"{result['verdict'].upper()}  {npc}  "
                  f"mean={result.get('mean_contribution', 0.0):.4f}  "
                  f"worst={result.get('worst_rolling_window_mean', 0.0):.4f}")
        else:
            print(f"=== {npc} ===")
            for k, v in result.items():
                print(f"  {k}: {v}")

    return 1 if overall_fail else 0


if __name__ == "__main__":
    sys.exit(main())
