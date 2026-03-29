# Game Plan: Burg — Adaptive NPC Town Simulation

## Game Description

A simulation-first adaptive NPC town built on the Smallville map from the Generative Agents project. The architecture treats NPCs as layered adaptive agents: Layer 1 is a numeric behavioral substrate (drives, momentum, interruption thresholds, trust, familiarity), Layer 2 is a compact human-legible projection surface (caution, urgency, frustration, curiosity, commitment), and Layer 3 is an executive planner (daily agenda, role obligations, social goals). The town provides the ecology — persistent places, recurring routines, rumor propagation, player disturbance — that makes memory and planning consequential rather than decorative.

The player walks around the top-down pixel art town, interacts with NPCs (talk, block, help, disrupt), and observes how the layered AI produces believable, continuous, path-dependent behavior. A debug overlay lets the player inspect any NPC's internal state across all three layers.

Uses pre-existing assets from joonspk-research/generative_agents: a pre-rendered 4480×3200 town map (140×100 tiles at 32px), 48×48 character sprites (RPG Maker VX Ace format), and collision data extracted from the TMX.

## 1. World, Navigation & Characters
- **Depends on:** (none)
- **Status:** pending
- **Targets:** scenes/main.tscn, scenes/player.tscn, scenes/npc.tscn, scripts/player_controller.gd, scripts/npc_controller.gd, scripts/camera_controller.gd, scripts/world_map.gd, scripts/navigation_manager.gd, project.godot
- **Goal:** Set up the complete game world using pre-rendered Smallville map with tile-based collision, player movement, NPC spawning with animated sprites, AStar2D pathfinding, and camera follow. This is the visual and spatial foundation everything else builds on.
- **Requirements:**
  - Load `assets/img/town_map.png` (4480×3200) as a Sprite2D background
  - Parse `assets/img/collision_map.png` (140×100 grayscale, white=blocked) to build an AStar2D grid for pathfinding. Each tile (32×32) is one navigation node. NPCs pathfind on this grid.
  - Player character uses a character sprite from `assets/characters/Character_RM_001.png`. Sprite sheet is 576×384 with RPG Maker VX Ace layout: 12 columns × 8 rows, each frame 48×48. Use the first character (top-left 3×4 block): 3 animation frames across, 4 direction rows (down, left, right, up). Animate at ~6 FPS when moving.
  - Player moves with WASD/arrows at ~120 px/sec on walkable tiles. Collision prevents walking into blocked tiles.
  - Camera follows player smoothly with Camera2D, zoom level ~2.5x so the pixel art is clearly visible. Camera clamped to map bounds.
  - Spawn 8 NPCs at positions from the TMX spawning layer (use spawns 0-7). Each NPC gets a different character sprite (Character_RM_002 through Character_RM_009). Same sprite sheet format as player.
  - NPCs wander between random walkable tiles using AStar2D pathfinding. They animate walk cycles matching their movement direction. When they reach their destination, they idle for 2-5 seconds, then pick a new destination.
  - NPCs and player have simple tile-based collision (cannot overlap blocked tiles). NPCs don't collide with each other or the player (they pass through).
  - Time-of-day system: a float tracking hours 6.0-22.0 at configurable speed (default: 1 game-minute = 1 real-second). Display current time on a minimal HUD label.
- **Verify:** Screenshot shows the colorful pixel art town map filling the viewport at ~2.5x zoom. Player character visible and clearly animated. Multiple NPCs visible walking along paths between buildings. A time display in the corner reads something like "8:30 AM". The town looks alive with movement.

