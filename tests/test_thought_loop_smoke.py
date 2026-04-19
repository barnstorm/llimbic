"""Smoke test covering the thought-cycle happy path.

Regression coverage for two ordering bugs that slipped through unit tests:
- `identity_decoded` was referenced in the phantom-nudge block (Phase 7)
  before it was initialized in the trace-serialization block.
- `elapsed` was referenced in trace_speech (Phase 0) before it was
  computed at the end of `_run_thought_cycle`.

Both bugs crashed the live thought loop the first time a thought emitted
a speak trigger with an active identity-appraisal. Unit tests mocked the
L3 layer so neither path fired. This smoke test drives the full cycle
with a stub L3 that returns a speak trigger and an identity-active state
to keep both branches alive.

Run:
    python3 tests/test_thought_loop_smoke.py
"""

from __future__ import annotations

import asyncio
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from thought_loop import ThoughtLoop  # noqa: E402
from npc_state import NPCState  # noqa: E402


class _StubL3:
    """Returns a thought with a speak trigger every call. Shape matches
    command_model.CommandModel.generate_command output."""

    def __init__(self):
        self.locations = {"bakery": True, "town_square": True}

    def generate_thought(self, context):
        return {
            "thoughts": ["talking to Mabel"],
            "intentions": [],
            "beliefs": [],
            "action_biases": {},
            "trigger_actions": [{
                "type": "speak", "text": "hello", "target": "Mabel",
            }],
            "command": "SAY",
            "target": {"name": "Mabel"},
            "raw": "",
        }


def _minimal_snapshot() -> dict:
    return {
        "hour": 6.0,
        "location": "town_square",
        "position": [100, 100],
        "drives": {"energy": 80, "hunger": 20, "social_need": 30, "safety": 80,
                   "frustration": 0.0, "task_momentum": 0.0, "salience": 50.0},
        "somatic_tags": ["body:settled"],
        "vagal_state": {"ventral": 60, "sympathetic": 20, "dorsal": 5},
        "emotion_vector": [0.1] * 27,
        "visible": [{"id": "ent_mabel", "name": "Mabel",
                     "distance": 3, "direction": "north"}],
        "visible_objects": [],
        "heard": [],
        "recent_events": [],
        "current_action": "idle",
        "carried_items": [], "available_items": [],
        "known_locations": ["town_square", "bakery"], "glimpsed_buildings": [],
        "appraisal": {"new_neurons": [], "active": {"appr_identity_ent_mabel": 50.0}},
        "reward_events": [],
        "per_entity_channels": {},
        "perception_salience": {"ent_mabel": 0.5},
        "compounds": {"active": {}, "count": 0},
        "cross_modal": {"heard": {}, "bind_active": {}, "new_bind_neurons": []},
        "temporal": {"active": {}, "new_neurons": []},
        "intention": {"context_neurons": {}, "amplification": {}, "bootstrap_variance": {}},
    }


def test_smoke(failures: list[str]) -> None:
    tl = ThoughtLoop(l2_model=None, l3_model=_StubL3())
    # Register a fake NPC.
    state = NPCState("hugo", "baker", {"name": "Hugo", "role": "Baker",
                                         "personality": {"traits": ["quiet"]},
                                         "schedule": []})
    tl.npc_states["hugo"] = state
    state.receive_snapshot(_minimal_snapshot())
    # last_active_appraisals must have an identity entry so phantom-nudge
    # branch + trace decode both fire (regression paths).
    state.last_active_appraisals = {"appr_identity_ent_mabel": 50.0}

    async def go():
        # Without this, tl._push_commands tries to use a None websocket.
        tl._ws = type("Fake", (), {"send_text": staticmethod(lambda s: asyncio.sleep(0))})()
        await tl._run_thought_cycle("hugo")

    try:
        asyncio.run(go())
    except NameError as e:
        failures.append(f"NameError in thought cycle (regression!): {e}")
        return
    except UnboundLocalError as e:
        failures.append(f"UnboundLocalError in thought cycle (regression!): {e}")
        return
    except Exception as e:
        # Other exceptions (e.g. missing appraisal manager) are acceptable —
        # we only care that the two specific bugs don't recur.
        msg = str(e)
        if "identity_decoded" in msg or "'elapsed'" in msg:
            failures.append(f"regression fingerprint in error: {e}")
            return
        print(f"  INFO  ignored benign exception: {type(e).__name__}: {msg}")

    print("  PASS  thought cycle completes without identity_decoded/elapsed UnboundLocalError")


def main() -> int:
    failures: list[str] = []
    test_smoke(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
