# Burg — Adaptive NPC Town Simulation

## Dimension: 2D

## Input Actions

| Action | Keys |
|--------|------|
| move_up | W, Up |
| move_down | S, Down |
| move_left | A, Left |
| move_right | D, Right |
| interact | Space, Enter |
| toggle_debug | Tab |
| ui_cancel | Escape |

## Scenes

### Main
- **File:** res://scenes/main.tscn
- **Root type:** Node2D
- **Children:** WorldMap, Player, NPCs (container), Camera2D, HUD (CanvasLayer), DebugOverlay, SocialPropagation, InteractionSystem

### Player
- **File:** res://scenes/player.tscn
- **Root type:** CharacterBody2D

### NPC
- **File:** res://scenes/npc.tscn
- **Root type:** CharacterBody2D

## Scripts

### GameManager (autoload)
- **File:** res://scripts/game_manager.gd
- **Extends:** Node
- **Signals emitted:** time_changed(hour), day_changed(day)

### NavigationManager (autoload)
- **File:** res://scripts/navigation_manager.gd
- **Extends:** Node
- **Signals emitted:** navigation_ready
- Loads collision_map.png as Texture2D resource, builds AStar2D grid (11936 walkable tiles)
- `get_nav_path(from, to, avoid_positions)` — optional `avoid_positions` array temporarily disables tiles for dynamic obstacle avoidance

### InferenceClient (autoload)
- **File:** res://scripts/inference_client.gd
- **Extends:** Node
- **Layer 2:** WebSocket to ws://localhost:8420/ws (projection/modulation)
- **Layer 3:** WebSocket to ws://localhost:8421/ws (plan, dialogue, chat, converse)
- Both connections auto-reconnect on disconnect (30s backoff)
- Multiplexed JSON-RPC: `{id, method, params}` → `{id, result}`

### PlayerController
- **File:** res://scripts/player_controller.gd
- **Extends:** CharacterBody2D
- **Collision:** layer 4, mask 2 (collides with NPCs)
- Added to "player" group for NPC perception lookup
- **ObserverProfile:** `sensor_profile` dict with wider range (128px) and arc (120deg) for future player-side perception features

### NPCController
- **File:** res://scripts/npc_controller.gd
- **Extends:** CharacterBody2D
- **Collision:** layer 2, mask 6 (collides with other NPCs and player)
- **Architecture:** Thin executor — brain selects actions, controller executes them
- **Actions:** MOVE_TOWARD, PAUSE, OBSERVE, EXAMINE, FLEE_FROM, WANDER, IDLE
- **External lock:** `_externally_locked` set by conversation/interaction systems, overrides brain
- Pathfinding is one tool among many, not the controlling abstraction
- Wander: at destination, NPCs meander within 48px radius instead of standing frozen
- **Dynamic obstacle avoidance:** On body collision during `_follow_path`, re-paths with obstacle's tile + 4 neighbors disabled in AStar grid (1s cooldown)
- **Progress reporting:** Each `_follow_path` tick reports intended vs actual movement to Layer 1 `update_progress()`

### NPCBrain
- **File:** res://scripts/npc_brain.gd
- **Extends:** RefCounted
- **Owns:** Layer1Substrate, Layer2Projection, Layer3Executive, MemorySystem, Perception
- **Perception via SensorSystem:** `update_perception()` queries SensorSystem.query_vision() for each entity/object candidate. Results include graded exposure and confidence. Brain NEVER computes visibility directly.
- **Per-NPC logging:** Writes to `logs/{name}.log`. Logs action changes (with substrate state), stall onset/clear, tagged memory events, and chunk transitions.
- **`select_action(delta)`:** Called every tick. Priority-ordered decision tree:
  1. Reorientation pause (after interruption, 0.5-2s based on frustration)
  2. Flee from distrusted entity (trust < 0.2, flee tendency > 0.5)
  3. Observe interesting entity (observe > 0.6, 8s cooldown — bypassed when stalled to 2s). When stalled, finds closest entity instead of novel-only.
  4. EXAMINE object (1-2s, triggered by chunk arrival with object_id or seeing role-relevant unexamined object)
  5. Wander at destination (within 48px, ticks chunk timer, checks for unexamined chunk objects)
  6. Move toward plan target (drive overrides change WHERE, action system changes HOW)
