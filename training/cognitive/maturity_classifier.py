"""Phase 8 F5 maturity classifier.

Per docs/perception_implementation_plan.md Phase 8:

    compound_neuron_count     >= min_compound_neurons        (6)
    AND appr_identity_count   >= min_appr_identity           (3)
    AND mean_drift_count_per_appraisal >= min_mean_drift     (50)

All three thresholds live in the `training_maturity` block of
`data/perception_constants.json`. This classifier is the one source of truth
for "is this trace record harvest-eligible?" — the training-data generator,
the F5 CLI probe, and the corpus validator all route through it.

Zero new authored decisions: every threshold reads from constants; the
counts come from substrate state already recorded in trace v2
(`compounds_state.count`, `active_appraisals` filtered to `appr_identity_*`,
`appraisal_drift_counts`).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

_CONSTS_PATH = Path(__file__).resolve().parent.parent.parent / "data" / "perception_constants.json"

try:
    with _CONSTS_PATH.open() as _f:
        _TRAINING_MATURITY = json.load(_f).get("training_maturity", {})
    MIN_COMPOUND_NEURONS = int(_TRAINING_MATURITY.get("min_compound_neurons", 6))
    MIN_APPR_IDENTITY = int(_TRAINING_MATURITY.get("min_appr_identity", 3))
    MIN_MEAN_DRIFT = float(_TRAINING_MATURITY.get("min_mean_drift_per_appraisal", 50))
    SYNTHETIC_TO_REPLAY_RATIO = float(_TRAINING_MATURITY.get("synthetic_to_replay_ratio", 2.0))
except Exception:
    MIN_COMPOUND_NEURONS = 6
    MIN_APPR_IDENTITY = 3
    MIN_MEAN_DRIFT = 50.0
    SYNTHETIC_TO_REPLAY_RATIO = 2.0


@dataclass
class MaturityEvaluation:
    """Per-record maturity evaluation — every threshold check and its input
    values recorded so corpus metadata can audit why a sample was rejected."""
    is_mature: bool
    compound_count: int
    appr_identity_count: int
    mean_drift: float
    reasons_failed: list[str] = field(default_factory=list)


@dataclass
class NPCMaturityTimeline:
    """Per-NPC evaluation across a trace. `first_mature_ts` is the earliest
    timestamp the being crossed all three thresholds; records before that are
    pre-maturity and must NOT enter the training corpus (spec §Phase 8)."""
    npc: str
    first_mature_ts: float | None
    total_samples: int
    pre_maturity_samples: int
    post_maturity_samples: int
    final_compound_count: int
    final_appr_identity_count: int
    final_mean_drift: float


def _count_appr_identity(active_appraisals: dict | list | None) -> int:
    """Tolerate either trace v2 shape. `active_appraisals` is written as a
    list-of-records by trace_logger, but NPCState caches it as a dict
    earlier in the pipeline; the classifier accepts both."""
    if not active_appraisals:
        return 0
    if isinstance(active_appraisals, dict):
        return sum(1 for k in active_appraisals if str(k).startswith("appr_identity_"))
    n = 0
    for entry in active_appraisals:
        if isinstance(entry, dict) and str(entry.get("id", "")).startswith("appr_identity_"):
            n += 1
    return n


def evaluate_record(record: dict) -> MaturityEvaluation:
    """Evaluate one trace record against all three F5 thresholds. Returns
    is_mature=True only if every threshold passes. `reasons_failed` reports
    which gates blocked (empty for mature records)."""
    compounds = record.get("compounds_state") or {}
    compound_count = int(compounds.get("count", 0))

    active = record.get("active_appraisals")
    appr_identity_count = _count_appr_identity(active)

    drift_counts = record.get("appraisal_drift_counts") or {}
    # mean_drift over APPRAISAL neurons only (including identity-appraisals).
    # Empty drift_counts → 0, which will correctly fail the min_drift gate.
    if drift_counts:
        mean_drift = sum(float(v) for v in drift_counts.values()) / len(drift_counts)
    else:
        mean_drift = 0.0

    reasons: list[str] = []
    if compound_count < MIN_COMPOUND_NEURONS:
        reasons.append(f"compound_count={compound_count} < {MIN_COMPOUND_NEURONS}")
    if appr_identity_count < MIN_APPR_IDENTITY:
        reasons.append(f"appr_identity_count={appr_identity_count} < {MIN_APPR_IDENTITY}")
    if mean_drift < MIN_MEAN_DRIFT:
        reasons.append(f"mean_drift={mean_drift:.2f} < {MIN_MEAN_DRIFT}")

    return MaturityEvaluation(
        is_mature=not reasons,
        compound_count=compound_count,
        appr_identity_count=appr_identity_count,
        mean_drift=mean_drift,
        reasons_failed=reasons,
    )


def build_timeline(npc: str, records: list[dict]) -> NPCMaturityTimeline:
    """Walk an NPC's thought-cycle trace in time order and find the first tick
    at which all three thresholds pass. Once crossed, later samples are
    considered mature even if a single tick dips — maturity is latching, not
    instantaneous (the operator/training pipeline can re-confirm sustained
    maturity at harvest time; this classifier just identifies the crossover)."""
    records = sorted(records, key=lambda r: float(r.get("ts", 0.0)))
    first_ts: float | None = None
    pre = 0
    post = 0
    final_eval: MaturityEvaluation | None = None
    for r in records:
        ev = evaluate_record(r)
        final_eval = ev
        if ev.is_mature and first_ts is None:
            first_ts = float(r.get("ts", 0.0))
        if first_ts is None:
            pre += 1
        else:
            post += 1
    return NPCMaturityTimeline(
        npc=npc,
        first_mature_ts=first_ts,
        total_samples=len(records),
        pre_maturity_samples=pre,
        post_maturity_samples=post,
        final_compound_count=final_eval.compound_count if final_eval else 0,
        final_appr_identity_count=final_eval.appr_identity_count if final_eval else 0,
        final_mean_drift=final_eval.mean_drift if final_eval else 0.0,
    )


def iter_mature_records(records: list[dict]) -> list[dict]:
    """Filter a per-NPC record stream down to post-maturity samples only.
    Used by the training-data generator's F5 gate."""
    timeline = build_timeline(records[0].get("npc", "?") if records else "?", records)
    if timeline.first_mature_ts is None:
        return []
    first_ts = timeline.first_mature_ts
    return [r for r in records if float(r.get("ts", 0.0)) >= first_ts]
