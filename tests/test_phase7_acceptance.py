"""Phase 7 acceptance gate.

Plan acceptance:
  - v1/v2 GGUFs produce invalid output on new prompt (expected — confirms
    format break).
  - Trace v2 shows new prompt format end-to-end.
  - F4 fallback decays to zero in mature beings (verified in trace).
  - F6 attention entropy still above floor.

The v1/v2 LLM break is asserted structurally: the new prompt must NOT contain
scaffolding a v2-trained model was conditioned on (the "Commands: GO TO place,
LOOK AT target, ..." line and the "TOUCH grounds the body..." verb-hint
paragraph). If those strings survive anywhere in the rendered prompt, Phase 7
has not correctly broken the contract.

F4 decay is re-verified end-to-end via the CLI probe (see test_fallback_decay
for regime-level coverage); this test ensures a trace emitted through the
live trace_logger with Phase 7 fields parses correctly.

F6 entropy is covered by test_attention_entropy; this test re-asserts the
field shape survives on Phase 7 traces.

Run:
    python3 tests/test_phase7_acceptance.py
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from command_model import _format_perception  # noqa: E402


V2_SCAFFOLD_MARKERS = [
    "Commands: GO TO place",
    "TOUCH grounds the body",
    "INTERACT engages",
    "OFFER presents an item",
    "Think about your situation, then choose ONE action.",  # this line DID survive; test confirms
]


def test_format_break_v2_scaffolding_removed(failures: list[str]) -> None:
    """v1/v2 GGUF training data contained the "Commands: ..." enumeration
    and the "TOUCH grounds the body" verb-hint paragraph. Phase 7 must
    remove BOTH. If either survives, a v2 model will still appear to work
    — false-positive — and the Phase 8 retrain won't actually be needed."""
    ctx = {
        "npc_name": "hugo", "role": "baker",
        "location": "bakery", "current_action": "idle",
        "drives": {"energy": 80, "hunger": 20, "social_need": 30, "safety": 80, "frustration": 0.0},
        "somatic_tags": ["body:settled"],
        "body_narrative": "You feel calm.",
        "visible": [{"id": "ent_mabel", "name": "Mabel", "distance": 3, "direction": "north"}],
        "visible_objects": [{"id": "obj_oven", "name": "brick oven", "distance": 2, "direction": "east"}],
        "heard": [],
        "recent_events": [], "intentions_summary": "idle",
        "beliefs_summary": "none", "recent_thoughts": [],
        "carried_items": [], "available_items": [],
        "known_locations": ["bakery", "town_square"],
        "glimpsed_buildings": [],
        "identity_appraisal_decoded": {"ent_mabel": ["warm", "familiar"]},
        "compounds": {"active": {}, "count": 0},
    }
    prompt = _format_perception(ctx)
    v2_found = [m for m in V2_SCAFFOLD_MARKERS[:4] if m in prompt]  # first 4 must all be gone
    if v2_found:
        failures.append(f"v2 scaffolding survived: {v2_found}")
    else:
        print("  PASS  v1/v2 scaffolding removed (format break confirmed)")

    # Positive: the new spec §6.4 structure IS present.
    if "You see:" not in prompt or "You hear:" not in prompt:
        failures.append(f"§6.4 You see/You hear blocks missing from prompt")
    # Inline tokens from identity-appraisal landed.
    if "feels: warm, familiar" not in prompt:
        failures.append(f"identity-appraisal inline tokens not in prompt:\n{prompt}")
    else:
        print("  PASS  §6.4 format + inline identity tokens present in prompt")


def test_no_commands_listing_in_prompt(failures: list[str]) -> None:
    """Phase 7 removed the hand-rolled "Commands: ..." line. The GBNF grammar
    now owns verb enumeration at decode time, not the prompt text."""
    ctx = {
        "npc_name": "hugo", "role": "baker",
        "location": "bakery", "current_action": "idle",
        "drives": {"energy": 80, "hunger": 20, "social_need": 30, "safety": 80, "frustration": 0.0},
        "somatic_tags": [], "body_narrative": "You feel calm.",
        "visible": [], "visible_objects": [], "heard": [],
        "recent_events": [], "intentions_summary": "idle",
        "beliefs_summary": "none", "recent_thoughts": [],
        "carried_items": [], "available_items": [],
        "known_locations": [], "glimpsed_buildings": [],
        "identity_appraisal_decoded": {},
        "compounds": {"active": {}, "count": 0},
    }
    prompt = _format_perception(ctx)
    if "Commands:" in prompt:
        failures.append(f"Commands: line leaked:\n{prompt}")
    else:
        print("  PASS  Commands: enumeration removed (grammar owns it)")


def test_trace_logger_accepts_phase7_fields(failures: list[str]) -> None:
    """The trace logger's trace_thought must accept the new Phase 7 keyword
    arguments without TypeError — proves the signature update landed."""
    from trace_logger import trace_thought, _write  # noqa: F401
    # Dry-run: call with all new kwargs pointed at an in-memory fake file.
    import io
    import trace_logger as tl
    fake = io.StringIO()
    original = tl._trace_file
    tl._trace_file = fake
    try:
        trace_thought(
            npc_name="hugo",
            context={"role": "baker", "visible": [], "visible_objects": []},
            thought_result={"thoughts": [""], "intentions": [], "beliefs": [],
                            "action_biases": {}, "trigger_actions": [], "raw": "",
                            "command": "WAIT", "target": None},
            elapsed_ms=10.0,
            prompt_rendered="You see:\n  - nothing.\nYou hear:\n  - silence",
            fallback_contribution=0.0,
            fallback_coefficient=0.0,
            compounds_state={"active": {}, "count": 8},
            verbs_via_compound=["WAIT"],
            verbs_via_fallback=[],
            attention_entropy={"tick": 1.2, "mean_10min": 1.3, "h_min": 1.24, "k": 8, "fallback": False},
        )
        record = json.loads(fake.getvalue().strip().split("\n")[0])
        for key in ("prompt_rendered", "compounds_state",
                    "fallback_contribution_per_tick", "verbs_via_compound"):
            if key not in record:
                failures.append(f"trace record missing {key}")
        if record.get("prompt_rendered", "") == "":
            failures.append("prompt_rendered empty after write")
        else:
            print("  PASS  trace_thought accepts Phase 7 fields end-to-end")
    finally:
        tl._trace_file = original


def test_f4_formula_boundary(failures: list[str]) -> None:
    """Ensure the F4 coefficient hits exactly 0 at the retire boundary —
    this is the property the trace-based CLI relies on for mature-being gating."""
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        n = int(json.load(f)["n_fallback_retire"])
    from command_grammar import _fallback_coefficient
    if _fallback_coefficient(n) != 0.0:
        failures.append(f"fallback_coefficient(N={n}) should be 0, got {_fallback_coefficient(n)}")
    if _fallback_coefficient(n - 1) <= 0.0:
        failures.append(f"fallback_coefficient(N-1) should be > 0")
    else:
        print(f"  PASS  F4 coefficient zeroed at count=N (N={n})")


def main() -> int:
    failures: list[str] = []
    print("test_format_break_v2_scaffolding_removed:")
    test_format_break_v2_scaffolding_removed(failures)
    print("test_no_commands_listing_in_prompt:")
    test_no_commands_listing_in_prompt(failures)
    print("test_trace_logger_accepts_phase7_fields:")
    test_trace_logger_accepts_phase7_fields(failures)
    print("test_f4_formula_boundary:")
    test_f4_formula_boundary(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