- **Stall-triggered observation:** When stalled and observing, creates tagged event ("{name} is in my way while I'm trying to {task}") and erodes trust toward blocker.
- **Object interaction:** EXAMINE action stops NPC, faces object, updates memory with current state. If object is problematic (broken/empty), creates concern and injects fix chunk into plan.
- **Drive overrides:** safety<30, energy<20, hunger>80, social>85 → override destination, suspend chunk. Hunger override checks known food objects first.
- **Reflection:** Every 2 game-hours or 5+ new tagged events
- **Modulation triggers:** Fires southbound L2 modulation on chunk changes

### HebbianNetwork
- **File:** res://scripts/hebbian_network.gd
- **Extends:** RefCounted
- **Neurons:** 19 fixed (4 drive, 3 task, 8 sensory, 5 action) + up to 32 dynamic via neurogenesis
- **Connections:** Weighted edges [-1.0, 1.0] between neurons, ~25 initial, grows via Hebbian learning
- **Propagation:** Every frame: `dst += src * weight * 0.1 * dt_scale`, decay 0.998/frame, noise +-0.05
- **Hebbian learning:** Every 0.5s, top K=2 co-activated pairs (>70% threshold), `delta_w = lr * (v1/100) * (v2/100)`, weight decay 0.001, pair rotation cooldown
- **Spontaneous connections:** Highly co-activated neurons with no existing connection form new edges
- **Neurogenesis:** Every 2s, creates specialized neurons: stress (cap 5), novelty (cap 6), reward (cap 6), global cap 32
  - Stress: sustained frustration >3s OR frustration >75%, creates inhibitory connections to frustration
  - Novelty: low familiarity sustained >5s, creates excitatory connections to observe/approach
  - Reward: drive recovery after override, reinforces drive-action pathway
- **Action baselines:** Floor values prevent tendency collapse (observe: 20, approach: 20, help: 15)
- **Data-driven:** Initial drive values and connection biases loaded from `data/npcs/{name}.json` persona files

### Layer1Substrate
- **File:** res://scripts/layer1_substrate.gd
- **Extends:** RefCounted
- **Architecture:** Wraps HebbianNetwork internally. External API unchanged — all properties backed by neuron activations via getters/setters
- **Drives (0-100):** energy, hunger, social_need, safety — neuron activations
- **Task state (0-1):** task_momentum, interruption_tolerance, frustration — 0-100 internally, scaled at interface
- **Action tendencies (0-1):** approach, avoid, observe, help, flee — emergent from network dynamics, not hardcoded formulas
- **Per-entity:** trust (dict), place_familiarity (dict) — non-neural, dictionary-based
- **Modulation inputs from Layer 2:** learning_rate_mod, exploration_bias, attention_weight, interruption_sensitivity, persistence_scale — now computed deterministically every tick from emotion vector
- **Emotion feedback:** `apply_emotion_feedback(emotion_vector)` — anger→frustration, curiosity→observe, fear→safety/flee, joy→approach. Closes the L2→L1 bidirectional loop
- **Baseline drift:** Preserves current game feel (hunger rises, energy depletes) independently of network; network adds learned adjustments on top
- **Progress tracking:** `update_progress(delta, intended_speed, actual_movement)` called by controller each tick
  - `is_stalled` — true when intended movement produces <30% expected displacement for >0.4s
  - Onset spike: frustration +15-40 (0-100 scale), momentum breaks -15, fires once per stall episode
  - Sustain: frustration +2/s, momentum -1/s while stuck
  - Spike re-arms when stall clears (including during observe pauses)
- **Frustration→observe coupling:** Emerges from network connection `task_frustration -> action_observe` (+0.04 initial weight), strengthened by Hebbian learning when both are co-activated
- `should_interrupt_for(priority)` — evaluates whether current momentum allows interruption
- `get_network_debug()` — returns neuron counts, connection counts, neurogenesis state for debug overlay

### EmotionEngine
- **File:** res://scripts/emotion_engine.gd
- **Extends:** RefCounted
- **Replaces L2 LLM projection** — deterministic, runs every tick, zero latency
- **Persona baseline gravity:** emotion vector decays toward persona-defined baseline (3%/tick)
- **L1 state mapping:** low energy→sadness, high frustration→anger/annoyance, low safety→fear, high social→desire
- **Event-driven spikes:** keyword matching on recent events (fled→fear, discovered→curiosity, broken→disappointment)
- **Modulation:** `compute_modulation(emotion_vector, chunk_priority)` — fixed mapping from emotions to L1 parameters (fear→interruption_sensitivity, curiosity→exploration_bias, etc.)

