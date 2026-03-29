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

### NPCController
- **File:** res://scripts/npc_controller.gd
- **Extends:** CharacterBody2D
- **Architecture:** Thin executor — brain selects actions, controller executes them
- **Actions:** MOVE_TOWARD, PAUSE, OBSERVE, FLEE_FROM, WANDER, IDLE
- **External lock:** `_externally_locked` set by conversation/interaction systems, overrides brain
- Pathfinding is one tool among many, not the controlling abstraction
- Wander: at destination, NPCs meander within 48px radius instead of standing frozen

### NPCBrain
- **File:** res://scripts/npc_brain.gd
- **Extends:** RefCounted
- **Owns:** Layer1Substrate, Layer2Projection, Layer3Executive, MemorySystem, Perception
- **`select_action(delta)`:** Called every tick. Priority-ordered decision tree:
  1. Reorientation pause (after interruption, 0.5-2s based on frustration)
  2. Flee from distrusted entity (trust < 0.2, flee tendency > 0.5)
  3. Observe interesting entity (new in FOV, observe > 0.6, 8s cooldown)
  4. Wander at destination (within 48px, ticks chunk timer)
  5. Move toward plan target (drive overrides change WHERE, action system changes HOW)
- **Drive overrides:** safety<30, energy<20, hunger>80, social>85 → override destination, suspend chunk
- **Reflection:** Every 2 game-hours or 5+ new tagged events
- **Modulation triggers:** Fires southbound L2 modulation on chunk changes

### Layer1Substrate
- **File:** res://scripts/layer1_substrate.gd
- **Extends:** RefCounted
- **Drives (0-100):** energy, hunger, social_need, safety
- **Task state (0-1):** task_momentum, interruption_tolerance, frustration, reorientation_timer
- **Action tendencies (0-1):** approach, avoid, observe, help, flee — weighted by conditions
- **Per-entity:** trust (dict), place_familiarity (dict)
- **Modulation inputs from Layer 2:** learning_rate_mod, exploration_bias, attention_weight, interruption_sensitivity, persistence_scale
- `should_interrupt_for(priority)` — evaluates whether current momentum allows interruption

### Layer2Projection
- **File:** res://scripts/layer2_projection.gd
- **Extends:** RefCounted
- 27-dim GoEmotions vector stored per NPC
- Calls `/layer2/project` every ~2.0 real seconds (staggered per NPC)
- Southbound modulation via `/layer2/modulate` on Layer 3 directive changes

### Layer3Executive
- **File:** res://scripts/layer3_executive.gd
- **Extends:** RefCounted
- 16 town locations with world positions
- Role configs with default daily schedules (4-7 chunks each)
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
- **Object knowledge:** `known_objects` dict (object_id -> {name, type, last_seen_position, last_seen_state, last_seen_time, learned_from, location})
- Methods: `add_object_knowledge()`, `get_objects_at_location()`, `get_objects_by_type()`, `get_object_summary()`

### Perception
- **File:** res://scripts/perception.gd
- **Extends:** RefCounted
- **FOV:** 90° cone, 3-tile range (96px), directional based on facing
- **Hearing:** Omnidirectional, 2.5-tile range (80px)
- NPCs only observe entities within FOV
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
- Cooldown: 60 real seconds per pair
- NPCs stop, face each other, generate dialogue via Layer 3, speech bubbles visible

### InteractionSystem
- **File:** res://scripts/interaction_system.gd
- **Extends:** Node
- Uses `_unhandled_input` (not `_input`) so LineEdit gets keypresses first
- Opens chat panel (right side, dark theme) with message history
- NPC greeting via `/layer3/dialogue`, replies via `/layer3/chat` (WebSocket)
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
| Fast | Layer 1 substrate | Every physics tick |
| Medium | Layer 2 projection | Every ~2.0 real seconds (staggered) |
| Slow | Layer 3 planning | Every ~30 game-minutes |
| Very slow | Social propagation | Every 5 real seconds |
| Triggered | Layer 3 reflection | Every 2 game-hours or 5+ new events |
| On demand | Layer 3 chat/dialogue | Player interaction |

## Assets

- Town map: assets/img/town_map.png (4480x3200, rendered from TMX)
- Collision: assets/img/collision_map.png (140x100 grayscale)
- Characters: assets/characters/Character_RM_001-010.png (48x48 frames, RPG Maker VX Ace)
