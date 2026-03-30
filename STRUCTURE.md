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
- **Perception includes Player:** `update_perception()` takes player node, adds to entity list alongside NPCs. NPCs see the player through the same FOV cone as everything else.
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
- **Deterministic:** Uses EmotionEngine (GDScript, no LLM) every tick via `update_deterministic()`
- **Continuous modulation:** Modulation parameters computed every tick from emotion vector + chunk priority, not just on chunk changes
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
- Observations (last 20), tagged events (last 10 with salience + decay)
- Relationship tracking (trust per entity), place familiarity
- Unresolved concerns, reflections, failed strategies, socially acquired beliefs
- Event decay over time
- **Object knowledge:** `known_objects` dict (object_id -> {name, type, last_seen_position, last_seen_state, last_seen_time, learned_from, location, reliable})
- Methods: `add_object_knowledge()`, `get_objects_at_location()`, `get_objects_by_type()`, `get_object_summary()`, `get_problematic_objects()`, `get_food_objects()`, `get_objects_for_sharing()`, `get_object_dialogue_context()`
- Second-hand object knowledge from trusted sources (trust > 0.6) marked as "reliable"
- Direct observations don't get overwritten by fresh second-hand info (5-minute protection)
- `on_tagged_event: Callable` — optional log callback, set by brain to pipe events to per-NPC log file

### Perception
- **File:** res://scripts/perception.gd
- **Extends:** RefCounted
- **FOV:** 90° cone, 3-tile range (96px), directional based on facing
- **Hearing:** Omnidirectional, 2.5-tile range (80px)
- NPCs observe entities (other NPCs + Player) and objects within FOV
- Speech broadcasts to all NPCs in hearing range
- **Object vision:** `visible_objects` array + `update_object_vision()` — same FOV cone rules as entity vision

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
- Requires: both NPCs have social_need > 30, at least one sees the other, both pass interruption check
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
- FOV cones rendered in world space via Node2D child
- Valence indicator dots above all NPCs

### CameraController
- **File:** res://scripts/camera_controller.gd

### WorldMap
- **File:** res://scripts/world_map.gd

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

## Inference Servers

| Server | Port | Model | Protocol | Purpose |
|--------|------|-------|----------|---------|
| Layer 2 | 8420 | SmolLM2-135M-Instruct (transformers) | WebSocket (/ws) + HTTP fallback | Fast emotion projection/modulation |
| Layer 3 | 8421 | SmolLM2-1.7B-Instruct (transformers) | WebSocket (/ws) + HTTP fallback | Planning, dialogue, chat, NPC conversation |

- Start both: `bash server/start.sh`
- Logs: `tail -f /tmp/burg_l2.log /tmp/burg_l3.log`
- L3 plans use role defaults by default; LLM only triggered for replanning on high frustration/concerns/failures
- All L3 calls log method, input summary, response, and timing

## Time Scales

| Rate | System | Cadence |
|------|--------|---------|
| Fast | Layer 1 substrate + L2 emotions + modulation | Every physics tick (closed loop) |
| Fast | L1 Hebbian learning | Every 0.5 real seconds |
| Fast | L1 neurogenesis check | Every 2.0 real seconds |
| Slow | Layer 3 planning | Every ~30 game-minutes + urgency triggers (30s debounce) |
| Very slow | Social propagation | Every 5 real seconds |
| Triggered | Layer 3 reflection | Every 2 game-hours or 5+ new events |
| Triggered | Urgency replan | frustration>0.7, safety<20, energy<15, hunger>90 |
| On demand | Layer 3 chat/dialogue | Player interaction |

## Assets

- Town map: assets/img/town_map.png (4480x3200, rendered from TMX)
- Collision: assets/img/collision_map.png (140x100 grayscale)
- Characters: assets/characters/Character_RM_001-010.png (48x48 frames, RPG Maker VX Ace)