### PersonaLoader
- **File:** res://scripts/persona_loader.gd
- **Extends:** RefCounted (static methods)
- Loads NPC persona JSON from `data/npcs/{name}.json`
- Loads location data from `data/locations.json`
- `get_emotion_baseline_vector(persona)` — converts sparse emotion_baseline dict to 27-dim array

### Layer2Projection
- **File:** res://scripts/layer2_projection.gd
- **Extends:** RefCounted
- 27-dim GoEmotions vector stored per NPC
- **Dual-path architecture:**
  - **Fast path:** EmotionEngine (GDScript, deterministic) every tick via `update_deterministic()`
  - **Slow path:** Limbic server (TinyLlama-1.1B+LoRA) every ~2s via `request_limbic_update()`, overrides emotion vector
- **Limbic outputs:** `limbic_emotions` (label dict), `limbic_attention` (focus targets), `limbic_drives` (motivational drives)
- **Continuous modulation:** Modulation parameters computed every tick from emotion vector + chunk priority
- Persona baseline loaded from `data/npcs/{name}.json`

### Layer3Executive
- **File:** res://scripts/layer3_executive.gd
- **Extends:** RefCounted
- 16 town locations with world positions
- Role configs with default daily schedules (4-7 chunks each), with optional `object_id` and `object_action` fields
- **Object-aware planning:** Plan chunks can target specific objects. Role-default schedules reference work objects (Baker targets oven, Blacksmith targets forge, etc.)
- **Object concern injection:** When NPC discovers a problematic object in their domain, injects a high-priority fix/restock chunk into the agenda
- **Conditional replanning:** Only triggers LLM when state warrants it (high frustration, concerns, failures). Otherwise uses role defaults instantly.
- **Chunk suspension:** Can suspend current chunk for drive override, resume after recovery
- Night behavior: NPCs return home ~21:00, Guard patrols, Innkeeper stays late

### MemorySystem
- **File:** res://scripts/memory_system.gd
- **Extends:** RefCounted
- **Identity:** `npc_name`, `npc_role` — set by brain at setup for role-relevance scoring
- **Observations (last 20):** Structured dicts with `kind` (vision/hearing), `subtype`, `text`, `source_type`, `confidence`, `position`, `direction`, `tags`, `time`
- **Tagged events (last 10):** Structured with `text`, `salience`, `kind` (object_problem/speech/drive_override/player_interaction/etc.), `source_type` (direct/second_hand), `confidence`, `tags`, `time`
- Relationship tracking (trust per entity), place familiarity
- Unresolved concerns, reflections, failed strategies, socially acquired beliefs
- Event decay over time
- **Object knowledge:** `known_objects` dict (object_id -> {name, type, last_seen_position, last_seen_state, last_seen_time, learned_from, location, reliable})
- **Promotion:** `promote_observation()` — confidence + novelty + role-relevance gating for observation → tagged event promotion
- **Retrieval/compression layer — three packet builders:**
  - `build_plan_packet(ctx)` — bounded packet for L3 planning: top_emotions(3), concerns(2), problem_objects(2), recent_failures(2), salient_events(4)
  - `build_reflection_packet(ctx)` — bounded packet for L3 reflection: events(6), current_concerns(2), active_intention
  - `build_dialogue_packet(ctx)` — bounded packet for L3 dialogue: top_emotions(3), top_concern, notable_objects(2), recent_relevant_events(3)
- **Ranking:** `_rank_events()` — weighted score from salience, recency, confidence, role relevance, chunk relevance
- **Dedupe:** `_dedupe_events()` — collapse repeated events by kind+text prefix, keep latest with count
- **Legacy methods kept:** `get_memory_summary()`, `get_object_summary()`, `get_object_dialogue_context()`, `add_observation(who,where,doing)`
- `on_tagged_event: Callable` — optional log callback, set by brain to pipe events to per-NPC log file

