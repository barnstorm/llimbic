"""Phase 7 — command_grammar compound-gating + F4 decay tests.

Covers:
- TOUCH only admitted when q_touchable active OR (cold-start fallback AND
  a target is in proximity).
- APPROACH admitted when no q_touchable; blocked when q_touchable is active
  AND fallback coefficient reaches zero.
- At compound_count ≥ N_FALLBACK_RETIRE, fallback_contribution = 0 regardless
  of how many fallback-eligible verbs exist.
- Grammar string contains only the admitted verbs (model can't emit blocked
  verbs under constrained decode).
- Identity-phantom nudge builder produces expected quality-name targets.

Run:
    python3 tests/test_command_grammar_v7.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from command_grammar import build_gbnf, build_gbnf_from_context
from identity_phantom import build_phantom_nudges


def _n_retire() -> int:
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        return int(json.load(f)["n_fallback_retire"])


def test_touch_gated_on_q_touchable(failures: list[str]) -> None:
    # No compound, no proximity, no compounds at all → TOUCH blocked.
    r = build_gbnf(
        visible_entities=["Mabel"], visible_objects=[],
        active_compounds=set(), compound_count=0, in_proximity=False,
    )
    if "TOUCH" in r.verbs_available:
        failures.append("TOUCH admitted without compound and without proximity (cold-start)")
    else:
        print("  PASS  TOUCH blocked when no compound + not in proximity")

    # q_touchable active → TOUCH admitted via compound path.
    r2 = build_gbnf(
        visible_entities=["Mabel"], visible_objects=[],
        active_compounds={"q_touchable"}, compound_count=3, in_proximity=False,
    )
    if "TOUCH" not in r2.verbs_via_compound:
        failures.append(f"TOUCH not admitted via compound path: {r2.verbs_via_compound}")
    else:
        print("  PASS  TOUCH via compound path when q_touchable active")

    # Cold-start fallback: no compound, but in proximity → fallback path.
    r3 = build_gbnf(
        visible_entities=["Mabel"], visible_objects=[],
        active_compounds=set(), compound_count=0, in_proximity=True,
    )
    if "TOUCH" not in r3.verbs_via_fallback:
        failures.append(f"TOUCH not admitted via fallback when in proximity: {r3.verbs_via_fallback}")
    else:
        print("  PASS  TOUCH via fallback when in proximity (cold-start)")


def test_approach_negated_by_q_touchable(failures: list[str]) -> None:
    # No q_touchable → APPROACH admitted.
    r = build_gbnf(
        visible_entities=["Mabel"], visible_objects=[],
        active_compounds=set(), compound_count=0, in_proximity=False,
    )
    if "APPROACH" not in r.verbs_available:
        failures.append("APPROACH should be admitted without q_touchable")
    # q_touchable ACTIVE + mature being (fallback retired) → APPROACH blocked.
    n = _n_retire()
    r2 = build_gbnf(
        visible_entities=["Mabel"], visible_objects=[],
        active_compounds={"q_touchable"}, compound_count=n, in_proximity=True,
    )
    if "APPROACH" in r2.verbs_available:
        failures.append(f"APPROACH admitted while q_touchable fires + mature (expected blocked): {r2.verbs_available}")
    else:
        print("  PASS  APPROACH blocked when q_touchable fires in mature being (§7.3 negation)")


def test_fallback_coefficient_decay(failures: list[str]) -> None:
    n = _n_retire()
    # At count = 0 → coefficient = 1.0
    r0 = build_gbnf(
        visible_entities=["A"], visible_objects=[],
        active_compounds=set(), compound_count=0, in_proximity=True,
    )
    if abs(r0.fallback_coefficient - 1.0) > 1e-9:
        failures.append(f"coef at count=0 expected 1.0, got {r0.fallback_coefficient}")
    # At count = n/2 → 0.5
    r_half = build_gbnf(
        visible_entities=["A"], visible_objects=[],
        active_compounds=set(), compound_count=n // 2, in_proximity=True,
    )
    if abs(r_half.fallback_coefficient - 0.5) > 1e-9:
        failures.append(f"coef at count=N/2 expected 0.5, got {r_half.fallback_coefficient}")
    # At count = n → 0
    r_mature = build_gbnf(
        visible_entities=["A"], visible_objects=[],
        active_compounds=set(), compound_count=n, in_proximity=True,
    )
    if r_mature.fallback_coefficient != 0.0:
        failures.append(f"coef at count=N expected 0, got {r_mature.fallback_coefficient}")
    # At count > n → still 0 (clamped).
    r_over = build_gbnf(
        visible_entities=["A"], visible_objects=[],
        active_compounds=set(), compound_count=n * 2, in_proximity=True,
    )
    if r_over.fallback_coefficient != 0.0:
        failures.append(f"coef at count=2N expected 0, got {r_over.fallback_coefficient}")
    if r_mature.fallback_contribution != 0.0:
        failures.append(f"mature contribution expected 0, got {r_mature.fallback_contribution}")
    else:
        print(f"  PASS  F4 decay: coef 1.0 → 0.5 → 0 at counts 0/N/2/N (N={n})")


def test_grammar_only_admits_admitted(failures: list[str]) -> None:
    # With no compound and not in proximity, TOUCH/INTERACT/OFFER should be
    # absent from the grammar text.
    r = build_gbnf(
        visible_entities=["Mabel"], visible_objects=["oven"],
        carried_items=["bread"], available_items=[],
        active_compounds=set(), compound_count=0, in_proximity=False,
    )
    if '"TOUCH "' in r.gbnf:
        failures.append("GBNF contains TOUCH when it should be blocked")
    if '"INTERACT WITH "' in r.gbnf:
        failures.append("GBNF contains INTERACT when blocked")
    # OFFER: requires q_offerable or fallback + in_proximity. No proximity → blocked.
    if '"OFFER "' in r.gbnf:
        failures.append("GBNF contains OFFER when blocked")
    # APPROACH should be in (q_touchable not active — admitted).
    if '"APPROACH "' not in r.gbnf:
        failures.append("GBNF missing APPROACH (expected — no q_touchable)")
    if not failures:
        print("  PASS  grammar emits only admitted verbs")


def test_build_from_context(failures: list[str]) -> None:
    """End-to-end: build_gbnf_from_context reads compounds payload correctly."""
    ctx = {
        "visible": [{"id": "ent_1", "name": "Alpha"}],
        "visible_objects": [],
        "carried_items": [],
        "available_items": [],
        "known_locations": None,
        "glimpsed_buildings": [],
        "compounds": {
            "active": {"q_touchable": 55.0},
            "count": 3,
        },
    }
    r = build_gbnf_from_context(ctx)
    if "TOUCH" not in r.verbs_via_compound:
        failures.append(f"TOUCH not wired via compound from context path: {r.verbs_via_compound}")
    elif r.fallback_coefficient == 0.0:
        failures.append("fallback coef went to 0 at compound_count=3 < N")
    else:
        print(f"  PASS  build_gbnf_from_context consumes compounds correctly (coef={r.fallback_coefficient:.2f})")


def test_phantom_nudges_match_decoded_tokens(failures: list[str]) -> None:
    nudges = build_phantom_nudges(
        identity_decoded={"ent_mabel": ["tight", "prickling"]},
        active_identity_activations={"appr_identity_ent_mabel": 80.0},
        visible_eids=["ent_mabel"],
    )
    qids = {n["quality_id"] for n in nudges}
    if "q_tight" not in qids or "q_prickling" not in qids:
        failures.append(f"phantom nudges missing expected q_*: {qids}")
    # First-ranked token should have more strength than second.
    by_qid = {n["quality_id"]: n["amount"] for n in nudges}
    if by_qid.get("q_tight", 0) <= by_qid.get("q_prickling", 0):
        failures.append(f"rank-weighted strength wrong: {by_qid}")
    else:
        print(f"  PASS  phantom nudges follow identity decode + rank ({by_qid})")


def test_phantom_no_nudge_when_inactive(failures: list[str]) -> None:
    # Below activation floor → no nudges.
    nudges = build_phantom_nudges(
        identity_decoded={"ent_mabel": ["tight"]},
        active_identity_activations={"appr_identity_ent_mabel": 15.0},  # under 30 floor
        visible_eids=["ent_mabel"],
    )
    if nudges:
        failures.append(f"phantom fired for inactive identity-appraisal: {nudges}")
    else:
        print("  PASS  phantom silent when identity-appraisal below floor")


def main() -> int:
    failures: list[str] = []
    print("test_touch_gated_on_q_touchable:")
    test_touch_gated_on_q_touchable(failures)
    print("test_approach_negated_by_q_touchable:")
    test_approach_negated_by_q_touchable(failures)
    print("test_fallback_coefficient_decay:")
    test_fallback_coefficient_decay(failures)
    print("test_grammar_only_admits_admitted:")
    test_grammar_only_admits_admitted(failures)
    print("test_build_from_context:")
    test_build_from_context(failures)
    print("test_phantom_nudges_match_decoded_tokens:")
    test_phantom_nudges_match_decoded_tokens(failures)
    print("test_phantom_no_nudge_when_inactive:")
    test_phantom_no_nudge_when_inactive(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
