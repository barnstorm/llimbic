# Grounded External-Mind Protocol — burg (body) ↔ LCAEC (mind)

This is the wire + design contract for **external control** of burg's NPCs by an
external "mind" called **LCAEC** (a separate project, `~/devel/LCAEC`). burg is
demoted to a pure **I/O boundary**: the body emits MEASURED observations and
applies MOTOR actions over a WebSocket; for controlled NPCs the in-Godot
cognitive stack (Layer 1 substrate, Layer 2 projection, Layer 3 executive,
Hebbian network) is **bypassed**. Uncontrolled NPCs keep their own cognition
unchanged.

Everything here is **descriptive of the implementation** in `scripts/mind_link.gd`,
`scripts/scenario_runner.gd`, `scripts/behavior_recorder.gd`, and the external-mind
branch of `scripts/npc_controller.gd`. Those files are authoritative; this doc
exists so the §-citations in the code resolve. `tools/export_hebbian_golden*.gd`
emit golden fixtures consumed by LCAEC's P2 Hebbian-port parity tests.

**Scope of control.** The mind selects *velocity* and *interaction primitives*
that mutate drives only as body-side world side-effects. It can never write a
drive/emotion/intention value directly — there is no such wire field (§8).

| Role | Process | Direction | Authority |
|------|---------|-----------|-----------|
| Body | burg (Godot) | emits `obs`, applies `act` | owns the physics world |
| Mind | LCAEC (Python) | emits `act`, may push `episode`/`step` | owns decisions for controlled NPCs |

---

## §1 Overview & roles

External control turns burg into a **body**: a sensing+actuating surface for a
mind that lives elsewhere. The contract is a closed loop — sensor → observation
→ mind → action → actuator → sensor — forced to be *grounded*: the mind perceives
only what a body would measure and acts only through a motor surface (§8). For
each controlled NPC, per physics tick: keep perception (a sensor, not
cognition), build one observation, send it, apply the returned action, and
bypass the in-Godot brain. Perception, pathfinding-adjacent safety bounds, and
animation stay body-side; deliberation leaves.

---

## §2 Dormancy & env-arming

External control is **off by default** — burg runs exactly as the standalone
game. Each subsystem arms on an environment variable; with the var unset it does
nothing, sets no process, and `is_active()` stays false:

| Env var | Subsystem | Effect when set |
|---------|-----------|-----------------|
| `BURG_MIND_URL` | `MindLink` autoload | Connect to the mind; controlled NPCs enter external mode |
| `BURG_SCENARIO` | `ScenarioRunner` autoload | Load a scenario JSON; fire disturbances at exact ticks |
| `BURG_BEHAVIOR_LOG` | `BehaviorRecorder` autoload | Stream one CSV row/sec/NPC |

Default mind URL: `ws://127.0.0.1:8430/ws` (override with `BURG_MIND_URL`).

---

## §3 Connection & handshake

`MindLink` is a `WebSocketPeer` client with a 3 s reconnect backoff (modeled on
`inference_client.gd`). On `STATE_OPEN` it sends **`hello`**; the run is fixed by
the **`hello_ack`** that replies.

### `hello` (body → mind)
```jsonc
{
  "t": "hello",
  "proto": 3,                       // PROTO_VERSION; bump on any wire change
  "body_id": "burg",
  "npcs": ["Hugo", "Mabel", "..."], // npc_name of every node in group "npcs"
  "action_space": {
    "vel":        { "dim": 2, "unit": "px/s", "max": 112.0 },  // ceiling; per-NPC clamp uses npc.speed
    "primitives": ["consume", "rest", "interact", "face_toward", "speak"]
  },
  "obs_channels": ["kinematics", "vision", "hearing", "drives", "proprio", "clock"],
  "physics_tps": 60,                // Engine.physics_ticks_per_second
  "scenario":  { "id": "...", "hash": "sha256:..." }  // only if ScenarioRunner armed (§8, §13)
}
```

### `hello_ack` (mind → body)
```jsonc
{
  "t": "hello_ack",
  "proto": 3,
  "sync": "lockstep",               // or "free-running"
  "control_npcs": ["Hugo"],         // subset the mind drives; others keep native cognition
  "horizon": 1,                     // receding-horizon depth the body will accept
  "lockstep": { "deadline_ms": 50.0, "on_timeout": "hold_last" },  // "zero_vel" is the alternative
  "allow_speak": false              // v2 per-run gate for the "speak" primitive
}
```

