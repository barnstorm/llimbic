# Resume Prompt: Somatic Stream + Salience + Inventory

Paste this into a new Claude Code session to continue.

---

## Where we are

### What was done this session

**SmolLM2 → SmolLM3 consolidation (Priority 2: DONE)**
- Replaced SmolLM2-1.7B-Instruct (transformers, GPU) with second SmolLM3-3B (llama-server, port 8424)
- Port 8423: SmolLM3-3B fine-tuned — thought loop (think + command)
- Port 8424: SmolLM3-3B base — chat, dialogue, converse, plan, reflect
- `server/layer3_model.py` rewritten: `_generate()` and `_generate_chat()` use raw chatml `/completion`
- No more torch/transformers dependency in layer3_server.py
- Chat uses multi-turn chatml format with system message
- Think/speech split: `_split_think_and_speech()` captures inner monologue, speaks the rest

**Drive neuron decay fix**
- Drive neurons (`drive_energy`, `drive_hunger`, `drive_social`, `drive_safety`) set to `protected: true` in hebbian_network.gd
- Only `_baseline_drift()` in layer1_substrate.gd controls drives now
- Drives hold stable at init values, drift naturally over time

**Somatic tag cleanup**
- `emit_quality_tags()` picks ONE quality per region (strongest activation wins)
- No more `chest:tight:loose:pounding:hollow` compound garbage
- Tags now emit as `chest:tight`, `gut:hollow`, `muscles:heavy` — one clear signal per region

**Emotion→quality connections removed**
- `_seed_emotion_quality_connections()` cleared — no pre-wired emo_fear→q_tight etc.
- `_apply_emotion_to_qualities()` removed from somatic_stream.gd
- Emotion neurons still exist as sensory inputs; they connect to qualities through Hebbian learning only
- Drive→quality connections remain (physics: empty stomach→hollow)
- The being discovers what emotions feel like in its body through lived experience

**TinyLlama L2 role changed**
- Old: emotion classification (27-dim vector projection)
- New: intended as body narrative generator (drives+tags → "Your stomach feels empty")
- Current: TinyLlama's LoRA fights the new prompt, outputs old structured format
- Workaround: deterministic `_narrate_body()` template in thought_loop.py (TEMPORARY — antipattern, needs TinyLlama fine-tune or removal)
- Step 3 (thought→emotion coloring) removed from thought loop

**Inventory system**
- `scripts/inventory.gd` — Generic container class (items array, capacity, add/remove/transfer)
- NPCs have 5-slot on-person inventory, loaded from persona `starting_inventory`
- World items: real objects in world_object_registry with type="item", positions near relevant fixtures
- Bakery has bread loaves, inn has ale, market has apples, farm has apples, herbalist has remedies
- Snapshot sends `carried_items` and `available_items` to server
- Command model prompt shows "Carrying: Bread, Ale" and "Available here: Bread, Apple"
- GBNF grammar includes TAKE/CONSUME/DROP/GIVE only when relevant items exist
- Parser handles all four commands → trigger_actions
- NPC brain executes: TAKE removes from world+adds to inventory, CONSUME removes+applies drive effects, DROP spawns world object, GIVE removes+action override
- Consumption effects: food→hunger-30/energy+5, drink→hunger-10/energy+15, medicine→energy+25/safety+10

**Salience neuron (interrupt-driven thinking)**
- New `salience` neuron in Hebbian network (unprotected, starts at 0, unconnected)
- Thought loop checks `salience > 40` instead of timer-based cadence
- Fallback: 8-second max interval while salience hasn't learned yet
- After each thought cycle: productive thought → nudge salience +15, unproductive → -5
- Hebbian learning wires salience to whatever was active when productive thoughts happened
- The being learns its own attention pattern through experience

**Trace logger**
- `server/trace_logger.py` — JSONL recording of every cognitive event
- Two event types: `thought` (full body state → perception → thought → command) and `speech` (all spoken output)
- Trace file: `/tmp/burg_trace_{timestamp}.jsonl`
- Captures: somatic_tags, drives, vagal_state, carrying, available_items, visible, heard, body_narrative, thought, command, action_biases, trigger_actions, salience, inference_ms

**Memory events**
- Motor commands now record as tagged events ("Headed toward inn", "Looked at Mabel", "Examined Guest Ledger")
- Thoughts recorded as events ("Thought: Something about the Pantry caught my eye")
- tagged_events now chronological (was sorted by salience, which buried recent low-salience events)
- GO TO intentions replace each other (was stacking indefinitely)

**Architecture docs**
- `docs/architecture.md` — 11 mermaid diagrams covering full data flow

### Current problems (in priority order)

**1. Somatic tags are monotone — `tight` wins every region**
- The safety→tight connection overpowers everything else
- With emotion→quality connections removed, only drive→quality connections fire
- `q_tight` has connections from safety, hunger, anger — it accumulates activation from multiple sources
- Other qualities (hollow, heavy, settled, warm) only connect to one or two drives
- Result: every region says "tight" regardless of actual state
- Fix options: rebalance drive→quality connection weights, or let Hebbian learning diversify over time

**2. TinyLlama body narrative is garbage**
- LoRA produces "Emotional: calmness Focus: rest" instead of natural language
- Deterministic template works but is an antipattern (fixed mappings)
- Need: fine-tune TinyLlama on narrative output, OR replace with SmolLM3 call, OR accept deterministic for now
- The body narrative feeds into both command model and chat model prompts

