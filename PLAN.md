# Game Plan: Burg — Adaptive NPC Town Simulation

## Game Description

A simulation-first adaptive NPC town built on the Smallville map from the Generative Agents project. The architecture treats NPCs as layered adaptive agents with action-based control: Layer 1 is a numeric behavioral substrate (drives, momentum, interruption thresholds, trust, familiarity, reorientation cost) that selects moment-to-moment actions (move, pause, observe, flee, wander). Layer 2 uses SmolLM2-135M-Instruct to project Layer 1 state onto a fixed 27-dimensional GoEmotions coordinate surface and modulate back via southbound directives. Layer 3 uses SmolLM2-1.7B-Instruct for executive planning (daily agenda, role obligations, social goals, dialogue intent, reflection, memory compression). Both layers communicate via persistent WebSocket connections. No cloud LLMs. All inference is local.

The player walks around the top-down pixel art town, interacts with NPCs (talk, block, help, disrupt), and observes how the layered AI produces believable, continuous, path-dependent behavior. NPCs deviate from schedules when drives become urgent, pause to reorient after interruption, flee from distrusted entities, observe interesting newcomers, and wander at destinations instead of standing frozen. A debug overlay lets the player inspect any NPC's internal state across all three layers including the 27-dim emotion vector and current action.

Uses pre-existing assets from joonspk-research/generative_agents: a pre-rendered 4480×3200 town map (140×100 tiles at 32px), 48×48 character sprites (RPG Maker VX Ace format), and collision data extracted from the TMX.

## 1. World, Navigation & Characters
- **Depends on:** (none)
- **Status:** done
- **Targets:** scenes/main.tscn, scenes/player.tscn, scenes/npc.tscn, scripts/player_controller.gd, scripts/npc_controller.gd, scripts/camera_controller.gd, scripts/world_map.gd, scripts/navigation_manager.gd, project.godot
- **Goal:** Set up the complete game world using pre-rendered Smallville map with tile-based collision, player movement, NPC spawning with animated sprites, AStar2D pathfinding, and camera follow.
- **Verify:** Screenshot shows the colorful pixel art town map filling the viewport at ~2.5x zoom. Player character visible and clearly animated. Multiple NPCs visible walking along paths between buildings. A time display in the corner reads something like "8:30 AM".

## 2. Inference Backend
- **Depends on:** (none)
- **Status:** done
- **Targets:** server/inference_server.py, server/layer2_model.py, server/layer3_model.py, server/emotion_coords.py, server/requirements.txt
- **Goal:** Set up a Python FastAPI inference server running two local models: a ~15M parameter model for Layer 2 (projection/modulation) and SmolLM2-135M-Instruct for Layer 3 (planning/executive). The server exposes HTTP endpoints that Godot calls asynchronously. Models run on GPU (RTX 3080). The 27-dim GoEmotions coordinate system is defined here.
- **Requirements:**
  - **Model Stack:**
    - Layer 2: Use a ~15M-30M parameter model (e.g., TinyStories-33M, or the smallest available instruct-tuned model on HuggingFace). It performs bounded translation: given structured Layer 1 state + recent events, output an updated 27-dim coordinate vector. Stateless calls. Deterministic/near-deterministic outputs. Temperature ~0.1.
    - Layer 3: Use `HuggingFaceTB/SmolLM2-135M-Instruct`. It performs agenda formation, plan chunking, reflection, dialogue intent generation. Structured outputs only (JSON). Temperature ~0.3. Runs at slow cadence (not per-frame).
  - **GoEmotions 27-dim Coordinate System:**
    - Fixed vector: [admiration, amusement, approval, caring, desire, excitement, gratitude, joy, love, optimism, pride, relief, anger, annoyance, disappointment, disapproval, disgust, embarrassment, fear, grief, nervousness, remorse, sadness, confusion, curiosity, realization, surprise]
    - Each dimension is a bounded scalar 0.0-1.0
    - This is NOT the NPC's internal state — it is a projection surface and modulation handle
  - **Endpoints:**
    - `POST /layer2/project` — Input: Layer 1 state dict + recent events list + current emotion vector. Output: updated 27-dim vector + optional short summary string.
    - `POST /layer2/modulate` — Input: Layer 3 directives (structured text) + current emotion vector. Output: modulation parameters dict (learning_rate_mod, exploration_bias, attention_weights, interruption_sensitivity, persistence_scale — all bounded floats).
    - `POST /layer3/plan` — Input: role, memory_summary, current_context, emotion_summary. Output: JSON with agenda (list of plan chunks), each chunk having target_location, duration, priority, purpose.
    - `POST /layer3/reflect` — Input: memory_events list. Output: JSON with reflections (list of summary strings) and concerns (list of open-loop strings).
    - `POST /layer3/dialogue` — Input: role, emotion_summary, relationship_context, recent_events. Output: JSON with intent (string) and utterance (string).
    - `GET /health` — Returns model status and GPU memory usage.
  - **Performance:** Layer 2 calls should complete in <100ms. Layer 3 calls should complete in <500ms. Models loaded to GPU at startup. Both models can coexist in VRAM (15M + 135M << 16GB).
  - **Startup:** Server starts with `python server/inference_server.py`, downloads models on first run, serves on localhost:8420.