**Versioning.** The body refuses an ack whose `proto != PROTO_VERSION` and stays
inactive; both sides fail loud rather than running half-upgraded. `MindLink` is
not active until `hello_ack` lands on an open socket.

---

## §4 Observation contract

The body emits **only measured channels**, built key-by-key (never a spread of
brain state — §8). One `obs` per controlled NPC per tick:

```jsonc
{
  "t": "obs", "npc": "Hugo", "seq": 42, "t_emit": 1783119659.0,
  "tick": 1234, "dt": 0.0166,            // tick == Engine.get_physics_frames()
  "kinematics": { "pos":[x,y], "vel":[x,y], "heading":[x,y] },
  "vision":  [ { "id":"obj_<sha8>"|"ent_<sha8>", "dist":.., "dir":[x,y],
                 "exposure":0.8, "confidence":.., "kind":"npc"|"player"|"object:<cat>" } ],
  "hearing": [ { "emitter_eid":"..", "dir":[x,y], "perceived_volume":.., "clarity":..,
                 "est_src":[x,y]|null, "transcript":"" } ],   // transcript gated by clarity >= 0.5
  "drives":  { "energy":.., "hunger":.., "social":.., "safety":.. },  // the FOUR measured; social_need→social
  "proprio": { "intended_speed":.., "actual_movement":.., "is_stalled":bool },
  "abort":   { "active":false, "kind":"" },   // readout only; not wired to a bound yet
  "clock":   { "hour":.., "day":.. }          // v2: a wall clock is a sensor
}
```

Notes:
- **`vision`/`hearing`** come straight from `SensorSystem` graded results
  (`perception.visible_entities/objects`, `perception.last_hearing_results`).
- **Ids are opaque.** Entities cross as `ent_<sha8(npc_name)>`; world objects as
  `obj_<sha8(raw_id)>`. The body keeps `_obj_id_by_hash` to reverse-resolve an
  echoed primitive `target_id` back to the real id.
- **`transcript`** is a degraded measurement: a speech stimulus's text rides its
  tags and crosses only when heard at `clarity >= TRANSCRIPT_CLARITY_MIN` (0.5),
  else `""` — like real ears, faint speech is imprecise.
- **`drives`** are whitelisted to the four homeostatic channels;
  `get_state_dict()`'s arousal/momentum/frustration/etc. are cognition-derived
  and must NOT cross.

---

## §5 Body-side safety bounds (entry-denial)

Externally-commanded motion may never do what native motion wouldn't. Natives
only ever TARGET walkable tiles (AStar discipline) yet may legitimately stand
on / escape blocked ground — NPCs SPAWN inside blocked regions (e.g. the
town-square plaza) and walk out; the navgrid is a routing layer, not a physical
one. So the bound is **entry-denial**: deny entering a blocked tile FROM
walkable ground (revert the step + zero velocity + report intended speed so
`is_stalled` asserts — §10), but allow motion while already on blocked ground,
exactly as natives escape their spawns. Enforced in
`npc_controller._apply_velocity_and_progress` (landed-tile check; per-step motion
is `<<` one tile because velocity is `limit_length(speed)`-capped). A
physical-collider enforcement of the whole navgrid was tried and reverted for
this reason — see the note in `navigation_manager.gd::_ready`.

---

## §6 Action contract

The body applies the act motor-only (`npc_controller._apply_mind_action`):

```jsonc
{ "t":"act", "npc":"Hugo", "seq":42,        // seq echoes obs.seq in lockstep (§7)
  "vel":[vx,vy],                            // optional; px/s, clamped to npc.speed
  "horizon":[[vx,vy], ...],                 // optional; body applies horizon[0]
  "primitive":{ "kind":"consume"|"rest"|"interact"|"face_toward"|"speak", ... } }
```

- An **empty or timed-out act** resolves via `on_timeout` (`hold_last` reapplies
  the last velocity; `zero_vel` stops). The determinism contract is defined over
  `(seq, applied-state)`, so an act-less frame still resolves to a well-defined
  applied velocity.
