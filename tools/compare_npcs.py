"""tools/compare_npcs.py — Phase 12 cross-being diff.

Per docs/perception_implementation_plan.md Phase 12: this is the unifying
analysis tool for §9.3 (decay) and §9.4 (emergence) metrics. Given a trace
file (optionally with `saves/{npc}/appraisals.json` persisted embeddings
alongside), it computes:

  Per-NPC:
  - verb distribution
  - mean/min attention entropy (F6)
  - mean fallback contribution (F4)
  - compound count (F4/F10 maturity surface)
  - identity-appraisal count + drift summary
  - intention bootstrap variance summary (F11)

  Pairwise (across NPCs in the trace):
  - Jensen-Shannon divergence on verb distributions (§9.4 diversity)
  - appraisal-embedding silhouette (if saves/ directory provided)
  - Hebbian-graph Frobenius distance between aligned adjacency matrices
    (requires a `--graph-dump` jsonl with per-NPC connections; optional)

The tool is read-only — it never mutates a trace or save file. Exit 0 on
successful analysis (no acceptance-level verdict here; use the individual
probes for gate verdicts).

Usage:
    python3 tools/compare_npcs.py --trace <path.jsonl> [--saves <dir>]
                                  [--top-verbs 10]

Example workflow (post-deploy check on a 2-being run):
    python3 tools/compare_npcs.py --trace trace_phase13.jsonl --saves saves/
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter, defaultdict
from itertools import combinations
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


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


def _jensen_shannon(p: dict[str, float], q: dict[str, float]) -> float:
    """Symmetric divergence; 0 = identical distributions, ln(2) = maximal."""
    keys = set(p.keys()) | set(q.keys())
    if not keys:
        return 0.0
    eps = 1e-9
    p_arr = [p.get(k, 0.0) + eps for k in keys]
    q_arr = [q.get(k, 0.0) + eps for k in keys]
    ps, qs = sum(p_arr), sum(q_arr)
    p_arr = [x / ps for x in p_arr]
    q_arr = [x / qs for x in q_arr]
    m = [(a + b) / 2.0 for a, b in zip(p_arr, q_arr)]
    kl_pm = sum(a * math.log(a / c) for a, c in zip(p_arr, m) if a > 0)
    kl_qm = sum(b * math.log(b / c) for b, c in zip(q_arr, m) if b > 0)
    return 0.5 * (kl_pm + kl_qm)


def _normalize(counter: Counter | dict) -> dict[str, float]:
    total = sum(counter.values())
    if total == 0:
        return {}
    return {k: v / total for k, v in counter.items()}


def _cosine(a, b) -> float:
    import numpy as np
    na = np.linalg.norm(a); nb = np.linalg.norm(b)
    if na < 1e-9 or nb < 1e-9:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


def analyze_trace(trace_path: Path, top_verbs: int) -> dict:
    """Per-NPC rollup of metrics that can be computed from a trace alone."""
    per_npc: dict[str, dict] = {}
    verb_counts: dict[str, Counter] = defaultdict(Counter)
    entropy_samples: dict[str, list[float]] = defaultdict(list)
    fallback_samples: dict[str, list[float]] = defaultdict(list)
    compound_counts_seen: dict[str, set[int]] = defaultdict(set)
    appr_ids_seen: dict[str, set[str]] = defaultdict(set)
    identity_drift_last: dict[str, dict[str, int]] = defaultdict(dict)
    intention_cv_last: dict[str, dict[str, float]] = defaultdict(dict)

    total_records = 0
    for rec in iter_thought_records(trace_path):
        total_records += 1
        npc = str(rec.get("npc", "?"))

        # Verb distribution.
        cmd = str(rec.get("command", "")).strip()
        if cmd:
            verb_counts[npc][cmd.split()[0]] += 1

        # F6 entropy.
        ae = rec.get("attention_entropy") or {}
        tick_h = ae.get("tick")
        if isinstance(tick_h, (int, float)):
            entropy_samples[npc].append(float(tick_h))

        # F4 fallback.
        fc = rec.get("fallback_contribution_per_tick")
        if isinstance(fc, (int, float)):
            fallback_samples[npc].append(float(fc))

        # F4 compound count (F5 maturity surface too).
        cs = rec.get("compounds_state") or {}
        if "count" in cs:
            compound_counts_seen[npc].add(int(cs["count"]))

        # Active appraisals (identity-appraisal count is the subset starting with appr_identity_).
        active = rec.get("active_appraisals") or []
        for entry in active:
            nid = str(entry.get("id", "") if isinstance(entry, dict) else entry)
            if nid:
                appr_ids_seen[npc].add(nid)

        # Drift counts (Phase 8 F5 field).
        drift = rec.get("appraisal_drift_counts") or {}
        for nid, count in drift.items():
            identity_drift_last[npc][str(nid)] = int(count)

        # Intention bootstrap variance (Phase 11 F11 field).
        istate = rec.get("intention_state") or {}
        cvs = istate.get("bootstrap_variance") or {}
        for iid, cv in cvs.items():
            intention_cv_last[npc][str(iid)] = float(cv)

    for npc in verb_counts.keys() | entropy_samples.keys():
        e = entropy_samples.get(npc, [])
        f = fallback_samples.get(npc, [])
        drift = identity_drift_last.get(npc, {})
        cvs = intention_cv_last.get(npc, {})
        appr_ids = appr_ids_seen.get(npc, set())
        identity_count = sum(1 for nid in appr_ids if nid.startswith("appr_identity_"))
        per_npc[npc] = {
            "records": sum(verb_counts.get(npc, Counter()).values()),
            "top_verbs": verb_counts.get(npc, Counter()).most_common(top_verbs),
            "mean_attention_entropy": (sum(e) / len(e)) if e else None,
            "min_attention_entropy": min(e) if e else None,
            "mean_fallback_contribution": (sum(f) / len(f)) if f else None,
            "compound_count_seen_max": max(compound_counts_seen.get(npc, {0})),
            "appr_total_seen": len(appr_ids),
            "appr_identity_seen": identity_count,
            "mean_drift_per_appraisal": (sum(drift.values()) / len(drift)) if drift else 0.0,
            "intention_cv_min": min(cvs.values()) if cvs else None,
            "intention_cv_mean": (sum(cvs.values()) / len(cvs)) if cvs else None,
            "intention_context_count": len(cvs),
        }
    return {"total_records": total_records, "per_npc": per_npc, "verb_counts_raw": verb_counts}


def pairwise_verb_divergence(verb_counts: dict[str, Counter]) -> dict[str, float]:
    """Jensen-Shannon divergence on verb distributions between every pair of
    NPCs. Keys are "npc_a|npc_b" (alphabetical)."""
    dists = {npc: _normalize(c) for npc, c in verb_counts.items()}
    out: dict[str, float] = {}
    for a, b in combinations(sorted(dists.keys()), 2):
        out[f"{a}|{b}"] = float(_jensen_shannon(dists[a], dists[b]))
    return out


def pairwise_appraisal_silhouette(saves_dir: Path) -> dict[str, float]:
    """Compute pairwise mean appraisal-embedding cosine distance between
    beings that share any `appr_identity_*` neuron IDs in their persisted
    state. Returns {"npc_a|npc_b": mean_cosine_distance}. Requires the
    saves/{npc}/appraisals.json format from Phase 0."""
    import numpy as np
    if not saves_dir.exists():
        return {}
    being_embs: dict[str, dict[str, "np.ndarray"]] = {}
    for sub in sorted(saves_dir.iterdir()):
        appraisal_path = sub / "appraisals.json"
        if not appraisal_path.exists():
            continue
        with appraisal_path.open() as f:
            data = json.load(f)
        neurons = data.get("neurons") or {}
        entries: dict[str, "np.ndarray"] = {}
        for nid, body in neurons.items():
            emb = body.get("embedding")
            if not emb:
                continue
            v = np.asarray(emb, dtype=np.float32)
            n = np.linalg.norm(v)
            if n < 1e-9:
                continue
            entries[str(nid)] = (v / n)
        being_embs[sub.name] = entries

    out: dict[str, float] = {}
    for a, b in combinations(sorted(being_embs.keys()), 2):
        shared = set(being_embs[a].keys()) & set(being_embs[b].keys())
        if not shared:
            continue
        distances = []
        for nid in shared:
            cos = _cosine(being_embs[a][nid], being_embs[b][nid])
            distances.append(1.0 - cos)
        out[f"{a}|{b}"] = float(sum(distances) / len(distances))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Cross-being emergence diff")
    parser.add_argument("--trace", required=True, help="Trace jsonl")
    parser.add_argument("--saves", default=None,
                        help="Optional: saves/ dir with per-being appraisals.json for silhouette")
    parser.add_argument("--top-verbs", type=int, default=10)
    parser.add_argument("--json", action="store_true",
                        help="Emit machine-readable JSON instead of pretty text")
    args = parser.parse_args()

    trace_path = Path(args.trace)
    if not trace_path.exists():
        print(f"ERROR: {trace_path} not found", file=sys.stderr)
        return 2

    rollup = analyze_trace(trace_path, args.top_verbs)
    verb_div = pairwise_verb_divergence(rollup.pop("verb_counts_raw"))
    silhouette: dict[str, float] = {}
    if args.saves:
        try:
            silhouette = pairwise_appraisal_silhouette(Path(args.saves))
        except Exception as e:
            silhouette = {"_error": str(e)}

    report = {
        "total_records": rollup["total_records"],
        "per_npc": rollup["per_npc"],
        "pairwise_verb_jensen_shannon": verb_div,
        "pairwise_appraisal_distance": silhouette,
    }

    if args.json:
        print(json.dumps(report, indent=2, default=str))
        return 0

    print(f"=== Cross-being analysis: {trace_path} ===")
    print(f"Total thought records: {report['total_records']}")
    print(f"NPCs: {len(report['per_npc'])}")
    for npc, m in sorted(report["per_npc"].items()):
        print(f"\n--- {npc} ---")
        for k, v in m.items():
            if isinstance(v, list):
                print(f"  {k}:")
                for item in v:
                    print(f"    {item}")
            else:
                print(f"  {k}: {v}")
    if verb_div:
        print("\nPairwise verb Jensen-Shannon (§9.4 diversity):")
        for pair, d in sorted(verb_div.items()):
            print(f"  {pair}: {d:.4f}")
    if silhouette:
        print("\nPairwise appraisal-embedding distance (§9.2.7 silhouette):")
        for pair, d in sorted(silhouette.items()):
            print(f"  {pair}: {d:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
