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
- **Status:** pending
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