- **`vel`** → `velocity = Vector2(v).limit_length(speed)` → shared motor path
  (face + animate + `move_and_slide` + `update_progress`). AStar and path jitter
  are bypassed entirely.
- **Primitives** dispatch to existing body-side effectors and mutate drives as
  world side-effects (§8): `consume` (reverse-resolve opaque token → category →
  `_apply_consume_effects_by_category`), `rest` (`_handle_rest`), `face_toward`,
  `speak` (gated by `allow_speak`, §3; refused with a warning otherwise),
  `interact` (no-op motor gesture for now).

---

## §7 Sync modes & timeout policy

- **Lockstep** (default): the body `await`s the act whose `seq` echoes `obs.seq`,
  yielding on `physics_frame` (never busy-wait) up to `deadline_ms`. One
  observation in flight per NPC — a re-entrancy guard (`_mind_awaiting`) makes
  subsequent physics frames early-out until the prior obs/act resolves. On
  timeout the body applies `on_timeout` and returns; the late act, if any, is
  dropped (the `_last_done_seq` watermark bounds the inbox — §10).
- **Free-running**: the body applies `_latest_act(npc)` each tick (hold-last);
  acts carry no `seq` consumer and the actuation echo dedupes by `seq` (§10).

A receding-horizon mind sends `horizon: [[vx,vy], ...]`; the body applies
`horizon[0]` and re-requests each step. `vel`, if present, takes precedence.

---

## §8 Grounded control & the state-vector contract

The firewall is **structural**, not a convention to remember:

- **Northbound is measured-only.** The observation is assembled key-by-key from
  sensors/substrate, never a spread of any brain-state dict. An
  emotion/appraisal/somatic field cannot leak in even by accident.
- **Southbound is motor-only.** The act carries velocity + primitives. There is
  no wire field for drives, emotions, intentions, or beliefs; drive changes
  happen only as world side-effects of primitives.
- **Ids are opaque.** World-object ids embed semantic location+identity
  (`bakery_oven_01`); they must not cross in plaintext. Both id families
  (`ent_*`, `obj_*`) use the same SHA8 scheme so they are indistinguishable
  on the wire.
- **Provenance is never a control signal.** Trace-header fields — the
  `scenario` block on `hello`, the `applied` echo (§10), the `BehaviorRecorder`
  CSV (§14) — are instrumentation only. No mind consumes them; they exist so an
  offline analyst can join disturbance → observation → actuation row-by-row.

This is what makes the link a *grounded* control loop: the mind is forced to
infer everything a real embodied agent would (its own drives, who it is looking
at, what it hears) from the same degraded measurements a body provides, and to
act through the same motor surface.

---

## §9 Weak-evidence probes

`ScenarioRunner` can suppress a controlled NPC's perception for a window via
`sensory_blackout`. The implementation is a REAL hook, not a stub: it zeroes
`brain._sensor_profile.vision_range` (=0 → the range check rejects every target)
and raises `hearing_threshold` to 2.0 (`perceived_volume` is clamped to [0,1], so
no stimulus qualifies), stashing and restoring the original profile when the
window ends. No edits to brain/controller/mind_link/sensor_system are required —
it exploits the existing per-tick profile re-read. With no `npc` given, the
window applies to all NPCs.

---

## §10 Actuation timing & echo

The body stamps `obs.t_emit` and, when an act is **actually applied** to the
actuators, sends an **`applied`** echo with `t_apply` on the SAME clock:

```jsonc
{ "t":"applied", "npc":"Hugo", "seq":42, "t_apply":1783119659.2 }
```

`report_applied` dedupes by `seq` (free-running re-applies the same act every
frame; only the FIRST application is the actuation event). Empty/timeout acts
carry no `seq` and echo nothing — an act that never actuated has no `t_apply`.
The mind pairs `t_emit`/`t_apply` for the true sensing→actuation delay without
mixing clocks.

