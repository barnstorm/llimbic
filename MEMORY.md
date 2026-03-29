# Memory

## Task 1: World, Navigation & Characters

### What worked
- `Image.load_from_file()` works for reading the collision map PNG at runtime, even though Godot warns about export compatibility. The image loads correctly in both headless and display modes.
- AStar2D grid builds quickly (11936 walkable tiles from 140x100 map). 4-directional connectivity is sufficient for the tile grid.
- RPG Maker VX Ace sprite sheets: first character is top-left 3x4 block (3 cols x 4 rows). Row order: down=0, left=1, right=2, up=3. Each frame is 48x48. AtlasTexture regions work perfectly for extracting individual frames.
- Camera2D with `position_smoothing_enabled` + `limit_*` properties handles smooth follow and map-bounds clamping without custom code.
- `--write-movie` with `DISPLAY=:0` works on this system (lavapipe software renderer). Headless mode crashes when trying to render textures with `--write-movie`.

### Technical details
- Collision map: 140x100 grayscale, white(255)=blocked, black(0)=walkable. 2064 blocked tiles, 11936 walkable.
- TMX spawn positions (first 8): all in upper portion of map inside buildings. Spawn tiles are verified walkable.
- Player start position: world (2240, 1600) = tile (70, 50), confirmed walkable.
- `NavigationManager.astar` may be null during `_initialize()` in test harness — autoload `_ready()` fires after `_initialize()`. Check availability in `_process()` instead.

### Autoload access pattern
- Cannot reference autoloads by name in SceneTree scripts (quirk). Must iterate `get_tree().root.get_children()` and match by `.name`.
- In runtime scripts attached to scene nodes, same pattern works: iterate `get_tree().root.get_children()`.

### Character sprite setup
- SpriteFrames built programmatically with AtlasTexture per frame
- Animation names: `walk_down`, `walk_left`, `walk_right`, `walk_up`, `idle_down`, etc.
- Walk speed: 6 FPS, idle: 1 FPS (single frame)
- NPC character sheets: Character_RM_002 through Character_RM_009 assigned to 8 NPCs

### NPC names and roles
- Edith (Baker), Roland (Guard), Ivy (Herbalist), Felix (Courier)
- Greta (Blacksmith), Mabel (Gossip), Aldric (Farmer), Hugo (Innkeeper)

## Task 3: NPC AI & Town Life

### Architecture
- NPCBrain (RefCounted) orchestrates Layer1, Layer2, Layer3, and MemorySystem per NPC
- All layer classes are RefCounted, instantiated from GDScript via `load().new()`
- InferenceClient: HTTP to L2 (port 8420), WebSocket to L3 (port 8421/ws). Graceful degradation if servers are down.
- Layer 1 runs every physics tick (pure GDScript drives/tendencies + action tendencies: approach, avoid, observe, help, flee)
- Layer 2 fires every ~2.0 real seconds per NPC (staggered, emotion vector projection via HTTP)
- Layer 3 fires on game-time intervals (~30 game-minutes). Plans use role defaults; LLM only triggered for replanning on high frustration/concerns/failures.
- Social propagation pulses every 5 real seconds, checks NPC pairs within 64px, requires social_need > 30 + FOV visibility + interruption check
- Drive overrides: brain overrides L3 plan when safety<30, energy<20, hunger>80, or social>85. Suspends current chunk, resumes after recovery.
- Reflection: every 2 game-hours or 5+ new tagged events, calls /layer3/reflect to compress memory
- Observation pauses: NPCs with high observe tendency briefly stop to watch nearby entities
- Speed modulation: flee tendency increases walk speed, avoid tendency decreases it near others

### What worked
- Direct property access on RefCounted instances works fine from NPC controller (no casting needed)
- Debug overlay built programmatically with ColorRect bars + heatmap cells; updates every _process
- Plan chunk timing: game-hours converted to ~8-30 real seconds for playable pacing
- `Input.action_press()` in SceneTree test scripts does NOT propagate to node `_input()` handlers — must directly set overlay state in test harness
- NPCs use `add_to_group("npcs")` in `_ready()` for easy lookup by social propagation and debug overlay

### Technical details
- Layer3Executive.LOCATIONS maps 16 town location names to world pixel positions
- ROLE_CONFIG defines home, work, and default daily schedule per role (4-7 chunks each)
- 27-dim GoEmotions vector: indices 0-11 positive, 12-22 negative, 23-26 cognitive/neutral
- Valence computed from positive vs negative sum ratio
- Social propagation cooldown: 300 real seconds per NPC pair
- NPC speech bubble: Label child on CharacterBody2D, shown for 4 seconds after dialogue

### Autoloads
- GameManager, NavigationManager, InferenceClient — all registered in project.godot
- Access pattern: iterate `get_tree().root.get_children()` and match by `.name`

## Task 4: Presentation Video

### What worked
- `DISPLAY=:0` with lavapipe software renderer works for `--write-movie` AVI capture at 30 FPS (no GPU needed)
- Keyframe-based camera system: array of {frame, pos, zoom, speed} dicts, lerp between them in `_process()`
- Direct debug overlay manipulation: set `_active`, `visible`, `_selected_npc` directly instead of simulated input (Input.action_press doesn't propagate to node `_input()` in SceneTree scripts)
- Closest NPC pair detection for framing NPC interactions mid-video
- ffmpeg CRF 28 + slow preset produced 3.8 MB for 30s at 1280x720 — well under 50MB limit

### Technical details
- 900 frames at 30 FPS = exactly 30 seconds
- time_scale progression: 5.0 (normal activity) -> 30.0 (fast-forward day progression) -> 5.0 (close-up)
- Camera zoom range: 1.6x (wide establishing) to 4.0x (close-up NPC follow)
- AVI output from Godot is MJPEG; must convert to H.264 MP4 for compatibility
