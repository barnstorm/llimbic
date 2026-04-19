"""F8 magnitude-sensitivity CLI — Phase 12 of perception_implementation_plan.md.

Phase 1 established reward-gating normalization. F8's test: scale every
reward magnitude in `perception_constants.json` by 2x, re-run the sim, and
check that the verb distribution hasn't shifted more than
`magnitude_sensitivity_max_kl` from the baseline. If it HAS shifted, the
magnitudes are bypassing reward-gating's normalization — a Phase 1 defect.

Today this gate has a Godot test (tests/test_f8_magnitude_sensitivity.gd)
that exercises the reward-gating normalization directly. Phase 12 adds this
trace-level CLI so the gate can run against ANY two traces post-deploy —
baseline vs perturbed, v2 vs v3 post-retrain, mature vs cold-start — and
confirm the substrate's verb distribution is robust to magnitude scaling.

KL formula: symmetric (Jensen-Shannon divergence actually; pure KL is
asymmetric and magnitude-sensitivity should be direction-agnostic).

Usage:
    python3 tools/probe_magnitude_sensitivity.py <baseline.jsonl> <perturbed.jsonl>
                                                 [--npc NAME]
                                                 [--max-kl 0.15]
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_max_kl() -> float:
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        return float(json.load(f).get("magnitude_sensitivity_max_kl", 0.15))


def _verb_distribution(path: Path, npc_filter: str | None) -> dict[str, Counter]:
    """Return {npc: Counter(verb -> count)} across a trace."""
    by_npc: dict[str, Counter] = defaultdict(Counter)
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
            npc = str(rec.get("npc", "?"))
            if npc_filter and npc != npc_filter:
                continue
            cmd = str(rec.get("command", "")).strip()
            if not cmd:
                continue
            verb = cmd.split()[0]
            by_npc[npc][verb] += 1
    return by_npc


def _jensen_shannon(p: dict[str, float], q: dict[str, float]) -> float:
    """Symmetric KL-like distance. Both p and q must sum to 1 (or close)."""
    keys = set(p.keys()) | set(q.keys())
    if not keys:
        return 0.0
    # Build aligned probability vectors with a small uniform prior so neither
    # distribution has zeros (pure KL blows up; this is the standard smoothing).
    eps = 1e-9
    p_arr = [p.get(k, 0.0) + eps for k in keys]
    q_arr = [q.get(k, 0.0) + eps for k in keys]
    ps = sum(p_arr)
    qs = sum(q_arr)
    p_arr = [x / ps for x in p_arr]
    q_arr = [x / qs for x in q_arr]
    m = [(a + b) / 2.0 for a, b in zip(p_arr, q_arr)]
    kl_pm = sum(a * math.log(a / c) for a, c in zip(p_arr, m) if a > 0)
    kl_qm = sum(b * math.log(b / c) for b, c in zip(q_arr, m) if b > 0)
    return 0.5 * (kl_pm + kl_qm)


def _normalize(counter: Counter) -> dict[str, float]:
    total = sum(counter.values())
    if total == 0:
        return {}
    return {k: v / total for k, v in counter.items()}


def audit(baseline_path: Path, perturbed_path: Path,
          npc_filter: str | None, max_kl: float) -> dict:
    b = _verb_distribution(baseline_path, npc_filter)
    p = _verb_distribution(perturbed_path, npc_filter)
    common = set(b.keys()) & set(p.keys())
    if not common:
        return {"verdict": "skip", "reason": "no overlapping NPCs", "baseline_npcs": list(b),
                "perturbed_npcs": list(p)}
    results: dict[str, dict] = {}
    overall_max_kl = 0.0
    any_fail = False
    for npc in sorted(common):
        p_norm = _normalize(b[npc])
        q_norm = _normalize(p[npc])
        kl = _jensen_shannon(p_norm, q_norm)
        ok = kl <= max_kl
        if not ok:
            any_fail = True
        overall_max_kl = max(overall_max_kl, kl)
        results[npc] = {
            "baseline_samples": sum(b[npc].values()),
            "perturbed_samples": sum(p[npc].values()),
            "jensen_shannon": float(kl),
            "verdict": "pass" if ok else "fail",
        }
    return {
        "verdict": "fail" if any_fail else "pass",
        "max_kl_observed": float(overall_max_kl),
        "max_kl_threshold": float(max_kl),
        "per_npc": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="F8 magnitude-sensitivity probe")
    parser.add_argument("baseline", help="Baseline trace jsonl")
    parser.add_argument("perturbed", help="Perturbed trace jsonl (e.g. 2x reward magnitudes)")
    parser.add_argument("--npc", default=None, help="Filter to one NPC")
    parser.add_argument("--max-kl", type=float, default=None,
                        help="Override max Jensen-Shannon distance (default: from constants)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    b_path = Path(args.baseline)
    p_path = Path(args.perturbed)
    for path in (b_path, p_path):
        if not path.exists():
            print(f"ERROR: {path} not found", file=sys.stderr)
            return 2

    max_kl = args.max_kl if args.max_kl is not None else _load_max_kl()
    result = audit(b_path, p_path, args.npc, max_kl)

    if args.quiet:
        print(f"{result['verdict'].upper()}  max_kl={result.get('max_kl_observed', 0.0):.4f}  "
              f"threshold={result.get('max_kl_threshold', 0.0):.4f}  "
              f"npcs={len(result.get('per_npc', {}))}")
    else:
        print(json.dumps(result, indent=2, default=str))

    if result["verdict"] == "fail":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
