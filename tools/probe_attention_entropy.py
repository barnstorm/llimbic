"""F6 attention-entropy CLI probe — Phase 6 of perception_implementation_plan.md.

The F6 gate: rolling 10-minute mean of attention entropy must stay above
H_MIN = `h_min_attention_entropy_factor * log(K)`. If the gate fails, the
being has developed tunnel vision (propagation-weight collapse onto a few
percepts) and the substrate has regressed Phase 6 emergence.

This CLI reads a trace file (jsonl produced by `server/trace_logger.py`),
extracts every `attention_entropy` block from `type: "thought"` records,
and reports:
- min rolling 10-min mean across the trace window,
- per-window breakdown (min/mean/max by tick),
- pass/fail verdict against H_MIN (carried in-trace per-tick so replay is
  self-contained).

This is the continuous F6 monitor — the plan states it runs against every
later phase's trace, not just Phase 6's. Exit code 0 = gate pass, 1 = fail.

Usage:
    python3 tools/probe_attention_entropy.py <trace.jsonl> [--npc NAME]
                                              [--window-seconds 600]
                                              [--min-samples 5]

Adding `--npc` filters to one being; otherwise all NPCs are audited
independently and the verdict is the AND across every being present.
"""

from __future__ import annotations

import argparse
import json
import math
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


def rolling_mean(ts_values: list[tuple[float, float]], window_s: float) -> list[tuple[float, float]]:
    """Given (timestamp, entropy) pairs in order, return (timestamp, rolling_mean)
    over a trailing window of `window_s` seconds."""
    out: list[tuple[float, float]] = []
    left = 0
    running_sum = 0.0
    for right, (ts, val) in enumerate(ts_values):
        running_sum += val
        cutoff = ts - window_s
        while left <= right and ts_values[left][0] < cutoff:
            running_sum -= ts_values[left][1]
            left += 1
        n = right - left + 1
        out.append((ts, running_sum / n if n else 0.0))
    return out


def audit_npc(name: str, samples: list[dict], window_s: float, min_samples: int) -> dict:
    """Audit one being's stream. `samples` is [{ts, tick, mean_10min, h_min, k}]
    in time order. Returns a dict with verdict + details."""
    if not samples:
        return {"npc": name, "samples": 0, "verdict": "skip", "reason": "no_samples"}

    # Recompute the rolling mean from per-tick values so the CLI is
    # self-consistent even if a trace was produced with a different window.
    pairs = [(s["ts"], s["tick"]) for s in samples]
    rolling = rolling_mean(pairs, window_s)

    # H_MIN from the trace itself (the per-tick `h_min` field carries the
    # threshold in force at record time; it may vary if K changes tick-to-tick).
    h_mins = [s["h_min"] for s in samples]

    # Walk the rolling values and check each against its corresponding h_min.
    # A violation = rolling_mean < h_min when we have at least `min_samples`
    # ticks in the window. (Early ticks where the window hasn't filled yet
    # are skipped to avoid false positives.)
    ts_list = [s["ts"] for s in samples]
    min_rolling = min((r for _, r in rolling), default=0.0)
    max_rolling = max((r for _, r in rolling), default=0.0)
    violations = 0
    worst = None  # (ts, rolling, h_min) of worst offender
    eligible = 0
    for i, (ts, r) in enumerate(rolling):
        cutoff = ts - window_s
        n = sum(1 for prev_ts in ts_list[: i + 1] if prev_ts >= cutoff)
        if n < min_samples:
            continue
        eligible += 1
        threshold = h_mins[i]
        if r < threshold:
            violations += 1
            if worst is None or (r - threshold) < (worst[1] - worst[2]):
                worst = (ts, r, threshold)

    verdict = "pass"
    if eligible == 0:
        verdict = "skip"
    elif violations > 0:
        verdict = "fail"

    return {
        "npc": name,
        "samples": len(samples),
        "eligible": eligible,
        "violations": violations,
        "min_rolling": float(min_rolling),
        "max_rolling": float(max_rolling),
        "worst": {"ts": worst[0], "rolling": worst[1], "h_min": worst[2]} if worst else None,
        "verdict": verdict,
        "k_range": [int(min(s["k"] for s in samples)), int(max(s["k"] for s in samples))],
        "h_min_range": [float(min(h_mins)), float(max(h_mins))],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="F6 attention-entropy gate probe")
    parser.add_argument("trace", help="Path to trace jsonl file")
    parser.add_argument("--npc", default=None, help="Only audit this NPC (optional)")
    parser.add_argument("--window-seconds", type=float, default=600.0,
                        help="Rolling-mean window; defaults to spec-stated 600s (10 min)")
    parser.add_argument("--min-samples", type=int, default=5,
                        help="Minimum ticks in window before gate becomes eligible")
    parser.add_argument("--quiet", action="store_true", help="Only print verdict lines")
    args = parser.parse_args()

    path = Path(args.trace)
    if not path.exists():
        print(f"ERROR: {path} not found", file=sys.stderr)
        return 2

    per_npc: dict[str, list[dict]] = defaultdict(list)
    for rec in iter_thought_records(path):
        npc = rec.get("npc", "?")
        if args.npc and npc != args.npc:
            continue
        ent = rec.get("attention_entropy") or {}
        if "tick" not in ent:
            continue
        per_npc[npc].append({
            "ts": float(rec.get("ts", 0.0)),
            "tick": float(ent.get("tick", 0.0)),
            "mean_10min": float(ent.get("mean_10min", 0.0)),
            "h_min": float(ent.get("h_min", 0.0)),
            "k": int(ent.get("k", 0)),
        })

    if not per_npc:
        print(f"WARN: no thought records with attention_entropy found in {path}")
        return 2

    overall_fail = False
    overall_skip = True
    for npc, samples in sorted(per_npc.items()):
        samples.sort(key=lambda s: s["ts"])
        result = audit_npc(npc, samples, args.window_seconds, args.min_samples)
        if result["verdict"] == "fail":
            overall_fail = True
            overall_skip = False
        elif result["verdict"] == "pass":
            overall_skip = False
        if args.quiet:
            print(f"{result['verdict'].upper()}  {npc}  "
                  f"min_rolling={result.get('min_rolling', 0.0):.3f}  "
                  f"violations={result.get('violations', 0)}/{result.get('eligible', 0)}")
        else:
            print(f"=== {npc} ===")
            for k, v in result.items():
                print(f"  {k}: {v}")

    if overall_fail:
        return 1
    if overall_skip:
        print("SKIP: no eligible samples (trace shorter than min-samples*window)")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
