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
- **Children:** WorldMap (Sprite2D), Player (instance), NPCs (Node2D container), Camera2D, CanvasLayer (HUD), DebugOverlay, SocialPropagation, InteractionSystem

### Player
- **File:** res://scenes/player.tscn
- **Root type:** CharacterBody2D
- **Children:** AnimatedSprite2D

### NPC
- **File:** res://scenes/npc.tscn
- **Root type:** CharacterBody2D
- **Children:** AnimatedSprite2D, NameLabel (Label)

## Scripts

### GameManager (autoload)
- **File:** res://scripts/game_manager.gd
- **Extends:** Node
- **Signals emitted:** time_changed(hour: float), day_changed(day: int)

### NavigationManager (autoload)
- **File:** res://scripts/navigation_manager.gd
- **Extends:** Node
- **Signals emitted:** navigation_ready

### InferenceClient (autoload)
- **File:** res://scripts/inference_client.gd
- **Extends:** Node
- **Signals emitted:** request_completed(request_id, success, data)
- **Routes:** Layer 2 requests → localhost:8420, Layer 3 requests → localhost:8421

### PlayerController
- **File:** res://scripts/player_controller.gd
- **Extends:** CharacterBody2D

### NPCController
- **File:** res://scripts/npc_controller.gd
- **Extends:** CharacterBody2D
- **States:** IDLE, WALKING, ARRIVED, TALKING, CONVERSING

### NPCBrain
- **File:** res://scripts/npc_brain.gd
- **Extends:** RefCounted
- **Owns:** Layer1Substrate, Layer2Projection, Layer3Executive, MemorySystem, Perception

### Layer1Substrate
- **File:** res://scripts/layer1_substrate.gd
- **Extends:** RefCounted

### Layer2Projection
- **File:** res://scripts/layer2_projection.gd
- **Extends:** RefCounted

### Layer3Executive
- **File:** res://scripts/layer3_executive.gd
- **Extends:** RefCounted

### MemorySystem
- **File:** res://scripts/memory_system.gd
- **Extends:** RefCounted

### Perception
- **File:** res://scripts/perception.gd
- **Extends:** RefCounted
- **FOV:** 90° cone, 3-tile range (96px), directional based on facing
- **Hearing:** Omnidirectional, 2.5-tile range (80px)

### SocialPropagation
- **File:** res://scripts/social_propagation.gd
- **Extends:** Node
- **Manages:** NPC-to-NPC face-to-face conversations with Layer 3 dialogue

### InteractionSystem
- **File:** res://scripts/interaction_system.gd
- **Extends:** Node
- **Manages:** Player chat dialogue panel with multi-turn conversation via Layer 3

### DebugOverlay
- **File:** res://scripts/debug_overlay.gd
- **Extends:** CanvasLayer
- **Shows:** L1 bars, L2 GoEmotions 27-dim heatmap, L3 plan chunks, FOV cones

### CameraController
- **File:** res://scripts/camera_controller.gd
- **Extends:** Camera2D

### WorldMap
- **File:** res://scripts/world_map.gd
- **Extends:** Sprite2D

### HUDTime
- **File:** res://scripts/hud_time.gd
- **Extends:** Label

## Signal Map

- NavigationManager.navigation_ready -> NPCController (begin pathfinding)
- GameManager time tracked by NPCController each tick

## Autoloads

- GameManager = res://scripts/game_manager.gd
- NavigationManager = res://scripts/navigation_manager.gd
- InferenceClient = res://scripts/inference_client.gd

## Inference Servers

| Server | Port | Model | Purpose |
|--------|------|-------|---------|
| Layer 2 | 8420 | SmolLM2-135M-Instruct | Fast emotion projection/modulation (~4 calls/sec) |
| Layer 3 | 8421 | SmolLM2-1.7B-Instruct | Planning, dialogue, chat, NPC conversation |

Start both: `bash server/start.sh`

## Asset Hints

- Pre-rendered town map: assets/img/town_map.png (4480×3200, Sprite2D background)
- Collision grid: assets/img/collision_map.png (140×100, parsed for AStar2D)
- Character sprites: assets/characters/Character_RM_001-010.png (576×384, 48×48 frames, RPG Maker VX Ace format)