- **Verify:** Server starts, health endpoint returns both models loaded. A test projection call returns a valid 27-dim vector. A test plan call returns structured JSON with plan chunks.

## 3. NPC AI & Town Life
- **Depends on:** 1, 2
- **Status:** done
- **Targets:** scripts/npc_brain.gd, scripts/layer1_substrate.gd, scripts/layer2_projection.gd, scripts/layer3_executive.gd, scripts/memory_system.gd, scripts/social_propagation.gd, scripts/npc_controller.gd, scripts/debug_overlay.gd, scripts/interaction_system.gd, scripts/game_manager.gd, scripts/inference_client.gd
- **Goal:** Implement the three-layer adaptive AI architecture with local model inference, structured memory, social propagation, player interaction, and a debug inspection overlay. Layer 1 runs entirely in GDScript at physics tick rate. Layer 2 and Layer 3 call the Python inference server asynchronously via HTTP.
- **Requirements:**
  - **Roles & Identity:** Each of the 8 NPCs has a distinct role: Baker, Guard, Herbalist, Courier, Blacksmith, Gossip, Farmer, Innkeeper. Roles determine home location, work location, default daily schedule, and social tendencies.
  - **InferenceClient (autoload):** A GDScript singleton that manages async HTTP requests to the Python inference server (localhost:8420). Queues requests, handles responses, provides callbacks. Falls back gracefully if server is unreachable (Layer 1 still runs, Layer 2 uses last-known vector, Layer 3 uses default schedule).
  - **Layer 1 — Behavioral Substrate (NO LLM, pure GDScript):** Each NPC maintains numeric state variables updated every physics tick:
    - `energy` (0-100): depletes during activity, recovers at home/rest spots
    - `hunger` (0-100): rises over time, satisfied by visiting food-related locations
    - `social_need` (0-100): rises over time, satisfied by proximity to other NPCs
    - `safety` (0-100): drops near unfamiliar/dangerous areas, recovers in known safe spaces
    - `task_momentum` (0-1): builds while pursuing a plan chunk, decays on interruption
    - `interruption_tolerance` (0-1): threshold for abandoning current task. Higher when deep in task.
    - `frustration` (0-1): accumulates from repeated interruptions, failed plans, or blocked paths
    - `trust` per-entity (dictionary): trust toward each NPC and the player
    - `place_familiarity` (dictionary): per-location comfort score, increases with visits
    - Action tendencies: `approach`, `avoid`, `observe`, `help`, `flee` — weighted by conditions
    - Path-dependent: two identical world states produce different behavior if arrival history differs
    - Layer 1 modulation inputs from Layer 2: learning_rate_mod, exploration_bias, attention_weights, interruption_sensitivity, persistence_scale — all bounded floats that bias Layer 1 calculations
  - **Layer 2 — Projection/Modulation (TinyChat15M via HTTP, medium cadence ~every 0.5 game-seconds):**
    - Northbound (projection): Collects Layer 1 state snapshot + recent events → calls `/layer2/project` → receives updated 27-dim GoEmotions vector + optional summary
    - Southbound (modulation): When Layer 3 issues directives → calls `/layer2/modulate` → receives bounded modulation parameters → applies to Layer 1
    - The 27-dim vector is stored on the NPC and used by the debug overlay, social propagation, and Layer 3
    - If server unreachable, retain last-known vector and skip update
  - **Layer 3 — Executive Planner (SmolLM2-135M via HTTP, slow cadence ~every 30 game-minutes):**
    - Calls `/layer3/plan` with role, memory summary, current context, top-5 emotion dimensions
    - Receives structured agenda: list of plan chunks with target_location, duration, priority, purpose
    - Calls `/layer3/reflect` periodically to compress memory into reflections and surface concerns
    - Calls `/layer3/dialogue` when player interacts, producing intent + utterance
    - Outputs directives to Layer 2 when plan changes (e.g., "prioritize safety", "push through delay")
    - Does NOT micromanage — sets goals and constraints, Layer 1 executes
  - **Memory System:** Each NPC stores:
    - Raw observations (last 20): who they saw, where, doing what
    - Tagged events (last 10): notable occurrences with salience score
    - Relationship state: trust changes with reasons
    - Place familiarity: per-location visit count and comfort
    - Unresolved concerns: open loops that bias planning
    - Summarized reflections: compressed by Layer 3 periodically
    - Active intentions: current plan chunks (survive interruption)
    - Failed strategies: recently blocked paths, failed plans
    - Socially acquired beliefs: with source identity + trust weight
    - Fast retrieval for Layer 1 (salience-triggered), slow retrieval for Layer 3 (relevance-driven)
  - **Social Propagation:** When two NPCs are within 2 tiles and both have openness > 0.3:
    - Exchange tagged events (50% chance per encounter, 5-minute cooldown per pair)
    - Transferred events get "second-hand" tag, salience reduced 30%
    - Trust-weighted acceptance: events from trusted sources stored with higher salience
    - Role-filtered: guards share security info more readily, merchants share trade info
    - Location-based amplification: public zones (square, market) get 2x exchange chance
    - Decay: old rumors fade unless refreshed, minor incidents disappear
  - **Player Interaction:** Space/Enter near NPC (within 1.5 tiles):
    - Triggers Layer 3 `/layer3/dialogue` call with full context
    - Shows speech bubble with the generated utterance
    - Interaction modifies trust, creates tagged event in NPC memory
    - Interrupting high-commitment tasks lowers trust
  - **Player Disruption:** Blocking NPC path = interruption event. Loitering near work location >10s = observer event (frustration +0.05). These feed into Layer 1 and get projected by Layer 2.
  - **Debug Overlay (Tab key):**
    - Click NPC to select. Shows panel with:
      - Name, role, current action
      - Layer 1 raw values as labeled progress bars
      - Layer 2: full 27-dim GoEmotions vector as a compact heatmap (27 colored cells) + top-3 dimensions as text labels
      - Layer 3: current plan chunks (active highlighted), upcoming listed
      - Recent memory: last 3 tagged events
      - Current modulation parameters from Layer 2
    - All NPCs show colored dot: green=positive valence dominant, yellow=neutral, orange=negative, red=high-arousal negative
  - **Time Scales (enforced separation):**
    - Fast: Layer 1 behavioral substrate — every physics tick
    - Medium: Layer 2 projection/modulation — every ~0.5 game-seconds
    - Slow: Layer 3 planning — every ~30 game-minutes
    - Very slow: social propagation pulse — every ~5 game-minutes
  - **Day Cycle:** NPCs return home ~21:00. Energy recovers faster at home. Innkeeper active until 23:00. Guard patrols at night.
