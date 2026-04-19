"""Phase 7 — flat Percept renderer tests (spec §6.3-6.4).

Verifies:
- Entity vs object rendered identically (no category distinction).
- Inline tokens come from identity_appraisal_decoded and are per-eid.
- Order of rendered lines mirrors input order (which was pre-ranked in Phase 6).
- "You hear: silence" when no heard events; no `Commands:` or verb-hint.

Run:
    python3 tests/test_perception_renderer.py
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from perception import render, build_percepts, render_see_block, render_hear_block


def test_entity_and_object_rendered_same(failures: list[str]) -> None:
    ctx = {
        "visible": [
            {"id": "ent_mabel", "name": "Mabel", "distance": 3, "direction": "north"},
        ],
        "visible_objects": [
            {"id": "obj_oven", "name": "brick oven", "distance": 2, "direction": "east"},
        ],
        "heard": [],
        "identity_appraisal_decoded": {},
    }
    text, percepts = render(ctx)
    # No "a <obj_name>" prefix, no (state), no "tiles away" differential —
    # both lines should follow "{name}, {distance} tiles {direction}".
    if "Mabel, 3 tiles north" not in text:
        failures.append(f"entity line wrong: {text}")
    if "brick oven, 2 tiles east" not in text:
        failures.append(f"object line wrong: {text}")
    if " - a brick oven" in text:
        failures.append(f"object rendered with 'a ' prefix (category distinction): {text}")
    if text.count("feels:") != 0:
        failures.append(f"inline tokens injected with empty decode: {text}")
    else:
        print("  PASS  entity and object render identically (spec §6.4)")


def test_inline_tokens_from_identity_decode(failures: list[str]) -> None:
    ctx = {
        "visible": [
            {"id": "ent_mabel", "name": "Mabel", "distance": 3, "direction": "north"},
            {"id": "ent_roland", "name": "Roland", "distance": 5, "direction": "south"},
        ],
        "visible_objects": [],
        "heard": [],
        "identity_appraisal_decoded": {
            "ent_mabel": ["warm", "familiar", "settled"],
            # ent_roland has no identity-appraisal yet — no inline tokens
        },
    }
    text, _ = render(ctx)
    if "feels: warm, familiar, settled" not in text:
        failures.append(f"Mabel's decoded tokens not inlined: {text}")
    # Roland line should have no feels: suffix.
    lines = [l for l in text.split("\n") if "Roland" in l]
    if lines and "feels:" in lines[0]:
        failures.append(f"Roland got inline tokens without identity appraisal: {lines[0]}")
    if "feels: warm, familiar, settled" in text and lines and "feels:" not in lines[0]:
        print("  PASS  inline tokens only for eids with identity-appraisal decode")


def test_hear_silence(failures: list[str]) -> None:
    text = render_hear_block([])
    if "silence" not in text:
        failures.append(f"empty heard should render 'silence', got: {text}")
    else:
        print("  PASS  empty heard → silence")


def test_hear_populated(failures: list[str]) -> None:
    heard = [{"source": "Hugo", "text": "who goes there", "distance": 6, "direction": "west"}]
    text = render_hear_block(heard)
    if '"who goes there"' not in text or "Hugo" not in text:
        failures.append(f"heard rendering wrong: {text}")
    else:
        print("  PASS  heard rendering includes source + speech")


def test_no_commands_line_leaks(failures: list[str]) -> None:
    ctx = {"visible": [], "visible_objects": [], "heard": []}
    text, _ = render(ctx)
    if "Commands:" in text or "TOUCH grounds" in text:
        failures.append(f"verb-hint / commands line leaked into renderer: {text}")
    else:
        print("  PASS  renderer emits only §6.4 You see/You hear blocks")


def test_percepts_preserve_input_order(failures: list[str]) -> None:
    """The Percept list is the rendered order; Phase 6 pre-ranking produces
    `visible` then `visible_objects`, both already sorted by propagation
    weight. The renderer doesn't re-sort — order comes from the ranking."""
    ctx = {
        "visible": [
            {"id": "ent_1", "name": "First", "distance": 1, "direction": "n"},
            {"id": "ent_2", "name": "Second", "distance": 2, "direction": "n"},
        ],
        "visible_objects": [
            {"id": "obj_3", "name": "Third", "distance": 3, "direction": "n"},
        ],
        "heard": [],
        "identity_appraisal_decoded": {},
    }
    percepts = build_percepts(ctx)
    names = [p.name for p in percepts]
    if names != ["First", "Second", "Third"]:
        failures.append(f"percept order lost: {names}")
    else:
        print("  PASS  renderer preserves pre-ranked input order")


def main() -> int:
    failures: list[str] = []
    print("test_entity_and_object_rendered_same:")
    test_entity_and_object_rendered_same(failures)
    print("test_inline_tokens_from_identity_decode:")
    test_inline_tokens_from_identity_decode(failures)
    print("test_hear_silence:")
    test_hear_silence(failures)
    print("test_hear_populated:")
    test_hear_populated(failures)
    print("test_no_commands_line_leaks:")
    test_no_commands_line_leaks(failures)
    print("test_percepts_preserve_input_order:")
    test_percepts_preserve_input_order(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
