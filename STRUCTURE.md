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
- **Layer 2:** HTTP POST to localhost:8420 (projection/modulation)
- **Layer 3:** WebSocket to ws://localhost:8421/ws (plan, dialogue, chat, converse)
- Auto-reconnects WebSocket on disconnect (5s backoff)
- REQUEST_TIMEOUT: 30s

### PlayerController
- **File:** res://scripts/player_controller.gd
- **Extends:** CharacterBody2D

### NPCController
- **File:** res://scripts/npc_controller.gd
- **Extends:** CharacterBody2D
- **States:** IDLE, WALKING, ARRIVED, TALKING, CONVERSING
- Observation pauses: high `observe` tendency + visible entities → brief stop to watch
- Speed modulation: `flee` increases speed, `avoid` decreases near others (0.5x-1.5x)
- Staggered startup: each NPC delays first plan request by 0.5-5s random

### NPCBrain
- **File:** res://scripts/npc_brain.gd
- **Extends:** RefCounted
- **Owns:** Layer1Substrate, Layer2Projection, Layer3Executive, MemorySystem, Perception
- **Drive overrides:** When Layer 1 drives hit urgent thresholds (safety<30, energy<20, hunger>80, social>85), brain overrides Layer 3 plan to seek recovery. Suspends current plan chunk, resumes after recovery.
- **Reflection:** Every 2 game-hours or 5+ new tagged events, calls /layer3/reflect to compress memory
- **Modulation triggers:** When Layer 3 plan chunk changes, fires southbound modulation via Layer 2

### Layer1Substrate
- **File:** res://scripts/layer1_substrate.gd
- **Extends:** RefCounted
- **Drives (0-100):** energy, hunger, social_need, safety
- **Task state (0-1):** task_momentum, interruption_tolerance, frustration
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

### Perception
- **File:** res://scripts/perception.gd
- **Extends:** RefCounted
- **FOV:** 90° cone, 3-tile range (96px), directional based on facing
- **Hearing:** Omnidirectional, 2.5-tile range (80px)
- NPCs only observe entities within FOV
- Speech broadcasts to all NPCs in hearing range

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

## Inference Servers

| Server | Port | Model | Protocol | Purpose |
|--------|------|-------|----------|---------|
| Layer 2 | 8420 | SmolLM2-135M-Instruct (transformers) | HTTP | Fast emotion projection/modulation |
| Layer 3 | 8421 | SmolLM2-1.7B-Instruct (transformers) | HTTP + WebSocket (/ws) | Planning, dialogue, chat, NPC conversation |

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
