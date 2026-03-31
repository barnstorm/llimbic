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

## NPC Collision & Progress Awareness

### Architecture
- NPC and Player scenes have CollisionShape2D (RectangleShape2D 20x12, offset Y+8 for feet)
- NPC: collision layer 2, mask 6 (collides with NPCs + player). Player: layer 4, mask 2 (collides with NPCs)
- Player added to "player" group; NPCs find player via `get_tree().get_first_node_in_group("player")`
- Player is included in perception entity list — NPCs see the player through the same FOV cone as other NPCs

### Progress tracking (Layer 1)
- Controller reports intended vs actual movement to `layer1.update_progress()` each tick
- `is_stalled` = true when <30% expected displacement sustained for >0.4s
- Onset spike fires once per stall episode: frustration +0.15 to +0.40 (proportional to task_momentum), momentum breaks -0.15
- Spike re-arms when stall clears — including during observe pauses (velocity=0 → `update_progress` not called → spike re-arms)
- This means: stall → spike → observe → resume → stall again → NEW spike. Frustration escalates across cycles.
- Frustration feeds observe tendency generically (`observe = 0.2 + attention*0.3 + frustration*0.4`), no stall-specific flag needed
- When stalled, observe cooldown bypassed (2s instead of 8s) and `_find_interesting_entity` returns closest entity instead of novel-only

### Dynamic pathfinding
- On CharacterBody2D collision during `_follow_path`, controller re-paths with obstacle's tile + 4 neighbors disabled in AStar grid
- 1s cooldown on re-pathing to avoid per-frame recalculation
- `NavigationManager.get_nav_path()` accepts optional `avoid_positions` array, temporarily disables tiles via `astar.set_point_disabled()`

### Per-NPC logging
- Brain opens `logs/{name}.log` at setup, logs action changes (with frust/momentum/observe), stall onset/clear, tagged memory events (via callback on MemorySystem), and chunk transitions
- `tail -f logs/hugo.log` to watch a specific NPC in real time

### What we learned
- Bolting on a "blocked" handler is wrong — the NPC should perceive obstacles through existing FOV, feel lack of progress through drives, and respond through existing action priorities
- The missing perception was the root cause: Player wasn't in the entity list, so NPCs literally couldn't see what was blocking them
- Single-tile AStar avoidance insufficient — player collision shape spans tile boundaries. Disabling center + 4 neighbors forces real detours
- Stall spike must re-arm after any pause (observe, reorientation) otherwise the NPC gets one reaction then grinds forever
- Frustration→observe coupling should be general, not stall-gated: frustrated agents attend more to their environment regardless of cause

## Hebbian Neural Network (Layer 1 Substrate Rewrite)

### Architecture
- HebbianNetwork (RefCounted) lives inside Layer1Substrate — external API unchanged
- 19 fixed neurons: 4 drive, 3 task, 8 sensory (protected), 5 action
- Up to 32 dynamic neurons via neurogenesis (stress/novelty/reward)
- ~25 initial weighted connections, grows via Hebbian learning and spontaneous association
- Drive/task/action properties are getters/setters that read/write neuron activations
- Trust and place_familiarity remain non-neural dictionaries

### What worked
- GDScript property getters/setters (`var energy: float: get: return ...`) maintain perfect backward compatibility — no external code needed changes
- Baseline drift function preserves exact game feel from the old hardcoded update; network connections add learned adjustments on top
- Action neuron baselines (floors) prevent tendency collapse — without them, decay drains action neurons to zero
- Propagation at `weight * 0.1 * delta * 60` scale keeps network effects proportional without overwhelming baseline drift
- Decay of 0.998/frame (~0.887/sec) balances stability with responsiveness
- Pair rotation penalty in Hebbian learning prevents the same connection from monopolizing all learning