### Perception
- **File:** res://scripts/perception.gd
- **Extends:** RefCounted
- **Role:** Thin local cache for SensorSystem query results. No direct FOV math — all perception goes through SensorSystem.
- `facing_vector` retained for SensorSystem arc checks
- `visible_entities` and `visible_objects` populated by NPCBrain from SensorSystem results (includes `exposure`, `confidence`, `vision_result`)
- `_vision_cache` (per-entity VisionResult), `_hearing_cache` (per-stimulus HearingResult)
- `last_vision_queries` and `last_hearing_results` for debug overlay visualization
- Legacy `update_vision()`, `update_object_vision()`, `can_see()` kept as no-ops/fallbacks for backward compatibility
- `get_fov_cone_points()` retained for debug overlay rendering

### WorldObjectRegistry (autoload)
- **File:** res://scripts/world_object_registry.gd
- **Extends:** Node
- Persistent registry of 21 world objects across 8 locations
- Each object: id, name, type, position, location, state, owner, properties, discoverable, role_affinity
- Methods: `register_object()`, `get_object()`, `get_objects_at_location()`, `get_objects_by_type()`, `get_all_objects()`, `update_object_state()`

### SocialPropagation
- **File:** res://scripts/social_propagation.gd
- **Extends:** Node
- Pulses every 5 real seconds, checks NPC pairs within 64px
- Requires: both NPCs have social_need > 30, at least one sees the other (via SensorSystem.query_vision()), both pass interruption check
- Role-tag affinity: guards prefer sharing security info, merchants trade info, etc.
- Trust-weighted salience: events from trusted sources stored with higher salience
- **Object knowledge exchange:** During conversations, NPCs share known objects (1-2 per conversation). Role-filtered sharing (Baker shares bakery objects, etc.). Trust-weighted: reliable flag set for trusted sources.
- Conversation context enriched with object knowledge for more natural dialogue
- Cooldown: 60 real seconds per pair
- NPCs stop, face each other, generate dialogue via Layer 3, speech bubbles visible

### InteractionSystem
- **File:** res://scripts/interaction_system.gd
- **Extends:** Node
- Uses `_unhandled_input` (not `_input`) so LineEdit gets keypresses first
- Opens chat panel (right side, dark theme) with message history
- NPC greeting via `/layer3/dialogue`, replies via `/layer3/chat` (WebSocket)
- Dialogue context includes NPC's object knowledge summary (notable/problematic objects)
- Shows `[server] Connection failed` when server is down
- Speech broadcasts to nearby NPCs via hearing system
- Mood shifts affect trust

### DebugOverlay
- **File:** res://scripts/debug_overlay.gd
- **Extends:** CanvasLayer
- Layer 1: progress bars (energy, hunger, social, safety, momentum, tolerance, frustration)
- Layer 2: 27-dim GoEmotions heatmap (colored cells) + top-3 dimensions + modulation params
- Layer 3: plan chunks (active highlighted yellow), suspended chunk indicator
- Drive override display in action label (orange text)
- **World-space debug drawing** (Node2D child):
  - FOV cones for all NPCs (semi-transparent, colored by valence)
  - Vision rays from selected NPC: green=visible (with sample dots + exposure %), red=blocked (with X markers)
  - Hearing direction arcs with volume meters (yellow=speech, blue=generic, gray=footstep)
  - Occluder wall segments as semi-transparent red lines (viewport-culled)
  - Active stimuli as pulsing circles (yellow=speech, gray=footstep, red=impact)
- Valence indicator dots above all NPCs

### CameraController
- **File:** res://scripts/camera_controller.gd

### OccluderSystem (autoload)
- **File:** res://scripts/occluder_system.gd
- **Extends:** Node
- Extracts wall boundary line segments from collision_map.png (140x100 grayscale)
- Edge detection on horizontal/vertical tile boundaries, merges collinear runs
- 1148 wall segments stored in spatial grid (10-tile cells) for fast lookup
- `get_occluders_in_rect(rect: Rect2) -> Array` — broad-phase spatial query returning segment dicts
- `get_segment_indices_in_rect(rect: Rect2) -> Array` — returns deduplicated indices for ray testing
- Segment format: `{start: Vector2, end: Vector2, blocks_vision: bool, sound_damping: float, tags: Array}`