- **Verify:** Screenshot shows debug overlay open with an NPC selected. Panel displays Layer 1 bars, Layer 2 27-dim emotion heatmap with top dimensions labeled, and Layer 3 plan chunks. Colored dots visible above other NPCs. At least one NPC walking purposefully toward a plan-chunk destination (not random wandering). Server health endpoint confirms both models loaded.

## 4. Presentation Video
- **Depends on:** 1, 2, 3
- **Status:** done
- **Targets:** test/presentation.gd, screenshots/presentation/gameplay.mp4
- **Goal:** Create a ~30-second cinematic video showcasing the completed NPC town simulation.
- **Requirements:**
  - Write test/presentation.gd — a SceneTree script (extends SceneTree)
  - Showcase representative gameplay via simulated input or scripted animations
  - ~900 frames at 30 FPS (30 seconds)
  - Use Video Capture from godot-capture (AVI via --write-movie, convert to MP4 with ffmpeg)
  - Output: screenshots/presentation/gameplay.mp4
  - Camera pans across the town showing NPCs going about their routines
  - Zoom in on an NPC walking between locations, show them interacting with another NPC
  - Toggle the debug overlay to show the 27-dim emotion heatmap and Layer 3 plan
  - Show time passing and NPCs adjusting behavior (morning routine → afternoon activities)
  - Smooth camera transitions between points of interest
  - 2D: camera pans and smooth scrolling, zoom transitions between overview and close-up