### Technical details
- Sensory neurons are protected (network propagation cannot modify them) — set directly each tick from context
- Task neurons use 0-100 internal scale, exposed as 0-1 via getters to match old interface
- Stall detection remains mechanical (not neural) — `update_progress()` unchanged
- Reorientation timer remains mechanical timing
- Hebbian learning: `delta_w = 0.01 * lr_mod * (v1/100) * (v2/100)`, weight decay 0.001, top K=2 co-activated pairs per 0.5s cycle
- Neurogenesis triggers: stress (frustration >75% OR sustained >3s), novelty (familiarity <30% sustained >5s), reward (drive recovery after override)
- Stress neurons inhibit frustration (-0.1 weight) and are activated by frustration (+0.3 weight) — negative feedback loop
- Neurogenesis caps: stress=5, novelty=6, reward=6, global=32. When cap reached, existing neurons strengthened instead
- Reference implementation: Dosidicus (Python, github.com/ViciousSquid/Dosidicus) — ported core Hebbian + neurogenesis patterns to GDScript

## Data-Driven Personas, Prompt Wrappers, Closed Loop

### Architecture
- NPC persona data lives in `data/npcs/{name}.json` — single source of truth per NPC (identity, personality, schedule, drives, neural biases, emotion baseline, fallback dialogue, relationships, night behavior)
- Location data in `data/locations.json` — eliminates duplication between Python and GDScript
- `scripts/persona_loader.gd` (GDScript) and `server/persona_loader.py` (Python) both load from same JSON files
- `server/prompt_builder.py` builds persona preamble for every L3 LLM call (name, traits, speech style, backstory, emotions, situation, anti-boilerplate rules)
- `scripts/emotion_engine.gd` — deterministic emotion projection + modulation, replaces L2 LLM. Runs every tick.

### What worked
- JSON persona files work cleanly from both GDScript (`JSON.parse_string`) and Python (`json.load`)
- GDScript static methods on RefCounted work for persona_loader (no autoload needed)
- `layer3_executive.gd` static var for LOCATIONS with lazy loading from JSON — preserves the `L3Cls.LOCATIONS` pattern used by npc_brain.gd
- Emotion engine persona baseline gravity (97% current + 3% baseline per tick) gives each NPC a distinct emotional "home" without being rigid
- Continuous modulation (every tick instead of chunk-change-only) eliminates the 5-30s dead zone where emotions changed but behavior didn't
- Urgency replan with 30s debounce prevents flooding while still being responsive to L1 spikes

### Technical details
- Persona JSON `night_behavior.override` is null for go-home NPCs, a dict for Guard (night patrol) and Innkeeper (late hours). `go_home_hour` of 99.0 for Guard effectively means "never go home"
- `neural_biases` array in persona JSON maps directly to `_adjust_weight()` calls in HebbianNetwork — adds connections on top of the universal set
- EmotionEngine event keyword matching is simple `in` substring check — "fled" matches "Fled from Roland", "broken" matches "Discovered broken Forge"
- L3 server request models all gained `npc_name` field. Server looks up persona by name and builds preamble. Backward compatible — field defaults to ""
- `_chunk_outcomes` array in npc_brain tracks last 5 chunk results (completed/completed_with_difficulty/failed). Included in L3 planning context
- L2 server (port 8420) still runs but unused — projection and modulation are both deterministic GDScript now
- `update_layer2()` in npc_brain.gd is now a no-op — L2 runs inside `update_layer1()` via `layer2.update_deterministic()`
- The `_l2_timer` in npc_controller.gd was removed — no separate L2 cadence needed

## Task 10: Perception Foundation — OccluderSystem + SensorSystem

### Architecture
- OccluderSystem (autoload): extracts wall boundary line segments from collision_map.png using edge detection on horizontal and vertical tile boundaries. Merges collinear edges into runs. Stores in spatial grid (10-tile cells) for fast lookup.
- SensorSystem (autoload): two-phase vision queries. Phase 1: range + arc broad-phase reject. Phase 2: analytical line-segment intersection raycast against occluder segments — no physics engine dependency.
- SensorProfile: per-actor sensor config loaded from persona JSON `sensor_profile` section, with sensible defaults (96px range, 90deg arc).
- SensoryResultTypes: factory functions for VisionResult and HearingResult dictionaries, plus standard sample point offsets.

