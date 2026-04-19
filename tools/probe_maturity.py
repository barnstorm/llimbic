"""F5 maturity-gate CLI probe — Phase 8 of perception_implementation_plan.md.

Two modes:
- `--trace <file>`: audit a live trace jsonl for per-NPC maturity timelines
  (when each being crossed threshold, pre/post sample counts, final counts).
  Exit 0 — informational output.
- `--corpus <file>`: validate a v3 training corpus jsonl. Each entry must
  carry a `corpus_metadata` block showing the source trace_ts was after the
  being's `first_mature_ts`. Exit 1 if any entry is pre-maturity — the
  dataset has leaked cold-start samples and MUST be re-harvested per Phase 8.

Usage:
    python3 tools/probe_maturity.py --trace <path.jsonl> [--npc NAME]
    python3 tools/probe_maturity.py --corpus <path.jsonl>

This CLI joins F1, F4, F6 as a continuous substrate-regression gate. Every
subsequent phase that retrains (or re-harvests) re-runs this against its
corpus; any pre-maturity leak fails CI.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "training" / "cognitive"))

from maturity_classifier import (  # noqa: E402
    build_timeline, evaluate_record,
    MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT,
)


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


def audit_trace(path: Path, npc_filter: str | None, quiet: bool) -> int:
    per_npc: dict[str, list[dict]] = defaultdict(list)
    for rec in iter_thought_records(path):
        npc = str(rec.get("npc", "?"))
        if npc_filter and npc != npc_filter:
            continue
        per_npc[npc].append(rec)
    if not per_npc:
        print(f"WARN: no thought records in {path}", file=sys.stderr)
        return 2

    for npc, records in sorted(per_npc.items()):
        timeline = build_timeline(npc, records)
        crossover = "none" if timeline.first_mature_ts is None else f"{timeline.first_mature_ts:.1f}"
        verdict = "mature" if timeline.first_mature_ts is not None else "cold_start"
        if quiet:
            print(f"{verdict.upper():<11s}  {npc}  "
                  f"first_mature_ts={crossover}  "
                  f"pre={timeline.pre_maturity_samples}  post={timeline.post_maturity_samples}")
        else:
            print(f"=== {npc} ===")
            print(f"  verdict: {verdict}")
            print(f"  first_mature_ts: {crossover}")
            print(f"  total_samples: {timeline.total_samples}")
            print(f"  pre_maturity_samples: {timeline.pre_maturity_samples}")
            print(f"  post_maturity_samples: {timeline.post_maturity_samples}")
            print(f"  final_compound_count: {timeline.final_compound_count} "
                  f"(threshold: {MIN_COMPOUND_NEURONS})")
            print(f"  final_appr_identity_count: {timeline.final_appr_identity_count} "
                  f"(threshold: {MIN_APPR_IDENTITY})")
            print(f"  final_mean_drift: {timeline.final_mean_drift:.2f} "
                  f"(threshold: {MIN_MEAN_DRIFT})")
    return 0


def validate_corpus(path: Path, quiet: bool) -> int:
    """A v3 corpus is a jsonl where each line is a training example with a
    `corpus_metadata` block carrying:
      - npc: string
      - source_ts: float (trace record timestamp)
      - first_mature_ts: float (pre-computed from the source trace)
      - kind: "replay" | "synthetic"
    A corpus is valid iff:
      - every replay sample has source_ts >= first_mature_ts
      - synthetic samples bypass the timing gate (they are not from a trace)
    """
    total = 0
    leaked = 0
    missing_meta = 0
    by_npc: dict[str, int] = defaultdict(int)
    leaked_examples: list[dict] = []

    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            total += 1
            meta = rec.get("corpus_metadata") or {}
            kind = meta.get("kind")
            if kind is None:
                missing_meta += 1
                continue
            if kind == "synthetic":
                by_npc["(synthetic)"] += 1
                continue
            # replay — must be post-maturity
            by_npc[str(meta.get("npc", "?"))] += 1
            src_ts = float(meta.get("source_ts", -1))
            fmt = meta.get("first_mature_ts")
            if fmt is None or src_ts < float(fmt):
                leaked += 1
                if len(leaked_examples) < 5:
                    leaked_examples.append({"src_ts": src_ts, "first_mature_ts": fmt, "npc": meta.get("npc")})

    if quiet:
        verdict = "FAIL" if (leaked or missing_meta) else "PASS"
        print(f"{verdict}  corpus={path}  total={total}  leaked={leaked}  missing_meta={missing_meta}")
    else:
        print(f"=== corpus: {path} ===")
        print(f"  total: {total}")
        print(f"  missing_metadata: {missing_meta}")
        print(f"  pre_maturity_leaks: {leaked}")
        print("  by_source:")
        for k, v in sorted(by_npc.items()):
            print(f"    {k}: {v}")
        if leaked:
            print("  leaked examples (first 5):")
            for ex in leaked_examples:
                print(f"    {ex}")
    if leaked or missing_meta:
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="F5 maturity probe / corpus validator")
    parser.add_argument("--trace", help="Path to trace jsonl")
    parser.add_argument("--corpus", help="Path to v3 training corpus jsonl")
    parser.add_argument("--npc", default=None, help="Filter to one NPC (trace mode)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if not args.trace and not args.corpus:
        parser.error("one of --trace or --corpus required")
    if args.trace:
        return audit_trace(Path(args.trace), args.npc, args.quiet)
    return validate_corpus(Path(args.corpus), args.quiet)


if __name__ == "__main__":
    sys.exit(main())
