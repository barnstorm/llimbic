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

## Scenes

### Main
- **File:** res://scenes/main.tscn
- **Root type:** Node2D
- **Children:** WorldMap (Sprite2D), Player (instance), NPCs (Node2D container), Camera2D, CanvasLayer (HUD)

### Player
- **File:** res://scenes/player.tscn
- **Root type:** CharacterBody2D
- **Children:** AnimatedSprite2D

### NPC
- **File:** res://scenes/npc.tscn
- **Root type:** CharacterBody2D
- **Children:** AnimatedSprite2D, NameLabel (Label), StateIndicator (Sprite2D)

## Scripts

### GameManager (autoload)
- **File:** res://scripts/game_manager.gd
- **Extends:** Node
- **Signals emitted:** time_changed(hour: float), day_changed(day: int)

### PlayerController
- **File:** res://scripts/player_controller.gd
- **Extends:** CharacterBody2D
- **Attaches to:** Player:Player

### NPCController
- **File:** res://scripts/npc_controller.gd
- **Extends:** CharacterBody2D
- **Attaches to:** NPC:NPC

### NavigationManager (autoload)
- **File:** res://scripts/navigation_manager.gd
- **Extends:** Node
- **Signals emitted:** navigation_ready

### WorldMap
- **File:** res://scripts/world_map.gd
- **Extends:** Sprite2D
- **Attaches to:** Main:WorldMap

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

### SocialPropagation
- **File:** res://scripts/social_propagation.gd
- **Extends:** Node

### DebugOverlay
- **File:** res://scripts/debug_overlay.gd
- **Extends:** CanvasLayer

### InteractionSystem
- **File:** res://scripts/interaction_system.gd
- **Extends:** Node

## Signal Map

- GameManager.time_changed -> NPCController (schedule checks)
- GameManager.day_changed -> Layer3Executive (new day planning)
- NavigationManager.navigation_ready -> NPCController (begin pathfinding)

### NPCBrain
- **File:** res://scripts/npc_brain.gd
- **Extends:** RefCounted

### InferenceClient (autoload)
- **File:** res://scripts/inference_client.gd
- **Extends:** Node
- **Signals emitted:** request_completed(request_id: String, success: bool, data: Dictionary)

## Autoloads

- GameManager = res://scripts/game_manager.gd
- NavigationManager = res://scripts/navigation_manager.gd
- InferenceClient = res://scripts/inference_client.gd

## Asset Hints

- Pre-rendered town map: assets/img/town_map.png (4480×3200, used as Sprite2D)
- Collision grid: assets/img/collision_map.png (140×100, parsed for AStar2D)
- Character sprites: assets/characters/Character_RM_001-010.png (576×384, 48×48 frames, RPG Maker VX Ace format)