**3. CONSUME/TAKE rarely fire**
- Model was fine-tuned on GO TO/SAY/LOOK AT, not inventory commands
- GBNF grammar constrains pass 2 but pass 1 (unconstrained) rarely produces TAKE/CONSUME
- 8 CONSUME events in 7700 thoughts (0.1%) across a full session
- Need: training data with inventory-aware examples

**4. Recent events still sparse**
- Memory records events but they fall off the 10-event buffer before the next snapshot
- Many thoughts have empty `recent_events` — model lacks short-term context
- The `MAX_TAGGED_EVENTS = 10` may be too small for the current event recording rate

**5. Salience neuron at 0 — hasn't learned yet**
- Every thought fires on 8-second fallback
- Reward/punishment is flowing (+15/-5) but connections haven't formed
- Need sustained play sessions for Hebbian learning to wire salience to meaningful sources

### Key files reference

**Server (Python)**
- `server/command_model.py` — SmolLM3-3B thought model (port 8423). `_format_perception()` builds prompt with somatic tags, carrying, available items, body narrative.
- `server/layer3_model.py` — SmolLM3-3B chat model (port 8424). `_generate_chat()` for multi-turn, `_split_think_and_speech()` for output parsing.
- `server/layer3_server.py` — FastAPI + WebSocket. No torch dependency. Starts both SmolLM3 instances.
- `server/thought_loop.py` — Per-NPC async thought cycles. Step 1: body narrative. Step 2: L3 thinking. Salience reward after each cycle. Trace logging.
- `server/npc_state.py` — `should_think()` checks salience neuron > 40 with 8s fallback. GO TO intentions replace each other.
- `server/command_parser.py` — TAKE, CONSUME, DROP, GIVE patterns added.
- `server/command_grammar.py` — Inventory-aware GBNF: take-cmd, consume-cmd, drop-cmd, give-cmd conditional on item availability.
- `server/layer2_model.py` — TinyLlama limbic. Has `narrate_body_state()` method (unused — LoRA fights it). Old `project()` and `color_thought()` still exist but not called from thought loop.
- `server/trace_logger.py` — JSONL trace recording.

**GDScript (Godot)**
- `scripts/hebbian_network.gd` — Drive neurons protected. Salience neuron added. Emotion→quality connections removed. `emit_quality_tags()` picks one quality per region.
- `scripts/somatic_stream.gd` — `_apply_emotion_to_qualities()` removed. Clean emit path: suppression → conditioning → quality tags.
- `scripts/inventory.gd` — Generic container: add/remove/transfer/has/count/display_list.
- `scripts/npc_brain.gd` — Inventory member. TAKE/CONSUME/DROP/GIVE command handlers. `_record_action_event()` for memory. `reward_salience` handler.
- `scripts/npc_controller.gd` — Snapshot includes carried_items, available_items. `_get_location_items()` from world_object_registry.
- `scripts/world_object_registry.gd` — Real item world objects (`type="item"`). `find_item_by_name()`, `remove_object()`, `spawn_item()`, `get_items_at_location()`.
- `scripts/memory_system.gd` — Chronological event buffer (was salience-sorted). `get_recent_events_text()` returns most recent.
- `scripts/layer1_substrate.gd` — Salience exposed in `get_state_dict()`.

**Data**
- `data/npcs/*.json` — All 8 personas have `starting_inventory` arrays
- `data/items.json` — Does not exist yet (item effects are category-based in npc_brain.gd)
- `docs/architecture.md` — Mermaid diagrams of full architecture

### What to do next

**Immediate (unblock progress):**
1. Fix somatic tag monotony — `q_tight` wins everything. Either rebalance weights or add more drive→quality connections so different drives activate different qualities distinctly.
2. Increase `MAX_TAGGED_EVENTS` to 20-30 and verify recent events flow into the command model prompt.
3. Let the game run for 5+ minutes to see if Hebbian learning diversifies somatic tags and salience starts learning.

**Short term:**
4. Fine-tune TinyLlama on body narrative output — input: drives+tags+context, output: 2-3 sentences of felt experience. Use trace data to generate training examples.
5. Generate TAKE/CONSUME training examples for the command model fine-tune. The GBNF constrains pass 2 but the model needs to learn when to use inventory commands.
6. Add possession/near_resource neurons to Hebbian network for inventory-awareness at the network level.

**Medium term:**
7. Persistence: save/load Hebbian network state, memory, inventory between sessions.
8. More NPCs: test with 4-8 NPCs to verify performance (two SmolLM3 instances, -np 2 each).
9. Player as a being: give the player character the same inventory system.

### Architecture reminder

```
Port 8422: TinyLlama-1.1B (limbic, currently underused)
Port 8423: SmolLM3-3B fine-tuned (thought loop: <think> + command)
Port 8424: SmolLM3-3B base (chat, dialogue, converse, plan, reflect)

GDScript (every tick):
  Hebbian network → propagate → learn → neurogenesis
  Somatic stream → one quality per region → tags
  Salience neuron → fires when network warrants attention
  
Server (async, salience-driven):
  Step 1: Build body narrative (deterministic template, temporary)
  Step 2: SmolLM3 thinks + commands
  Reward salience based on thought productivity
  Push commands → client executes
  
Trace: /tmp/burg_trace_{ts}.jsonl — every thought + speech event
```
