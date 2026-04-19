"""Phase 10 acceptance — temporal-texture neurogenesis.

Plan acceptance:
  - §5.5: after 15-min session with ≥5 approach + ≥5 dwell events, ≥2
    temporal-texture neurons per being.
  - Decoded tokens reflect temporal character (lingering, approaching fast).

A "dwell event" = a period of sustained-high visibility on one entity; each
period that stays above threshold for temporal_persistence_seconds counts
as one (and spawns q_lingering_{eid}). Similarly for approach events. The
spawn rule guarantees each sustained period spawns one compound — so
≥5 sustained dwell periods across distinct eids → ≥5 q_lingering_* neurons
(plus any q_approaching_fast_*).

This test mirrors the Hebbian rule in Python (same approach as
test_phase9_acceptance) and verifies:
- After simulating 5 sustained dwell periods on distinct eids, ≥5 lingering
  compounds exist (acceptance floor is ≥2).
- Discontinuous dwell does NOT trigger spawn.
- `perception.render` surfaces "lingering"/"approaching_fast" inline tokens
  for active eids, matching spec §5.5's "decoded tokens reflect temporal
  character".

Run:
    python3 tests/test_phase10_acceptance.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from perception import render  # noqa: E402


def _consts() -> dict:
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        return json.load(f)["neurogenesis_thresholds"]


class TemporalSim:
    """Python mirror of hebbian_network.gd's temporal-texture spawn rule.
    Not a replacement for the Godot test — that covers live wiring — but
    this one verifies the SPEC SHAPE of the rule is correct (failure here =
    spec defect, even if the engine passes)."""

    def __init__(self, persistence_s: float, dwell_min: float, rate_min: float):
        self.persistence = persistence_s
        self.dwell_min = dwell_min
        self.rate_min = rate_min
        self.tracker: dict[str, dict] = {}  # eid -> counters
        self.spawned: set[str] = set()  # "{kind}:{eid}"

    def tick(self, dt: float, dwells: dict[str, float], rates: dict[str, float]) -> list[str]:
        """Apply one brain tick. Returns list of newly-spawned "{kind}:{eid}"."""
        new_spawns: list[str] = []
        for eid in set(dwells.keys()) | set(rates.keys()):
            tr = self.tracker.setdefault(eid, {"lingering_secs": 0.0, "approaching_secs": 0.0})
            d = dwells.get(eid, 0.0)
            r = rates.get(eid, 0.0)
            if d >= self.dwell_min:
                tr["lingering_secs"] += dt
            else:
                tr["lingering_secs"] = 0.0
            if r >= self.rate_min:
                tr["approaching_secs"] += dt
            else:
                tr["approaching_secs"] = 0.0
            if tr["lingering_secs"] >= self.persistence:
                key = f"lingering:{eid}"
                if key not in self.spawned:
                    self.spawned.add(key); new_spawns.append(key)
            if tr["approaching_secs"] >= self.persistence:
                key = f"approaching_fast:{eid}"
                if key not in self.spawned:
                    self.spawned.add(key); new_spawns.append(key)
        return new_spawns


def test_five_dwell_events_across_eids(failures: list[str]) -> None:
    c = _consts()
    sim = TemporalSim(
        persistence_s=float(c["temporal_persistence_seconds"]),
        dwell_min=float(c["temporal_dwell_min"]),
        rate_min=float(c["temporal_rate_min"]),
    )
    # 5 distinct eids each sustain high dwell for 10 seconds (> 8s floor).
    dt = 0.5
    eids = [f"ent_{i}" for i in range(5)]
    for _ in range(int(10.0 / dt)):
        sim.tick(dt, {e: 60.0 for e in eids}, {e: 0.0 for e in eids})
    lingering = [k for k in sim.spawned if k.startswith("lingering:")]
    if len(lingering) < 5:
        failures.append(f"expected ≥5 lingering spawns, got {len(lingering)}: {lingering}")
    else:
        print(f"  PASS  5 sustained dwell periods → {len(lingering)} q_lingering compounds")


def test_five_approach_events_across_eids(failures: list[str]) -> None:
    c = _consts()
    sim = TemporalSim(
        persistence_s=float(c["temporal_persistence_seconds"]),
        dwell_min=float(c["temporal_dwell_min"]),
        rate_min=float(c["temporal_rate_min"]),
    )
    eids = [f"ent_a{i}" for i in range(5)]
    dt = 0.5
    for _ in range(int(10.0 / dt)):
        sim.tick(dt, {e: 0.0 for e in eids}, {e: 1.5 for e in eids})
    approaching = [k for k in sim.spawned if k.startswith("approaching_fast:")]
    if len(approaching) < 5:
        failures.append(f"expected ≥5 approach spawns, got {len(approaching)}: {approaching}")
    else:
        print(f"  PASS  5 sustained approach periods → {len(approaching)} q_approaching compounds")


def test_fifteen_minute_session_floor(failures: list[str]) -> None:
    """Plan acceptance: after 15-min session with ≥5 approach + ≥5 dwell
    events, ≥2 temporal-texture neurons per being. We give each being a
    mix — ≥2 is a low bar that should trivially pass."""
    c = _consts()
    sim = TemporalSim(
        persistence_s=float(c["temporal_persistence_seconds"]),
        dwell_min=float(c["temporal_dwell_min"]),
        rate_min=float(c["temporal_rate_min"]),
    )
    # Simulate 15 wall-clock minutes at 2Hz (900 seconds × 2 ticks/s = 1800 ticks).
    # Each 10-second block: different eid scenario rotating through dwell and
    # approach to get ≥5 events of each.
    dt = 0.5
    events_produced = 0
    eids_cycle = [f"ent_b{i}" for i in range(10)]
    ei = 0
    t = 0.0
    while t < 900.0:
        # Block: one eid sustained for 10 seconds (produces one event).
        block_end = t + 10.0
        eid = eids_cycle[ei % len(eids_cycle)]
        # Alternate between lingering and approaching blocks to cover both.
        use_dwell = (ei % 2 == 0)
        while t < block_end:
            dwells = {eid: 60.0 if use_dwell else 0.0}
            rates = {eid: 1.2 if not use_dwell else 0.0}
            sim.tick(dt, dwells, rates)
            t += dt
        events_produced += 1
        ei += 1

    total = len(sim.spawned)
    if total < 2:
        failures.append(f"15-min session produced only {total} temporal neurons (≥ 2 required)")
    else:
        # Also verify BOTH kinds are represented (dwell + approach).
        kinds = {k.split(":")[0] for k in sim.spawned}
        if "lingering" not in kinds or "approaching_fast" not in kinds:
            failures.append(f"15-min session only produced {kinds}; need both")
        else:
            print(f"  PASS  15-min session → {total} temporal neurons, kinds={kinds}")


def test_discontinuous_does_not_spawn(failures: list[str]) -> None:
    c = _consts()
    sim = TemporalSim(
        persistence_s=float(c["temporal_persistence_seconds"]),
        dwell_min=float(c["temporal_dwell_min"]),
        rate_min=float(c["temporal_rate_min"]),
    )
    # Alternate above/below every tick for 20 seconds.
    dt = 0.5
    toggle = True
    for _ in range(int(20.0 / dt)):
        sim.tick(dt, {"ent_x": (60.0 if toggle else 10.0)}, {"ent_x": 0.0})
        toggle = not toggle
    if f"lingering:ent_x" in sim.spawned:
        failures.append("discontinuous dwell spawned lingering (rule broken)")
    else:
        print("  PASS  discontinuous dwell does NOT spawn lingering")


def test_renderer_surfaces_temporal_tokens(failures: list[str]) -> None:
    """§5.5: decoded tokens reflect temporal character. Renderer must inline
    `lingering` / `approaching_fast` for the eid whose temporal compound is
    active, alongside any identity-appraisal decoded tokens."""
    ctx = {
        "visible": [
            {"id": "ent_mabel", "name": "Mabel", "distance": 3, "direction": "north"},
            {"id": "ent_hugo", "name": "Hugo", "distance": 2, "direction": "east"},
        ],
        "visible_objects": [],
        "heard": [],
        "identity_appraisal_decoded": {"ent_mabel": ["warm", "settled"]},
        "temporal": {
            "active": {
                "ent_mabel": {"lingering": 65.0},
                "ent_hugo": {"approaching_fast": 48.0},
            },
            "new_neurons": [],
        },
    }
    text, percepts = render(ctx)
    # Mabel should have "lingering" AND her identity-appraisal tokens inline.
    mabel_line = next((l for l in text.split("\n") if "Mabel" in l), "")
    if "lingering" not in mabel_line:
        failures.append(f"lingering missing from Mabel's line: {mabel_line}")
    if "warm" not in mabel_line:
        failures.append(f"Mabel identity tokens missing when temporal present: {mabel_line}")
    # Hugo should have "approaching_fast".
    hugo_line = next((l for l in text.split("\n") if "Hugo" in l), "")
    if "approaching_fast" not in hugo_line:
        failures.append(f"approaching_fast missing from Hugo's line: {hugo_line}")
    if not failures:
        print("  PASS  renderer inlines temporal tokens per eid (and preserves identity)")


def test_temporal_tokens_bounded_by_density_cap(failures: list[str]) -> None:
    """Phase 7 default token density cap is 3 per eid. Temporal leads
    identity — if an eid has both kinds + >3 identity tokens, the cap
    truncates from the tail."""
    ctx = {
        "visible": [{"id": "e1", "name": "E1", "distance": 3, "direction": "n"}],
        "visible_objects": [],
        "heard": [],
        "identity_appraisal_decoded": {"e1": ["warm", "familiar", "settled", "open"]},
        "temporal": {
            "active": {"e1": {"lingering": 50.0, "approaching_fast": 40.0}},
            "new_neurons": [],
        },
    }
    _text, percepts = render(ctx)
    e1 = next((p for p in percepts if p.name == "E1"), None)
    if e1 is None or not e1.inline_tokens:
        failures.append("E1 percept missing inline tokens")
        return
    # Cap = 3 total. Temporal kinds come first (alphabetical): approaching_fast, lingering.
    if len(e1.inline_tokens) > 3:
        failures.append(f"token density cap violated: {e1.inline_tokens}")
    # Temporal tokens must lead (both present, then one identity token).
    if "approaching_fast" not in e1.inline_tokens or "lingering" not in e1.inline_tokens:
        failures.append(f"temporal tokens did not lead: {e1.inline_tokens}")
    else:
        print(f"  PASS  token cap respected, temporal leads identity ({e1.inline_tokens})")


def main() -> int:
    failures: list[str] = []
    test_five_dwell_events_across_eids(failures)
    test_five_approach_events_across_eids(failures)
    test_fifteen_minute_session_floor(failures)
    test_discontinuous_does_not_spawn(failures)
    test_renderer_surfaces_temporal_tokens(failures)
    test_temporal_tokens_bounded_by_density_cap(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
