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
- NPCBrain (RefCounted) orchestrates Layer1, Layer2, Layer3, MemorySystem, and Perception per NPC
- All layer classes are RefCounted, instantiated from GDScript via `load().new()`
- InferenceClient: WebSocket to L2 (ws://localhost:8420/ws), WebSocket to L3 (ws://localhost:8421/ws). Both use multiplexed JSON-RPC. Graceful degradation if servers are down, 30s reconnect backoff.
- **Action-based control:** Brain calls `select_action(delta)` every tick, returning an action dict. Controller is a thin executor. Actions: MOVE_TOWARD, PAUSE, OBSERVE, FLEE_FROM, WANDER, IDLE. Pathfinding is one tool among many.
- Layer 1 runs every physics tick (pure GDScript drives/tendencies). Reorientation timer: 0.5-2s pause after interruption proportional to frustration.
- Layer 2 fires every ~2.0 real seconds per NPC (staggered, emotion vector projection via WebSocket)
- Layer 3 fires on game-time intervals (~30 game-minutes). Plans use role defaults; LLM only triggered for replanning on high frustration/concerns/failures.
- Social propagation pulses every 5 real seconds, checks NPC pairs within 64px, requires social_need > 30 + FOV visibility + interruption willingness check
- Drive overrides: brain overrides L3 plan destination when safety<30, energy<20, hunger>80, or social>85. Suspends current chunk, resumes after recovery.
- Reflection: every 2 game-hours or 5+ new tagged events, calls /layer3/reflect to compress memory
- Southbound modulation: Layer 3 chunk changes → directive string → Layer 2 modulate → Layer 1 params
- Role-filtered social propagation: guards share security events preferentially, trust-weighted salience
- Event decay: tagged events lose salience over time, removed below 0.1

### What worked
- Direct property access on RefCounted instances works fine from NPC controller (no casting needed)
- Debug overlay built programmatically with ColorRect bars + heatmap cells; updates every _process
- Plan chunk timing: game-hours converted to ~8-30 real seconds for playable pacing
- `Input.action_press()` in SceneTree test scripts does NOT propagate to node `_input()` handlers — must directly set overlay state in test harness
- NPCs use `add_to_group("npcs")` in `_ready()` for easy lookup by social propagation and debug overlay
- Wander at destination (random subtargets within 48px, 2-5s per leg, 0.4x speed) looks much more alive than frozen standing

### LLM prompting
- SmolLM2 breaks character ("I'm an AI") when prompted with "You are {name}" in multi-turn user/assistant format
- Fix: frame as dialogue writer ("Write one line of dialogue for a {role}") with conversation embedded as narrative text in a single prompt — not as user/assistant turns
- Explicit "never mention AI" rule needed in every prompt
- Chat uses single prompt with embedded transcript; dialogue/converse use "Write one line for..." framing

### Technical details
- Layer3Executive.LOCATIONS maps 16 town location names to world pixel positions
- ROLE_CONFIG defines home, work, and default daily schedule per role (4-7 chunks each)
- 27-dim GoEmotions vector: indices 0-11 positive, 12-22 negative, 23-26 cognitive/neutral
- Valence computed from positive vs negative sum ratio
- Social propagation cooldown: 60 real seconds per NPC pair
- NPC speech bubble: Label child on CharacterBody2D, shown for 4 seconds after dialogue
- HTTP result code 13 = RESULT_REQUEST_FAILED (connection refused). Must mark server unavailable on failure or requests pile up.
- WebSocket reconnect: 30s backoff prevents spam when server is down. Initial connect failure sets timer to 25s so first retry is in ~5s.

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

## Task 5: World Object Registry & Object Perception

### What worked
- WorldObjectRegistry as autoload with Dictionary-based objects works well. 21 objects registered across 8 locations.
- Perception `update_object_vision()` reuses the same FOV cone logic as entity vision — straightforward extension.
- Object memory upsert pattern: `known_objects[id] = {...}` with timestamp for freshness tracking.
- NPCs discover objects at their starting locations within ~10 frames (1 second at 10 FPS) since they start near their work locations.
- Role affinity salience: Baker discovering Brick Oven gets 0.8 salience, Guard seeing it gets 0.4.

### Technical details
- WorldObjectRegistry autoload must be listed after InferenceClient in project.godot autoload order.
- `_initialize()` in SceneTree test scripts runs before autoload `_ready()` — so `_world_obj_registry.objects` is empty at that point. Check object counts in `_process()` instead.
- Object positions are placed near the LOCATIONS coordinates (within VISION_RANGE of 96px) so NPCs discover them when at their work/home locations.
- Three objects start in non-default state: bakery_basket_01 (empty), smith_forge_01 (broken), inn_ale_barrel_01 (empty) — these trigger discovery events with state info.
- Debug overlay panel expanded by ~100px height to accommodate the Known Objects section.
- `npc_brain.set_autoloads()` gained optional third parameter `world_object_registry` for backward compatibility.

## Task 6: Object-Aware Planning & Social Object Knowledge

### What worked
- Plan chunks with `object_id` and `object_action` fields allow NPCs to target specific objects in their schedules.
- EXAMINE action (1-2s stop + face object) triggers reliably when NPC arrives at destination with object_id chunk, or while wandering at destination with unexamined chunk object.
- Object concern injection: NPCs discovering broken/empty objects in their domain immediately inject a "Fix/Restock" chunk into their plan agenda.
- Hunger drive override now checks `memory.get_food_objects()` for known stocked food locations before falling back to generic FOOD_LOCATIONS.
- Dialogue context enrichment: `get_object_dialogue_context()` provides notable object info (broken/empty/locked) for NPC conversations.
- Social object knowledge exchange: `_exchange_object_knowledge()` shares 1-2 objects per conversation, role-filtered and trust-weighted.
- Direct observation protection: second-hand object knowledge doesn't overwrite fresh (< 5 min) direct observations.

### Technical details
- `_should_examine()` must check `_last_examine_times.has(object_id)` for never-examined case. Using `get(id, 0)` and comparing `Time.get_ticks_msec() - 0 > 300000` fails early in runtime because the engine hasn't been running for 5 minutes yet.
- EXAMINE action is handled by npc_controller.gd alongside "observe" — both stop the NPC and face the target.
- `inject_object_concern_chunk()` inserts the fix chunk at `current_chunk_index + 1` so it's the next thing the NPC does.
- `get_object_target_position()` on Layer3Executive returns the object's world position if the current chunk has an object_id, allowing NPCs to walk to the exact object rather than just the location center.
- Debug overlay shows object IDs in plan chunks via `[object_id]` suffix, and EXAMINE action in purple.
- `memory.add_object_knowledge()` has a `reliable` parameter (bool) set true when the source NPC's trust > 0.6.
- Social propagation enriches conversation context with `get_object_dialogue_context()` so LLM-generated dialogue can reference discovered objects.

## Task 7: Presentation Video (Updated — Object Knowledge)

### What worked
- Keyframe-based camera system from Task 4 reused and extended for object-focused cinematic
- Tracking NPCs by role (`_find_npc_by_role`) to focus on specific object discovery events (Greta/broken forge, Edith/empty basket, Hugo/empty ale barrel)
- Direct manipulation of debug overlay (`_active`, `visible`, `_selected_npc`) continues to work for SceneTree scripts
- `_find_conversing_pair()` checks `_externally_locked` on NPCs to detect active conversations
- Boosting `social_need = 60.0` on all NPCs at startup increases probability of social propagation conversations during the video window
- Slowing `time_scale` to 3.0 during social propagation phase gives more real-time ticks for conversation pulses (5s interval)
- Non-default state objects (bakery_basket_01=empty, smith_forge_01=broken, inn_ale_barrel_01=empty) trigger immediate concern injection + replan, visible in first few seconds of simulation

### Technical details
- Social propagation pulse interval is 5 real seconds; conversations require NPCs within 64px, both social_need > 30, willingness to interrupt
- `_externally_locked` is true during active conversations — reliable proxy for detecting conversing NPCs
- ffmpeg frame extraction: `ffmpeg -ss {seconds} -i video.mp4 -frames:v 1 output.png` for VQA keyframes
- Video output: 3.6MB MP4 (CRF 28, slow preset) for 30s at 1280px — well under 50MB limit