## 2. NPC AI & Town Life
- **Depends on:** 1
- **Status:** pending
- **Targets:** scripts/npc_brain.gd, scripts/layer1_substrate.gd, scripts/layer2_projection.gd, scripts/layer3_executive.gd, scripts/memory_system.gd, scripts/social_propagation.gd, scripts/npc_controller.gd, scripts/debug_overlay.gd, scripts/interaction_system.gd, scripts/game_manager.gd
- **Goal:** Implement the three-layer adaptive AI architecture, memory, social propagation, player interaction, and a debug inspection overlay. This is the core of the simulation — NPCs should feel like they have continuity, react to disruption, carry history, and remain inspectable.
- **Requirements:**
  - **Roles & Identity:** Each of the 8 NPCs has a distinct role: Baker, Guard, Herbalist, Courier, Blacksmith, Gossip, Farmer, Innkeeper. Roles determine home location, work location, default daily schedule, and social tendencies.
  - **Layer 1 — Behavioral Substrate:** Each NPC maintains numeric state variables updated every physics tick:
    - `energy` (0-100): depletes during activity, recovers at home/rest spots
    - `hunger` (0-100): rises over time, satisfied by visiting food-related locations
    - `social_need` (0-100): rises over time, satisfied by proximity to other NPCs
    - `safety` (0-100): drops near unfamiliar/dangerous areas, recovers in known safe spaces
    - `task_momentum` (0-1): builds while pursuing a plan chunk, decays on interruption
    - `interruption_tolerance` (0-1): threshold for abandoning current task. Higher when deep in a task.
    - `frustration` (0-1): accumulates from repeated interruptions, failed plans, or blocked paths
    - `trust` per-entity (dictionary): trust toward each other NPC and the player, shifts based on interactions
    - `place_familiarity` (dictionary): per-location comfort score, increases with visits
    - Action tendencies: `approach`, `avoid`, `observe`, `help`, `flee` — weighted by current conditions
  - **Layer 2 — Projection Surface:** Every 0.5 seconds, project Layer 1 into a compact readable state:
    - `mood`: composite of energy, hunger, frustration → labels like "content", "tired", "irritable", "anxious"
    - `urgency`: derived from time pressure, unfinished obligations → "relaxed", "purposeful", "rushed"
    - `openness`: social need + trust + current activity → "approachable", "busy", "withdrawn"
    - `commitment`: task momentum + interruption tolerance → "idle", "focused", "determined"
    - These projections modulate Layer 1 back: high urgency raises movement speed slightly, low openness raises interruption tolerance, high frustration lowers trust gain rate
  - **Layer 3 — Executive Planner:** Every 30 game-minutes, the executive layer reviews role obligations, memory, and current state to form/revise a plan:
    - Daily agenda: a list of 4-6 plan chunks for the day based on role (e.g., Baker: wake → open shop → serve customers → visit square → restock → close shop → go home)
    - Each plan chunk has: target location, expected duration, priority, and purpose
    - Plan revision: if a chunk fails (path blocked, location occupied, too tired), the executive can swap, delay, or skip it
    - Interruption handling: when interrupted (player conversation, NPC encounter, event), evaluate whether to pause-and-resume, abandon, or incorporate the interruption
    - Re-entry: suspended chunks remember progress and can be resumed with a brief delay
  - **Memory System:** Each NPC stores:
    - Recent observations (last 20): who they saw, where, doing what
    - Tagged events (last 10): notable occurrences with salience score (arguments, player interactions, unusual sightings, blocked paths, received rumors)
    - Relationship log: trust changes with reasons
    - Unresolved concerns: open loops that bias planning (e.g., "haven't seen the Courier today", "player was acting suspicious")
  - **Social Propagation:** When two NPCs are within 2 tiles of each other and both have openness > 0.3:
    - They may exchange a tagged event (50% chance per encounter, cooldown 5 game-minutes per pair)
    - Transferred events gain a "second-hand" tag and lose some detail (salience reduced by 30%)
    - Trust-weighted: events from trusted sources are stored with higher salience
    - Location-based amplification: exchanges in "public" zones (town square, market) have 2x chance
  - **Player Interaction:** Player presses Space/Enter near an NPC (within 1.5 tiles) to interact:
    - Show a speech bubble above the NPC with contextual dialogue based on current Layer 2 state, role, recent memory, and relationship with player
    - Dialogue is generated from templates, not LLM: e.g., if mood=irritable and the NPC recently witnessed the player bump into someone: "Watch where you're going. I saw what you did near the square."
    - Each interaction modifies trust (positive if helpful context, negative if disruptive)
    - NPCs remember player interactions as tagged events
  - **Player Disruption:** Walking into an NPC's path causes a brief interruption event. Standing near an NPC's work location for >10 seconds triggers an "observer" event that makes the NPC slightly uncomfortable (frustration +0.05). Interacting during high-commitment tasks lowers trust slightly.
  - **Debug Overlay:** Press Tab to toggle an inspection panel:
    - Click any NPC to select them. Shows a panel with:
      - Name and role
      - Layer 1 raw values (energy, hunger, frustration, momentum, etc.) as labeled bars
      - Layer 2 projection (mood, urgency, openness, commitment) as text labels
      - Layer 3 current plan: active chunk highlighted, upcoming chunks listed
      - Recent memory: last 3 tagged events as short text
      - Current action and destination
    - When overlay is active, all NPCs show a small colored dot above them: green=content, yellow=busy, orange=frustrated, red=distressed
  - **Day Cycle Effects:** NPCs return home when time approaches 21:00. Energy recovery is faster at home. The Innkeeper stays active until 23:00. The Guard patrols at night.
- **Verify:** Screenshot shows the debug overlay open with an NPC selected. The panel displays Layer 1 bars, Layer 2 text labels, and Layer 3 plan chunks. Colored dots visible above other NPCs in the scene. At least one NPC is visibly walking purposefully toward a destination (not random wandering). The selected NPC's panel shows a plausible daily plan with one chunk marked active.

## 3. Presentation Video
- **Depends on:** 1, 2
- **Status:** pending
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
  - Toggle the debug overlay to show internal state inspection
  - Show time passing and NPCs adjusting their behavior (morning routine → afternoon activities)
  - Smooth camera transitions between points of interest
- **Verify:** A smooth MP4 video showing polished gameplay with no visual glitches.