### StimulusRegistry (autoload)
- **File:** res://scripts/stimulus_registry.gd
- **Extends:** Node
- Manages active world stimuli (speech, footsteps, presence, impact) with spatial grid for fast range queries
- Each stimulus: `{id, type, position, radius, strength, duration, tags, emitter_id, created_at}`
- `emit(type, position, radius, strength, duration, tags, emitter_id) -> String` — returns stimulus id
- `remove(id)` — manual removal for persistent stimuli
- `get_stimuli_in_range(pos, radius) -> Array` — broad-phase spatial grid + narrow-phase distance check
- `tick(delta)` — auto-removes expired transient stimuli (called in `_process`)
- Persistent stimuli (duration=-1) must be refreshed/removed manually
- Speech stimuli: radius=160px, strength=0.8, duration=4s
- Footstep stimuli: radius=48px, strength=0.15, duration=0.5s

### SensorSystem (autoload)
- **File:** res://scripts/sensor_system.gd
- **Extends:** Node
- Two-phase vision queries with multi-sample line-of-sight raycasting
- `query_vision(observer_pos, observer_facing, profile, target_pos, target_sample_points) -> Dictionary` (VisionResult)
- Phase 1 (broad): range check + facing arc check, reject cheaply
- Phase 2 (narrow): analytical line-segment intersection against OccluderSystem segments — no physics engine dependency
- VisionResult: `{visible, distance, exposure, confidence, sample_hits, sample_total, blocked_by, last_visible_point}`
- Actor targets use 5 sample points (center + 4 body offsets), objects use center only
- **Hearing queries:**
  - `query_hearing(listener_pos, profile, stimulus) -> Dictionary` (HearingResult) — analog hearing with sound attenuation through occluders
  - `query_hearing_all(listener_pos, profile) -> Array` — batch query, returns only heard results
  - Broad phase: max effective radius from stimulus strength / hearing threshold
  - Narrow phase: 3 rays from source to listener, each occluder's sound_damping reduces signal multiplicatively
  - HearingResult: `{heard, perceived_volume, clarity, distance, direction, occlusion_loss, estimated_source_pos, stimulus_id, stimulus_type, emitter_id, tags}`
  - Uncertainty: estimated_source_pos has random offset proportional to (1 - clarity)

### SensorProfile
- **File:** res://scripts/sensor_profile.gd
- **Extends:** RefCounted (static methods)
- Per-actor sensor configuration: vision_range (96px), vision_arc_deg (90), eye_offset, hearing_threshold, hearing_sensitivity, ear_offset
- `make_default()` — returns default profile dictionary
- `from_persona(persona)` — loads from persona JSON `sensor_profile` section with fallback to defaults

### SensoryResultTypes
- **File:** res://scripts/sensory_result_types.gd
- **Extends:** RefCounted (static methods)
- Factory functions: `make_vision_result()`, `make_hearing_result()`
- Sample point offsets: `actor_sample_offsets()` (5 points), `object_sample_offsets()` (center only)

### WorldMap
- **File:** res://scripts/world_map.gd
- Container (Sprite2D with NO texture): instances `scenes/world.tscn` (the baked tilemap) + `scripts/world_labels.gd` + `scripts/world_object_markers.gd`. Retired the old flat `assets/img/town_map.png`. See `tools/build_world_tilemap.gd`.

### WorldLabels
- **File:** res://scripts/world_labels.gd
- 16 location-name Labels at `data/locations.json` positions (z -1, above tiles / below actors). Toggle with `toggle_labels` input (default L).

### WorldObjectMarkers
- **File:** res://scripts/world_object_markers.gd
- Colored diamond + label per `WorldObjectRegistry` object (35); group `world_objects`. z -1. Draw-only — perception still reads the registry.

### build_world_tilemap (tool)
- **File:** res://tools/build_world_tilemap.gd
- One-shot SceneTree baker: `assets/the_ville.tmx` → `tilesets/world_tileset.tres` + `scenes/world.tscn` (10 TileMapLayer, one per visual layer, native 32px). Run headless; re-runnable.

### HUDTime
- **File:** res://scripts/hud_time.gd

## Data Files

- **NPC Personas:** `data/npcs/{name}.json` — single source of truth per NPC (identity, schedule, personality, drives, neural biases, dialogue fallbacks, relationships)
- **Locations:** `data/locations.json` — shared location registry (position, tile, type, public flag)
- Both loaded by GDScript (`scripts/persona_loader.gd`) and Python (`server/persona_loader.py`)

