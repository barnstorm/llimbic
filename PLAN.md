# Game Plan: Burg — Adaptive NPC Town Simulation

## Game Description

A simulation-first adaptive NPC town built on the Smallville map from the Generative Agents project. The architecture treats NPCs as layered adaptive agents: Layer 1 is a numeric behavioral substrate (drives, momentum, interruption thresholds, trust, familiarity), Layer 2 uses a TinyChat15M-class local model to project Layer 1 state onto a fixed 27-dimensional GoEmotions coordinate surface and modulate back, and Layer 3 uses SmolLM2-135M for executive planning (daily agenda, role obligations, social goals, dialogue intent). No cloud LLMs. No GPT-class models. All inference is local.

The player walks around the top-down pixel art town, interacts with NPCs (talk, block, help, disrupt), and observes how the layered AI produces believable, continuous, path-dependent behavior. A debug overlay lets the player inspect any NPC's internal state across all three layers including the 27-dim emotion vector.

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