**Inbox bounding (lockstep).** `_acts_by_seq` is keyed `"npc|seq"` and consumed
only by `await_act`. A late act (its awaiter timed out and returned) is dropped
in `_handle_act` against the `_last_done_seq` watermark — this is what keeps the
inbox finite whenever delay ≥ deadline (and on every act in free-running, which
never consumes it). A periodic diagnostic prints inbox size + `dropped_stale`
only when late acts are actually being dropped. This same `update_progress`
path is what reports the `intended_speed`/`actual_movement` that make
`is_stalled` assert under the §5 entry-denial revert.

---

## §11 Instrument-first (honest stubs)

Disturbances that burg cannot apply cleanly are logged with `stub:true` and
**not** faked — an analyst must never be unable to tell a missing effect from a
silent one. Current stubs:
- **`block_path`** — `NavigationManager` builds its AStar2D from
  `collision_map.png` at load; there is no runtime block hook.
- **`spawn_threat`** — burg has no clean runtime entity spawner; the threat
  table was removed in Phase 7.

`teleport_npc`, `move_entity`, `drive_shock`, and `sensory_blackout` are fully
implemented (return `stub:false` on the happy path).

---

## §12 Goal-invalidation probes (cond-5-vs-4 discriminator)

`move_entity` moves a world object an NPC was heading toward. World objects are
pure data in `WorldObjectRegistry.objects[id]` — each has a `position: Vector2`
that brains re-read every perception tick, so mutating the dict moves the object
body-side immediately and consistently. This is the *cond-5-vs-4*
discriminator: it distinguishes "the agent recomputes a path to a moved goal"
(cond 5) from simpler reactivity, without touching the agent's cognition. Lookup
is by `entity_id`/`id`, else a case-insensitive linear scan by display `name`.

---

## §13 Scenario disturbance registry

Armed by `BURG_SCENARIO` (path to a JSON file). Deterministic by construction:
**no RNG anywhere** — events fire straight off `Engine.get_physics_frames()` (the
SAME counter emitted as `obs.tick`), once, when `at_tick == tick`. Events are
pre-sorted by `at_tick`; a malformed event never crashes the body (every fire is
node-validity-guarded). The file is SHA256-hashed over its raw bytes and exposed
as `scenario_meta()` → attached to `hello` as provenance (§8).

Event kinds and params:

| kind | params | status |
|------|--------|--------|
| `teleport_npc` | `{npc, pos}` | implemented |
| `move_entity` | `{name \| entity_id \| id, pos}` | implemented (§12) |
| `drive_shock` | `{npc, drives:{energy,hunger,social,safety deltas}}` | implemented |
| `sensory_blackout` | `{npc?, duration_ticks}` | implemented (§9) |
| `block_path` | — | stub (§11) |
| `spawn_threat` | — | stub (§11) |

A JSONL log (`scenario_log_<ts>.jsonl` in the user data dir) records every fire:
`{tick, kind, params, ts, stub, note?}`.

---

## §14 Behavior recording

Armed by `BURG_BEHAVIOR_LOG` (output CSV path). Wire-silent; one row/sec/NPC:
`ts,npc,x,y,action,location,stalled` — `location` resolved via
`Layer3.location_name_from_position`. Used for native-vs-controlled parity runs.

---

## §15 Wire-message reference

| `t` | from → to | purpose |
|-----|-----------|---------|
| `hello` | body → mind | advertise npcs, action space, obs channels, scenario provenance |
| `hello_ack` | mind → body | fix the run: sync mode, control_npcs, lockstep params, allow_speak |
| `obs` | body → mind | one measured observation per controlled NPC per tick |
| `act` | mind → body | motor command (vel/horizon/primitive); `seq` echoes `obs.seq` in lockstep |
| `applied` | body → mind | actuation echo: `t_apply` on the body clock (§10) |
| `step` | mind → body | explicit-advance control frame (currently a no-op; the loop already gates per-seq) |
| `episode` | mind → body | lifecycle event (logged with reason) |

Unknown message types are ignored (the mind is the authority; the body consumes
only what it understands).

---

## §16 Versioning

`PROTO_VERSION = 3`. Bump on any wire change. On mismatch the mind refuses at
`hello` and the body refuses the `hello_ack`; both sides stay inactive. The
version has moved: v1 (objects omitted from vision), v2 (`transcript` + `clock`
channels, `allow_speak` gate), v3 (actuation echo `applied`).