- **Verify:** A smooth MP4 video showing polished gameplay with no visual glitches.

## 5. World Object Registry & Object Perception
- **Depends on:** 1, 3
- **Status:** done
- **Targets:** scripts/world_object_registry.gd, scripts/perception.gd, scripts/memory_system.gd, scripts/npc_brain.gd, scripts/npc_controller.gd, scripts/debug_overlay.gd, project.godot
- **Goal:** Add a persistent world object registry and extend NPC perception + memory to discover, observe, and remember structured world objects — not just other NPCs and speech.
- **Requirements:**
  - **WorldObjectRegistry (autoload):** A singleton that holds all world objects. Each object is a Dictionary:
    - `id`: String (unique, e.g. "bakery_oven_01")
    - `name`: String (display, e.g. "Brick Oven")
    - `type`: String (category, e.g. "tool", "container", "supply", "furniture", "resource")
    - `position`: Vector2 (world coordinates)
    - `location`: String (which named location it belongs to, e.g. "bakery")
    - `state`: String (e.g. "working", "broken", "empty", "locked", "full")
    - `owner`: String (NPC name who owns/tends it, or "" for public)
    - `properties`: Dictionary (type-specific, e.g. {"fuel": 80, "capacity": 50})
    - `discoverable`: bool (true = NPCs must see it to learn about it)
    - `role_affinity`: Array[String] (roles that care about this object, e.g. ["Baker"])
  - **Initial Objects (15-20):** Populate the registry with objects tied to existing LOCATIONS. Examples:
    - Bakery: brick oven (tool, Baker), flour sacks (supply), bread basket (container)
    - Guard post: weapon rack (tool, Guard), lantern (furniture)
    - Herbalist shop: herb drying rack (tool, Herbalist), mortar and pestle (tool), remedy shelf (container)
    - Blacksmith: anvil (tool, Blacksmith), forge (tool), metal ingots (supply)
    - Inn: pantry (container, Innkeeper), guest ledger (furniture), ale barrel (supply)
    - Farm: plow (tool, Farmer), seed storage (container), water trough (resource)
    - Market: market stall (furniture), trade goods (supply)
    - Town square: well bucket (tool), notice board (furniture)
    - Some objects start in a non-default state (broken, empty) to create discovery events
  - **Object Perception:** Extend `perception.gd` with:
    - `visible_objects: Array[Dictionary]` — populated by new `update_object_vision()` method
    - Same FOV cone rules as entity vision (range, angle)
    - Object dict: `{id, name, type, position, distance, state, owner}`
    - Objects are only visible if within FOV and within VISION_RANGE
  - **Object Memory:** Extend `memory_system.gd` with:
    - `known_objects: Dictionary` — `object_id -> {name, type, last_seen_position, last_seen_state, last_seen_time, learned_from, location}`
    - `add_object_knowledge(id, name, type, position, state, location, source)` — upsert
    - `get_objects_at_location(location) -> Array` — filter known objects
    - `get_objects_by_type(type) -> Array` — filter by type
    - `get_object_summary() -> String` — for Layer 3 planning context
    - Objects learned from direct observation have higher confidence than second-hand
  - **Brain Integration:** In `npc_brain.update_perception()`:
    - Call `perception.update_object_vision()` with objects from WorldObjectRegistry
    - For each newly visible object: add to memory via `memory.add_object_knowledge()`
    - If object state differs from last known: create tagged event ("Discovered broken oven at bakery")
    - Role-relevant discoveries get higher salience (Baker sees broken oven = 0.8, Guard sees it = 0.4)
  - **Debug Overlay:** Add an "Objects" section showing selected NPC's known objects (name, location, state)
