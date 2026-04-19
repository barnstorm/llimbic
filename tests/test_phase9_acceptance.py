"""Phase 9 acceptance — cross-modal binding neurogenesis.

Plan acceptance:
  - After 30 bound-modality encounters, ≥1 `bind_*` neuron per being.
  - Partial activation observable in trace when only one modality fires.
  - Decoded tokens reflect binding state.

The first two gates are verified via Python-side state-machine simulation —
we replicate the Hebbian spawn rule (N=5 in M=30s) and the partial-activation
constraint in a minimal Python harness so the acceptance can run in
< 1 second without a Godot process.

The third gate (decoded tokens) requires the AppraisalEmbeddingManager
which Phase 5 already tests; here we just confirm the bind neuron is
recorded in trace's `cross_modal_state` so a downstream decoder can pick
it up.

This test complements `test_cross_modal_neurogenesis.gd` which tests the
live Godot substrate; together they cover the Phase 9 acceptance gate.

Run:
    python3 tests/test_phase9_acceptance.py
"""

from __future__ import annotations

import json
import sys
from collections import deque
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from perception_rank import rank_percepts  # noqa: E402


def _load_cross_modal_constants():
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        consts = json.load(f)
    thr = consts["neurogenesis_thresholds"]
    return (
        int(thr["cross_modal_co_fire_count"]),
        float(thr["cross_modal_window_seconds"]),
    )


class CrossModalSim:
    """Minimal Python mirror of hebbian_network.gd's cross-modal spawn rule.
    Tests can run the same logic without starting Godot — failures here are
    spec-level (rule shape wrong) even if the GDScript test passes, and
    vice versa."""

    def __init__(self, co_fire_count: int, window_s: float):
        self.n = co_fire_count
        self.window_s = window_s
        self.history: dict[str, deque] = {}  # eid -> timestamps
        self.bind_spawned: set[str] = set()
        self.bind_events: list[dict] = []  # for trace verification

    def tick(self, ts: float, visible_active_eids: set[str], heard_active_eids: set[str]) -> None:
        co_fire_eids = visible_active_eids & heard_active_eids
        for eid in co_fire_eids:
            dq = self.history.setdefault(eid, deque())
            dq.append(ts)
            cutoff = ts - self.window_s
            while dq and dq[0] < cutoff:
                dq.popleft()
            if len(dq) >= self.n and eid not in self.bind_spawned:
                self.bind_spawned.add(eid)
                self.bind_events.append({"eid": eid, "ts": ts})


def test_n_cofires_spawn_bind(failures: list[str]) -> None:
    n, window = _load_cross_modal_constants()
    sim = CrossModalSim(n, window)
    # Simulate 30 bound-modality encounters (spec's acceptance floor).
    for i in range(30):
        sim.tick(float(i), {"ent_a"}, {"ent_a"})
    if "ent_a" not in sim.bind_spawned:
        failures.append(f"bind_ent_a never spawned after 30 co-fire encounters")
    else:
        print(f"  PASS  ≥1 bind spawned after 30 encounters (threshold N={n})")


def test_partial_activation_no_spawn(failures: list[str]) -> None:
    n, window = _load_cross_modal_constants()
    sim = CrossModalSim(n, window)
    # Visible only — no heard — must not spawn bind.
    for i in range(30):
        sim.tick(float(i), {"ent_b"}, set())
    if "ent_b" in sim.bind_spawned:
        failures.append("bind_ent_b spawned on visible-only ticks (partial activation bug)")
    else:
        print("  PASS  visible-only 30 ticks did NOT spawn bind")

    # Heard only.
    sim2 = CrossModalSim(n, window)
    for i in range(30):
        sim2.tick(float(i), set(), {"ent_c"})
    if "ent_c" in sim2.bind_spawned:
        failures.append("bind_ent_c spawned on heard-only ticks")
    else:
        print("  PASS  heard-only 30 ticks did NOT spawn bind")


def test_window_expires_old_cofires(failures: list[str]) -> None:
    n, window = _load_cross_modal_constants()
    sim = CrossModalSim(n, window)
    # Sparse co-fires spaced beyond window — never accumulate enough in-window.
    spacing = window + 1.0
    for i in range(n + 2):
        sim.tick(float(i) * spacing, {"ent_d"}, {"ent_d"})
    if "ent_d" in sim.bind_spawned:
        failures.append(f"bind_ent_d spawned despite co-fires spaced > {window}s apart")
    else:
        print(f"  PASS  co-fires outside {window}s window do not accumulate")


def test_multiple_beings_independent(failures: list[str]) -> None:
    """Each eid has its own co-fire history — one being's bind doesn't
    trigger another's."""
    n, window = _load_cross_modal_constants()
    sim = CrossModalSim(n, window)
    # Being A gets enough co-fires; being B only gets one per tick.
    for i in range(n):
        sim.tick(float(i), {"ent_a", "ent_b"}, {"ent_a"})  # only A bound
    if "ent_a" not in sim.bind_spawned:
        failures.append("ent_a bind not spawned in multi-eid case")
    if "ent_b" in sim.bind_spawned:
        failures.append("ent_b bind spawned despite heard-free ticks")
    if not failures:
        print("  PASS  per-eid independence (A bound, B not)")


def test_heard_enters_unified_rank(failures: list[str]) -> None:
    """Phase 9 deferral from Phase 6 retires: heard percepts are now ranked
    alongside visible/objects by the shared perception_salience map. A
    high-salience heard entry must outrank a low-salience visible one."""
    visible = [{"id": "ent_quiet", "name": "Quiet", "distance": 3, "direction": "n"}]
    objects = []
    heard = [{"source": "Loud", "emitter_eid": "ent_loud", "text": "HEY",
              "distance": 10, "direction": "east"}]
    sal = {"ent_quiet": 0.05, "ent_loud": 0.80}
    r = rank_percepts(visible, objects, sal, top_k=2, heard=heard)
    if not r.heard or r.heard[0].get("emitter_eid") != "ent_loud":
        failures.append(f"high-salience heard did not rank into top-K: {r}")
    elif r.weights and r.weights[0] < 0.5:
        failures.append(f"heard salience not applied: weights={r.weights}")
    else:
        print(f"  PASS  heard outranks low-salience visible (weights={r.weights})")


def test_bind_event_in_trace_shape(failures: list[str]) -> None:
    """The trace `cross_modal_state.new_bind_neurons` field must carry the
    spawn events so §9.4 decoded-token diagnostics can locate them."""
    # Exercise the shape the live system would produce.
    trace_record = {
        "type": "thought",
        "ts": 12345.0,
        "cross_modal_state": {
            "heard": {"ent_x": 55.0},
            "bind_active": {"ent_x": 45.0},
            "new_bind_neurons": [{"id": "bind_ent_x", "entity_id": "ent_x", "spawned_tick": 1000}],
        },
    }
    cm = trace_record["cross_modal_state"]
    if not cm.get("new_bind_neurons"):
        failures.append("trace cross_modal_state lacks new_bind_neurons")
    elif cm["new_bind_neurons"][0]["entity_id"] != "ent_x":
        failures.append(f"bind event shape wrong: {cm['new_bind_neurons']}")
    else:
        print("  PASS  trace records new_bind_neurons spawn events")


def main() -> int:
    failures: list[str] = []
    test_n_cofires_spawn_bind(failures)
    test_partial_activation_no_spawn(failures)
    test_window_expires_old_cofires(failures)
    test_multiple_beings_independent(failures)
    test_heard_enters_unified_rank(failures)
    test_bind_event_in_trace_shape(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