### What worked
- Edge detection on tile boundaries (blocked vs walkable transitions) produces clean wall segments. Map edge treated as blocked for boundary detection.
- Merging collinear edges into runs reduced segment count: 1148 segments from 140x100 map (vs potential thousands of individual tile edges).
- Parametric cross-product line-segment intersection with epsilon margins (0.001-0.999) avoids edge-touching false positives.
- Spatial grid with 10-tile (320px) cells provides fast broad-phase: center-of-map rect query returns ~53 candidate segments.
- Multi-sample raycasting (5 body points for actors, 1 for objects) gives graded exposure values — partial visibility when some samples hit but others are blocked.

### Technical details
- OccluderSystem autoloads after WorldObjectRegistry in project.godot. SensorSystem autoloads after OccluderSystem.
- Segment format: `{start: Vector2, end: Vector2, blocks_vision: bool, sound_damping: float, tags: Array}`
- Grid uses `Vector2i` keys for cells. `get_segment_indices_in_rect()` returns deduplicated indices for ray testing.
- Vision test at town_square (2096,800) showed 80% exposure for 48px-apart targets — one sample clipped a nearby wall edge. This is correct behavior (partial occlusion).
- Wall-blocked vision test (through building walls) correctly returned 0% exposure.
- Actor sample offsets: center + top(0,-8) + left(-10,0) + right(10,0) + bottom(0,8). Object: center only.
- `_segments_intersect()` is a static method for reuse. Uses parametric t,u in (0.001, 0.999) range.
- Persona JSON can optionally include `sensor_profile` dict to customize per-NPC vision range, arc, offsets. Falls back to defaults if absent.

## Task 11: StimulusRegistry + Hearing Pipeline

### Architecture
- StimulusRegistry (autoload): manages world stimuli with spatial grid (320px cells). Each stimulus has position, radius, strength, duration, tags, emitter_id. Transient stimuli auto-expire via `_process()`.
- SensorSystem gained `query_hearing()` and `query_hearing_all()` for analog hearing with sound attenuation through occluders.
- 3-ray occlusion: center ray + two perpendicular offset rays (12px spread). Best (least occluded) ray wins. Each wall segment's `sound_damping` (0.8 default) reduces signal multiplicatively: `factor *= (1 - damping)`.
- Speech stimuli emitted via `npc_controller.speak()` instead of direct `perception.hear()` calls. Player speech emitted via interaction_system.gd.
- Footstep stimuli emitted from `_follow_path()` every 0.8s while NPC is moving (radius=48px, strength=0.15, duration=0.5s).

### What worked
- Spatial grid in StimulusRegistry provides fast broad-phase for range queries, same pattern as OccluderSystem.
- Best-of-3-rays approach for sound occlusion: avoids edge cases where a single ray grazes a wall corner, while keeping computation cheap.
- Distance falloff `1.0 - dist/radius` (linear) gives natural attenuation without complex physics.
- Uncertainty in estimated_source_pos: `randf_range(-uncertainty, uncertainty)` proportional to `(1 - clarity) * radius * 0.5` — faint sounds are poorly localized, clear sounds are precise.
- `_direction_to_name()` static method on npc_brain converts direction vectors to compass names for memory events ("heard something to the east").

### Technical details
- StimulusRegistry autoloads after OccluderSystem and before SensorSystem in project.godot.
- SensorSystem finds StimulusRegistry in `_ready()` via root children iteration.
- npc_brain gains `_sensor_system` and `_sensor_profile` via `set_sensor_autoloads()`, called from npc_controller after brain setup.
- Hearing pipeline in `update_perception()`: if `_sensor_system` is available, uses `query_hearing_all()` batch query. Falls back to legacy `perception.consume_heard()` if not.
- Speech stimuli carry the speech text (truncated to 60 chars) in the tags array for retrieval by the hearing pipeline.
- High clarity (>0.6) hearing produces "Heard X say: Y" memory events. Low clarity produces "Heard someone speaking to the east" — uncertain, imprecise.
- Footsteps only logged in memory when perceived_volume > 0.3 (prevents spam).
- Wall occlusion confirmed working: positions (3000,1500)->(3200,1500) have 4 wall segments between them, producing 99.8% occlusion loss.
- Town square area (2096,800) is open space — 0% occlusion between nearby positions, as expected.
- Semantic distinction preserved: vision is binary+exposure, hearing is analog+uncertain. Vision: "I see Edith." Hearing: "I heard something east of me."

