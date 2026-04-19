"""Phase 8 F5 — maturity classifier unit tests.

Verifies:
- All three thresholds (compound_count, appr_identity count, mean_drift)
  must be met for a record to be mature.
- Any single failing threshold blocks maturity (reasons_failed populated).
- Timeline detects first_mature_ts correctly across a stream of records.
- iter_mature_records strips pre-maturity samples.

Run:
    python3 tests/test_maturity_classifier.py
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "training" / "cognitive"))

from maturity_classifier import (  # noqa: E402
    evaluate_record, build_timeline, iter_mature_records,
    MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT,
)


def _rec(ts: float, compound_count: int, n_identity: int, mean_drift: float, npc="hugo") -> dict:
    active = [{"id": f"appr_identity_ent_{i}", "activation": 50.0} for i in range(n_identity)]
    drift_counts = {}
    for i in range(n_identity):
        drift_counts[f"appr_identity_ent_{i}"] = int(mean_drift)
    return {
        "type": "thought",
        "ts": ts,
        "npc": npc,
        "compounds_state": {"active": {}, "count": compound_count},
        "active_appraisals": active,
        "appraisal_drift_counts": drift_counts,
    }


def test_all_thresholds_required(failures: list[str]) -> None:
    # Below compound threshold — blocks even with identity+drift satisfied.
    ev = evaluate_record(_rec(0, MIN_COMPOUND_NEURONS - 1, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT))
    if ev.is_mature:
        failures.append("is_mature True despite compound_count below threshold")
    elif not any("compound_count" in r for r in ev.reasons_failed):
        failures.append(f"expected compound_count reason, got {ev.reasons_failed}")
    # Below identity threshold.
    ev = evaluate_record(_rec(0, MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY - 1, MIN_MEAN_DRIFT))
    if ev.is_mature:
        failures.append("is_mature True despite appr_identity below threshold")
    # Below drift threshold.
    ev = evaluate_record(_rec(0, MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT - 1))
    if ev.is_mature:
        failures.append("is_mature True despite mean_drift below threshold")
    print("  PASS  every single threshold failure blocks maturity")


def test_all_thresholds_met_is_mature(failures: list[str]) -> None:
    ev = evaluate_record(_rec(0, MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT))
    if not ev.is_mature:
        failures.append(f"is_mature False despite all thresholds met: {ev.reasons_failed}")
    elif ev.reasons_failed:
        failures.append(f"mature record has non-empty reasons_failed: {ev.reasons_failed}")
    else:
        print(f"  PASS  all thresholds met → is_mature (compound={ev.compound_count}, "
              f"identity={ev.appr_identity_count}, drift={ev.mean_drift:.1f})")


def test_timeline_first_mature_ts(failures: list[str]) -> None:
    records = [
        _rec(0,  2, 1, 10),  # pre
        _rec(1,  4, 2, 20),  # pre
        _rec(2,  MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT),   # mature (crossover)
        _rec(3,  MIN_COMPOUND_NEURONS + 1, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT + 10),  # post
    ]
    tl = build_timeline("hugo", records)
    if tl.first_mature_ts != 2.0:
        failures.append(f"first_mature_ts expected 2.0, got {tl.first_mature_ts}")
    if tl.pre_maturity_samples != 2:
        failures.append(f"pre count expected 2, got {tl.pre_maturity_samples}")
    if tl.post_maturity_samples != 2:
        failures.append(f"post count expected 2, got {tl.post_maturity_samples}")
    print("  PASS  timeline finds crossover + splits pre/post counts")


def test_iter_mature_records_strips_cold(failures: list[str]) -> None:
    records = [
        _rec(0,  1, 0, 5),   # pre
        _rec(1,  MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT),   # first mature
        _rec(2,  1, 0, 5),   # dip (still counts as mature post-crossover per plan)
        _rec(3,  MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT),   # post
    ]
    mature = iter_mature_records(records)
    if len(mature) != 3:
        failures.append(f"post-crossover count expected 3 (latching), got {len(mature)}")
    if mature[0]["ts"] != 1:
        failures.append(f"first mature ts expected 1, got {mature[0]['ts']}")
    print("  PASS  iter_mature_records latches on crossover (dips don't revert)")


def test_cold_start_timeline(failures: list[str]) -> None:
    records = [
        _rec(0,  1, 0, 5),
        _rec(1,  2, 1, 10),
        _rec(2,  3, 2, 20),
    ]
    tl = build_timeline("hugo", records)
    if tl.first_mature_ts is not None:
        failures.append(f"cold-start timeline has first_mature_ts={tl.first_mature_ts}")
    if tl.pre_maturity_samples != 3:
        failures.append(f"cold-start pre count expected 3, got {tl.pre_maturity_samples}")
    print("  PASS  cold-start timeline: first_mature_ts=None, all samples pre")


def main() -> int:
    failures: list[str] = []
    test_all_thresholds_required(failures)
    test_all_thresholds_met_is_mature(failures)
    test_timeline_first_mature_ts(failures)
    test_iter_mature_records_strips_cold(failures)
    test_cold_start_timeline(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
