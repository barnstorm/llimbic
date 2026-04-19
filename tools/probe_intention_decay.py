"""F11 intention-attention bootstrap-decay CLI — Phase 11 of
perception_implementation_plan.md.

Phase 11 seeds intention→sense edges uniformly at `bootstrap_intention_seed`.
Hebbian learning under reward reshapes specific I×S pairs, growing the
coefficient of variation (CV) across each intention neuron's outgoing
weights. CV = 0 means pure uniform bootstrap; CV > 0 means learned
specificity.

Gate: for every intention-context neuron that's been active across the trace
for at least `min_active_samples` ticks, the per-intention CV must be
strictly greater than the `min_cv_after_run` threshold. If an intention's
weights stay at uniform seed (CV ≈ 0), the substrate never learned from
reward history for that goal — an F11 regression.

Usage:
    python3 tools/probe_intention_decay.py <trace.jsonl> [--npc NAME]
                                            [--min-cv 0.05]
                                            [--min-samples 20]

Exit 0 = pass (bootstrap is decaying as designed), 1 = fail (one or more
intentions stuck at uniform), 2 = skip/error.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


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


def audit_npc(name: str, samples: list[dict], min_cv: float, min_samples: int) -> dict:
    """`samples` = ordered list of (ts, intention_state.bootstrap_variance
    dict). Walk through and measure: for each intention ever seen, how
    many ticks of active data we have + the LATEST variance value."""
    if not samples:
        return {"npc": name, "verdict": "skip", "reason": "no_samples"}

    per_intention_counts: dict[str, int] = defaultdict(int)
    per_intention_latest: dict[str, float] = {}
    for s in samples:
        bv = s.get("bootstrap_variance") or {}
        for iid, cv in bv.items():
            per_intention_counts[iid] += 1
            per_intention_latest[iid] = float(cv)

    if not per_intention_counts:
        return {"npc": name, "verdict": "skip", "reason": "no_intention_activity"}

    stuck: list[dict] = []
    passing: list[dict] = []
    for iid, count in per_intention_counts.items():
        if count < min_samples:
            # Not enough data to be testable; skip this intention silently.
            continue
        latest = per_intention_latest[iid]
        entry = {"intention": iid, "cv": float(latest), "samples": count}
        if latest < min_cv:
            stuck.append(entry)
        else:
            passing.append(entry)

    if not stuck and not passing:
        return {"npc": name, "verdict": "skip", "reason": "no_intentions_met_min_samples"}
    verdict = "fail" if stuck else "pass"
    return {
        "npc": name,
        "verdict": verdict,
        "intentions_passing": passing,
        "intentions_stuck": stuck,
        "min_cv_threshold": min_cv,
        "min_samples_threshold": min_samples,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="F11 intention bootstrap-decay probe")
    parser.add_argument("trace", help="Trace jsonl")
    parser.add_argument("--npc", default=None)
    parser.add_argument("--min-cv", type=float, default=0.05,
                        help="Minimum per-intention CV for pass (default 0.05)")
    parser.add_argument("--min-samples", type=int, default=20,
                        help="Minimum active ticks before gating (default 20)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    path = Path(args.trace)
    if not path.exists():
        print(f"ERROR: {path} not found", file=sys.stderr)
        return 2

    per_npc: dict[str, list[dict]] = defaultdict(list)
    for rec in iter_thought_records(path):
        npc = str(rec.get("npc", "?"))
        if args.npc and npc != args.npc:
            continue
        intention_state = rec.get("intention_state") or {}
        if not intention_state.get("bootstrap_variance"):
            continue
        per_npc[npc].append({
            "ts": float(rec.get("ts", 0.0)),
            "bootstrap_variance": intention_state["bootstrap_variance"],
        })

    if not per_npc:
        print(f"WARN: no intention_state.bootstrap_variance records in {path}")
        return 2

    overall_fail = False
    for npc, samples in sorted(per_npc.items()):
        samples.sort(key=lambda s: s["ts"])
        result = audit_npc(npc, samples, args.min_cv, args.min_samples)
        if result["verdict"] == "fail":
            overall_fail = True
        if args.quiet:
            passing = result.get("intentions_passing") or []
            stuck = result.get("intentions_stuck") or []
            print(f"{result['verdict'].upper()}  {npc}  "
                  f"passing={len(passing)}  stuck={len(stuck)}")
        else:
            print(f"=== {npc} ===")
            for k, v in result.items():
                print(f"  {k}: {v}")

    return 1 if overall_fail else 0


if __name__ == "__main__":
    sys.exit(main())