## Task 12: Consumer Migration + Debug Visualization

### Architecture
- perception.gd is now a thin cache: stores last VisionResult per entity, last HearingResult per stimulus. No FOV cone math — all queries go through SensorSystem.
- NPCBrain.update_perception() uses SensorSystem.query_vision() for every entity and object candidate. Results include graded exposure (0-1) and confidence.
- Social propagation uses SensorSystem.query_vision() for mutual visibility check before conversation, with fallback to cached visible_entities.
- Player gets an ObserverProfile (sensor_profile dict) with wider range (128px) and arc (120deg) for future features.
- Debug overlay draws: FOV cones (all NPCs), vision rays (selected NPC: green=visible with sample dots and exposure%, red=blocked), occluder wall segments (semi-transparent red), active stimuli (pulsing circles colored by type), hearing direction arcs with volume meters.

### What worked
- SensoryResultTypes.actor_sample_offsets() / object_sample_offsets() cleanly separate entity vs object query configurations.
- perception.gd retained facing_vector and get_fov_cone_points() for debug overlay — no downstream breakage.
- Recording vision queries and hearing results in perception (last_vision_queries, last_hearing_results) provides real debug data without separate debug code paths.
- Graded exposure (0.60 at 50px, 0.80 at 48px, 1.00 at 71px open area) gives richer information than binary visible/not-visible.
- Memory events now include confidence-weighted observations ("barely visible" suffix at low confidence).
- All existing behaviors preserved: object discovery, social propagation, drive overrides, examine actions all continue working.

### Technical details
- NPCs at spawn (early morning) are typically 100-300px apart — outside 96px vision range. Natural convergence takes several game-hours. Tests requiring visibility must force proximity or wait.
- `load("res://scripts/sensory_result_types.gd")` is called per-frame inside update_perception() for offsets. GDScript caches loaded resources so this is not a performance concern.
- Social propagation visibility check loads SensorProfile and SensoryResultTypes scripts each pulse. Since pulses are 5s apart, this is negligible.
- perception.can_see() retained as legacy fallback but now checks _vision_cache instead of computing cone math. Not recommended for new code — use SensorSystem directly.
- debug_overlay.gd finds OccluderSystem, StimulusRegistry, SensorSystem in _setup_fov_drawing() via root children iteration.
- _draw_world_text() uses ThemeDB.fallback_font for world-space text rendering (exposure percentages).

## Task 13: Presentation Video (Perception System)

### What worked
- Force-positioning NPCs into clusters (within 96px vision range) is essential for showcasing vision rays — natural spawn positions are 100-300px apart, outside vision range.
- Maintaining cluster via gentle lerp pull-back (`_maintain_cluster`) keeps NPCs from wandering during the vision demo phase.
- Gradually moving an NPC from behind a wall into view (`lerp` over frames) creates a clear occlusion→visible transition with exposure changing from 0 to >0.
- Emitting speech stimuli every 30 frames (1s) during hearing phase ensures `last_hearing_results` stays populated for arc visualization.
- Slowing `time_scale` to 2-3 during hearing phase gives more real-time for stimulus processing and visualization.
- Red blocked vision rays are only drawn within 200px range — targets must be close enough for the red ray to appear on screen.

### Technical details
- Video: 4.7MB MP4 (CRF 28, slow preset) for 30s at 1280px — well under 50MB limit.
- 6 cinematic phases: occluder wide shot → green vision rays → red blocked rays/occlusion → hearing arcs → exposure gradient → wide pullback.
- `_emit_speech_stimuli()` emits from all NPCs within 200px of observer — ensures multiple hearing results with varying volume/clarity.
- NPC nameplate overlap when clustered is a known cosmetic issue (note severity, not blocking).
- Vision ray z-order renders on top of sprites — cosmetic, doesn't affect demo clarity.