- **Verify:** Screenshot shows debug overlay with object knowledge section. At least one NPC has discovered objects at their work location. A tagged event in memory shows an object discovery. WorldObjectRegistry reports 15+ registered objects via a print at startup.

## 6. Object-Aware Planning & Social Object Knowledge
- **Depends on:** 5
- **Status:** done
- **Targets:** scripts/layer3_executive.gd, scripts/npc_brain.gd, scripts/social_propagation.gd, scripts/memory_system.gd, scripts/interaction_system.gd
- **Goal:** NPCs plan around discovered objects, act on object-related discoveries, and share object knowledge through social propagation. Plans can now target specific objects, not just named locations.
- **Requirements:**
  - **Object-Aware Planning (Layer 3):**
    - Plan chunks gain optional `object_id` and `object_action` fields (e.g. `{"location": "bakery", "object_id": "bakery_oven_01", "object_action": "use", "purpose": "Fire up the oven"}`)
    - `update_plan()` receives object summary from memory in addition to existing context
    - Role-default schedules include object references where natural (Baker's "Bake morning bread" chunk targets the oven)
    - When an NPC discovers a broken/empty object in their domain, it creates a concern → triggers replanning with object context → new chunk to address it ("Fix the oven", "Restock flour")
  - **Object Interaction Actions (Brain):**
    - New action type: `EXAMINE` — NPC stops at object position, faces it, spends 1-2s examining. Creates observation + updates object memory with current state.
    - Trigger: NPC arrives at destination with an `object_id` chunk, or sees a role-relevant object they haven't examined recently (>5 minutes)
    - After examining: if object state is problematic (broken, empty), add tagged event + concern
  - **Social Object Knowledge (Propagation):**
    - Extend `_exchange_events()` to also exchange object knowledge
    - When NPCs converse, they can share known objects: `memory.add_object_knowledge()` with `source=other_npc_name`
    - Role-filtered: Baker more likely to share info about bakery objects, Guard about security-relevant objects
    - Trust-weighted: object knowledge from trusted sources stored with "reliable" flag
    - Creates natural information flow: "Mabel told me the inn pantry is empty"
  - **Drive Override Enhancement:**
    - Hunger drive override now checks known food-related objects (e.g., if NPC knows bread basket is full at bakery, prefer bakery over generic FOOD_LOCATIONS)
    - Object knowledge enriches drive override target selection
  - **Dialogue Context:**
    - `request_dialogue()` and conversation context include relevant object knowledge
    - NPCs can mention objects they know about in conversation: "The oven's been acting up" or "I heard the pantry is empty"
  - **Interaction System:**
    - When player chats with NPC, dialogue context includes NPC's object knowledge summary
    - NPC responses can reference discovered objects naturally
- **Verify:** Screenshot shows an NPC with an object-targeting plan chunk visible in debug overlay. At least one NPC has replanned due to discovering a problematic object. Social propagation log shows object knowledge being shared between NPCs. A conversation between player and NPC references a discovered object.

## 7. Presentation Video (Updated)
- **Depends on:** 5, 6
- **Status:** done
- **Targets:** test/presentation.gd, screenshots/presentation/gameplay.mp4
- **Goal:** Create a ~30-second cinematic video showcasing the object knowledge system in action.
- **Requirements:**
  - Write test/presentation.gd — a SceneTree script (extends SceneTree)
  - ~900 frames at 30 FPS (30 seconds)
  - Use Video Capture from godot-capture (AVI via --write-movie, convert to MP4 with ffmpeg)
  - Output: screenshots/presentation/gameplay.mp4
  - Show an NPC arriving at their workplace and discovering objects (debug overlay visible)
  - Show the NPC examining an object in a non-default state (e.g. broken oven)
  - Show the debug overlay with object knowledge section populated
  - Show two NPCs conversing and object knowledge spreading via social propagation
  - Fast-forward to show replanning triggered by object discovery
  - Smooth camera transitions, 2D pans and zooms
- **Verify:** A smooth MP4 video showing object discovery, knowledge sharing, and object-aware planning with no visual glitches.

## 8. Hebbian Neural Network (Layer 1 Substrate)
- **Depends on:** 3
- **Status:** done
- **Targets:** scripts/hebbian_network.gd, scripts/layer1_substrate.gd, scripts/debug_overlay.gd, scripts/npc_brain.gd
- **Goal:** Replace hardcoded Layer 1 drive/tendency formulas with a genuine Hebbian neural network with neurogenesis.
- **Verify:** NPCs behave comparably to before. Debug overlay shows neural network section. Neurogenesis events visible after sustained stress.

## 9. Data-Driven Personas, Prompt Wrappers, Closed Control Loop
- **Depends on:** 8
- **Status:** done
- **Targets:** data/npcs/*.json, data/locations.json, scripts/persona_loader.gd, scripts/emotion_engine.gd, scripts/layer2_projection.gd, scripts/npc_brain.gd, scripts/layer3_executive.gd, scripts/npc_controller.gd, server/persona_loader.py, server/prompt_builder.py, server/layer3_model.py, server/layer3_server.py, scripts/inference_client.gd
- **Goal:** Three interconnected changes: (A) NPC identity in JSON persona files as single source of truth, (B) persona-grounded prompt wrappers for all L3 LLM calls, (C) closed L1↔L2↔L3 feedback loop with deterministic emotion engine.
- **Verify:** NPCs load from persona files. L3 prompts include persona preamble. Emotion→drive feedback visible in debug overlay every tick. Urgency replanning fires on frustration spikes.

## 10. Perception Foundation: OccluderSystem + SensorSystem Vision
- **Depends on:** 1, 5
- **Status:** done
- **Targets:** scripts/occluder_system.gd, scripts/sensor_system.gd, scripts/sensor_profile.gd, scripts/sensory_result_types.gd, project.godot
- **Goal:** Build the shared physical perception layer — occluder geometry extracted from the collision map, observer profiles per actor, and two-phase vision queries with multi-sample line-of-sight raycasting. This replaces the simple angle+range checks with real occlusion.
- **Requirements:**
  - **OccluderSystem (autoload):** Extracts wall segments from collision_map.png (140x100 grayscale, white=blocked). Uses marching squares or edge detection to build line segments representing wall boundaries. Each occluder segment has: shape (start/end points), blocks_vision (bool, default true for walls), sound_damping (float, 0.0-1.0, default 0.8 for walls), optional tags (wall, door, window, foliage). Provides `get_occluders_in_rect(rect: Rect2) -> Array` for broad-phase spatial queries. Store segments in a spatial grid (e.g., 10x10 tile cells) for fast lookup.
  - **SensorProfile (resource/dictionary):** Per-actor sensor configuration: vision_range (default 96px/3 tiles), vision_arc_deg (default 90), eye_offset (Vector2, default Vector2.ZERO), hearing_threshold (default 0.1), hearing_sensitivity (default 1.0), ear_offset (Vector2, default Vector2.ZERO). Loaded from persona JSON (add `sensor_profile` section) with sensible defaults.
  - **SensoryResultTypes:** VisionResult dictionary: {visible: bool, distance: float, exposure: float (0-1 fraction of visible samples), confidence: float, sample_hits: int, sample_total: int, blocked_by: Array of occluder tags, last_visible_point: Vector2}. HearingResult dictionary: {heard: bool, perceived_volume: float, clarity: float, distance: float, direction: Vector2, occlusion_loss: float, estimated_source_pos: Vector2}.
  - **SensorSystem (autoload):** `query_vision(observer_pos: Vector2, observer_facing: Vector2, profile: Dictionary, target_pos: Vector2, target_sample_points: Array[Vector2]) -> Dictionary` (VisionResult). Two-phase pipeline: (1) Broad phase: range check + facing arc check, reject cheaply. (2) Narrow phase: raycast from observer eye_offset to each target sample point (center + 4 body offsets for actors, center-only for objects). A ray succeeds if it doesn't intersect any vision-blocking occluder segment. Visible if ANY sample hits. Exposure = hits/total. Confidence = exposure * (1.0 - distance/range).
  - **Analytical raycasting:** Line-segment intersection against occluder segments. No physics engine dependency. For each ray, query OccluderSystem spatial grid for candidate segments along the ray path, test intersection with each.
  - **Target sample points for actors:** center + 4 offsets (top ±8px, left ±10px, right ±10px, bottom). For objects: center only.
  - **Decision locks:** Any visible sample = visible. Explicit occluder data (not scene traversal). Consumers receive graded results.
- **Verify:** Screenshot shows game running normally (no regression). Print output confirms OccluderSystem loaded N wall segments from collision map. A test call to `SensorSystem.query_vision()` from an NPC position toward another NPC returns a valid VisionResult with exposure > 0 when unobstructed and exposure = 0 when a wall intervenes.

## 11. StimulusRegistry + Hearing Pipeline
- **Depends on:** 10
- **Status:** done
- **Targets:** scripts/stimulus_registry.gd, scripts/sensor_system.gd, scripts/sensory_result_types.gd, project.godot
- **Goal:** Build the stimulus system for world-emitted events (speech, footsteps, presence) and add hearing queries to SensorSystem with sound attenuation through occluders.
- **Requirements:**
  - **StimulusRegistry (autoload):** Manages active world stimuli. Each stimulus: {id: String, type: String (visual_presence/speech/footstep/impact), position: Vector2, radius: float, strength: float (0-1), duration: float (seconds, -1 for persistent), tags: Array, emitter_id: String, created_at: int (ticks)}. Methods: `emit(type, position, radius, strength, duration, tags, emitter_id) -> String` (returns id), `remove(id)`, `get_stimuli_in_range(pos, radius) -> Array`, `tick(delta)` (removes expired stimuli). Spatial grid for fast range queries. Persistent stimuli (visual_presence) updated by actors each tick. Transient stimuli (speech, footstep, impact) auto-expire.
  - **Hearing query on SensorSystem:** `query_hearing(listener_pos: Vector2, profile: Dictionary, stimulus: Dictionary) -> Dictionary` (HearingResult). Broad phase: check if stimulus within max effective radius (stimulus.radius * stimulus.strength / profile.hearing_threshold). Narrow phase: cast 1-3 rays from stimulus position to listener. Each occluder segment along the ray reduces signal by its sound_damping factor (multiplicative, not additive). Final perceived_volume = stimulus.strength * distance_falloff * occlusion_factor. Heard if perceived_volume >= profile.hearing_threshold. Clarity = perceived_volume / stimulus.strength. Direction = normalized vector from listener to stimulus. Estimated_source_pos = stimulus.position + random offset proportional to (1.0 - clarity) — uncertain hearing produces imprecise localization.
  - **Batch query:** `query_hearing_all(listener_pos, profile) -> Array[Dictionary]` — queries all stimuli in range, returns only heard results. Uses StimulusRegistry.get_stimuli_in_range() for broad phase.
  - **Speech integration:** When NPCs speak (social propagation conversations, player interaction), emit a speech stimulus via StimulusRegistry instead of directly calling perception.hear().
  - **Footstep stimuli:** NPCs emit footstep stimuli while moving (low strength, small radius).
  - **Semantic choice:** Vision is binary+exposure. Hearing is analog+uncertain. Vision yields "I see Edith." Hearing yields "I heard something east of me."
- **Verify:** Print output confirms StimulusRegistry tracks active stimuli. A speech stimulus emitted at one position is heard by a nearby listener with appropriate volume. A wall between source and listener reduces perceived_volume. Estimated_source_pos has uncertainty proportional to occlusion.

## 12. Consumer Migration + Debug Visualization
- **Depends on:** 11
- **Status:** done
- **Targets:** scripts/npc_brain.gd, scripts/perception.gd, scripts/npc_controller.gd, scripts/debug_overlay.gd, scripts/social_propagation.gd, scripts/interaction_system.gd, scripts/player_controller.gd
- **Goal:** Migrate all perception consumers (NPC brain, social propagation, interaction system, player) to use SensorSystem queries instead of direct cone checks. Reduce perception.gd to a local result cache. Add debug visualization for vision rays and hearing.
- **Requirements:**
  - **perception.gd refactor:** Remove all FOV cone math. Becomes a thin cache: stores last VisionResult per entity, last HearingResult per stimulus. Updated by brain from SensorSystem query results. Retains facing_vector for SensorSystem calls.
  - **NPCBrain migration:** `update_perception()` calls `SensorSystem.query_vision()` for each candidate entity/object (using StimulusRegistry for candidates + direct NPC/player list). Stores graded VisionResults. Uses exposure/confidence for salience instead of binary visible/not-visible. Object perception uses same pipeline. Memory events now include confidence level.
  - **Hearing migration:** Brain calls `SensorSystem.query_hearing_all()` each tick. Processes HearingResults: high-clarity results create "Heard X say Y" events, low-clarity results create "Heard something from the east" events. Direction and estimated_source_pos feed into memory for spatial awareness.
  - **Social propagation:** Uses SensorSystem.query_vision() to check mutual visibility before initiating conversation (replaces direct perception.visible_entities check).
  - **Interaction system:** Player proximity check can optionally use SensorSystem for consistency.
  - **Brain contract:** npc_brain.gd NEVER computes visibility/audibility directly. All perception goes through SensorSystem. Brain receives graded results, not raw rays.
  - **Debug visualization:** Extend debug overlay with: (1) Vision rays from selected NPC to visible targets (green=hit, red=blocked, with sample points shown). (2) Hearing indicators: arcs showing sound direction, volume meters. (3) Occluder segments visible as semi-transparent lines when debug active. (4) Active stimuli shown as pulsing circles. Debug output reflects real queries — same code path as gameplay.
  - **Player sensor profile:** Player gets an ObserverProfile too, enabling future player-side perception features (hearing indicators, visibility feedback).
  - **Backward compatibility:** All existing behavior preserved — NPCs still see entities, discover objects, hear speech. The results are now richer (graded exposure, uncertain hearing) but the downstream effects (memory events, social propagation, planning) continue working.
- **Verify:** Screenshot shows debug overlay with vision rays from selected NPC to nearby entities (green lines to visible targets, red to occluded). Hearing direction indicators visible. Occluder segments drawn as overlay. NPCs behave comparably to before — walking routes, social interactions, object discovery all functional. An NPC behind a wall is NOT visible (exposure=0). An NPC in the open IS visible with exposure>0.

## 13. Presentation Video (Perception System)
- **Depends on:** 10, 11, 12
- **Status:** done
- **Targets:** test/presentation.gd, screenshots/presentation/gameplay.mp4
- **Goal:** Create a ~30-second cinematic video showcasing the new shared perception system.
- **Requirements:**
  - Write test/presentation.gd — a SceneTree script (extends SceneTree)
  - ~900 frames at 30 FPS (30 seconds)
  - Use Video Capture from godot-capture (AVI via --write-movie, convert to MP4 with ffmpeg)
  - Output: screenshots/presentation/gameplay.mp4
  - Show debug overlay with vision rays tracing from an NPC through open space (green) and being blocked by walls (red)
  - Show an NPC losing sight of another NPC as they walk behind a building
  - Show hearing: a speech stimulus propagating, one NPC hearing clearly (close), another hearing with uncertainty (far/occluded)
  - Show occluder segments overlaid on the map
  - Show the graded exposure/confidence values changing in the debug panel as an NPC partially emerges from cover
  - Smooth camera transitions, 2D pans and zooms
- **Verify:** A smooth MP4 video showing vision raycasting, occlusion, hearing attenuation, and debug visualization with no visual glitches.