## Autoloads

- GameManager = res://scripts/game_manager.gd
- NavigationManager = res://scripts/navigation_manager.gd
- InferenceClient = res://scripts/inference_client.gd
- WorldObjectRegistry = res://scripts/world_object_registry.gd
- OccluderSystem = res://scripts/occluder_system.gd
- StimulusRegistry = res://scripts/stimulus_registry.gd
- SensorSystem = res://scripts/sensor_system.gd

## Inference Servers

| Server | Port | Model | Protocol | Purpose |
|--------|------|-------|----------|---------|
| Layer 2 (Limbic) | 8420 | TinyLlama-1.1B + LoRA (4-bit, peft) | WebSocket (/ws) + HTTP fallback | Trained emotion projection, attention focus, motivational drives |
| Layer 3 | 8421 | SmolLM2-1.7B-Instruct (transformers) | WebSocket (/ws) + HTTP fallback | Thought loop, planning, dialogue, chat, NPC conversation |

- Start both: `bash server/start.sh`
- Logs: `tail -f /tmp/burg_l2.log /tmp/burg_l3.log`
- L3 server hosts the **thought loop** — an async per-NPC coroutine that generates thoughts, intentions, beliefs, and pushes them to the client
- L3 also loads L2 model for thought coloring (limbic interpretation of executive thoughts)
- All L3 calls log method, input summary, response, and timing

## Thought Loop Architecture

```
CLIENT (every physics tick):                SERVER (async per-NPC, every 2-8s):
  L1 Hebbian network                          Receive state snapshot from client
  Deterministic emotion engine (fallback)        ↓
  Softmax action selection over L1 neurons     L3 Executive: generate_thought()
  Execute action                                 → think(), intend(), believe(), bias_action()
  Send state snapshot (every ~2s)                ↓
  Process server push commands               L2 Limbic: color the thoughts emotionally
                                                ↓
                                              Push commands to client:
                                                update_emotion, set_intention,
                                                store_belief, bias_action, set_thought
```

- **Server drives behavior** by pushing commands; client doesn't poll for replan triggers
- **Action selection** uses softmax competition over Hebbian action neurons — no priority queue
- **Intentions** replace canned schedules as the primary behavior driver
- **Beliefs** are structured (subject/predicate/object) and influence trust computation
- **Thoughts** are internal stimuli that pass through the limbic model for emotional coloring
- **Graceful degradation**: if server is down, L1+deterministic L2+fallback schedule still run

### Server-Side Modules

- `server/npc_state.py` — Per-NPC state: intentions, beliefs, thought history, adaptive cadence
- `server/thought_loop.py` — Async engine: one coroutine per NPC, L2+L3 cycle, push delivery

### Push Protocol

Server sends unsolicited messages over the L3 WebSocket:
```json
{"push": true, "npc": "Edith", "commands": [
  {"cmd": "update_emotion", "vector": [...], "summary": "..."},
  {"cmd": "set_intention", "goal": "...", "location": "...", "priority": 0.8, "reason": "..."},
  {"cmd": "store_belief", "subject": "...", "predicate": "...", "object": "...", "confidence": 0.7},
  {"cmd": "bias_action", "biases": {"approach": 0.5}},
  {"cmd": "set_thought", "text": "..."}
]}
```

## Time Scales

| Rate | System | Cadence |
|------|--------|---------|
| Fast | Layer 1 substrate + L2 emotions + modulation | Every physics tick (closed loop) |
| Fast | L1 Hebbian learning | Every 0.5 real seconds |
| Fast | L1 neurogenesis check | Every 2.0 real seconds |
| Adaptive | Thought loop (server) | Every 2-8 real seconds per NPC (urgency-driven) |
| Slow | State snapshots (client → server) | Every 2 real seconds |
| Very slow | Social propagation | Every 5 real seconds |
| Triggered | Layer 3 reflection | Every 2 game-hours or 5+ new events |
| On demand | Layer 3 chat/dialogue | Player interaction |

## Assets

- Town map: assets/img/town_map.png (4480x3200, rendered from TMX)
- Collision: assets/img/collision_map.png (140x100 grayscale)
- Characters: assets/characters/Character_RM_001-010.png (48x48 frames, RPG Maker VX Ace)
