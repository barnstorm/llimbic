# Resume Prompt: Model Consolidation + Somatic Prompt Unification

Paste this into a new Claude Code session to continue.

---

## Where we are

### Architecture (fully integrated, tested end-to-end)

```
GDScript (every tick)
  ├── Hebbian network: drives, vagal neurons, quality neurons, action neurons
  │     Neurogenesis: stress/novelty/reward/vagal/compound-quality
  │     Hebbian learning: co-activation strengthens connections
  │
  ├── Somatic stream: quality neurons → compound tags (gut:empty:churning)
  │     Probabilistic emission, suppression, place/entity conditioning
  │
  ├── Vagal gate: ventral/sympathetic/dorsal (mutual inhibition, learnable)
  │     Gates action neurons, colors quality neurons, modulates thought cadence
  │
  └── Snapshot every 2s → WebSocket → server
        Includes: somatic_tags, vagal_state, visible, heard, visible_objects

Server (Python, three models)
  ├── SmolLM3-3B Q4_K_M (llama-server, port 8423) — THE MIND
  │     Raw /completion endpoint, chatml format
  │     Reads: "You feel: gut:empty:churning, chest:tight"
  │     Thinks: <think>My stomach is growling.</think>
  │     Outputs: GO TO bakery
  │     Runs every ~8s per NPC via thought loop
  │
  ├── SmolLM2-1.7B-Instruct (transformers, port 8421) — SPEECH/PLANNING
  │     Planning: daily agenda from persona + state
  │     Chat: player conversation (chat template turns)
  │     Converse: NPC-to-NPC dialogue
  │     Reflect: memory compression + concerns
  │     Dialogue: player greeting
  │     Still reads OLD format: emotion summary + drive floats
  │
  └── TinyLlama-1.1B+LoRA (transformers, port 8420) — LIMBIC
        Emotion vector projection (27-dim GoEmotions)
        Mostly redundant — deterministic EmotionEngine + somatic stream
        does the same work without model calls
```

### What was proven in testing

- All 8 adventure commands fired in live testing: WAIT, GO TO, SAY TO, LOOK AT, WANDER AT, EXAMINE, FLEE FROM, APPROACH
- Somatic tags drive behavior: "Can barely keep my eyes open" from muscles:heavy + head:foggy
- "Something about the town_square feels wrong" → FLEE emerged from body sensation
- NPC-to-NPC perception: Mabel saw Hugo, thought about him, looked at him
- Two NPCs running concurrent thought loops at ~1.3s/inference on RTX 3080
- Vagal transitions: ventral→sympathetic onset ~220 ticks, dorsal collapse, rung constraint verified

### Repo

GitHub: https://github.com/barnstorm/llimbic
Latest commit: `ac495d5 add vagal gate: three competing autonomic neurons with neurogenesis`

## What needs to happen next

### Priority 1: Unify prompts around somatic tags

SmolLM2's prompts (chat, dialogue, converse, plan, reflect) still use the old format:
```
NPC state: energy=75, hunger=1, social=3, safety=100
Current emotions: joy=0.30, curiosity=0.25, optimism=0.20
```

These should read somatic tags instead:
```
You feel: chest:warm:open, body:settled, head:clear
```

**Files to change:**
- `server/prompt_builder.py` — `build_preamble()` and `build_preamble_from_packet()` construct the persona+state preamble. Replace drive float formatting with somatic tag pass-through.
- `server/layer3_model.py` — `chat_from_packet()` builds a system message with perception string. Should include somatic tags.
- `server/npc_state.py` — `build_thought_context()` already passes `somatic_tags`. Ensure it's available for all prompt paths.
- `server/layer2_model.py` — Format state prompt. May need somatic tag awareness.
- `server/emotion_coords.py` — `format_state_prompt()` builds the L2 prompt with drive floats.

### Priority 2: Consolidate SmolLM2 into SmolLM3

SmolLM3 (3B) is more capable than SmolLM2 (1.7B). The thought loop already uses SmolLM3 exclusively. The remaining SmolLM2 tasks (planning, dialogue, chat, reflect, converse) could all route through SmolLM3's llama-server with different system prompts.

**Approach:**
- Add prompt modes to CommandModel: "plan", "chat", "converse", "reflect" alongside the default "think+command" mode
- Route all L3 endpoints through llama-server /completion with mode-specific system prompts
- Remove SmolLM2 from GPU entirely — one less model to load
- The chat endpoint would use the same raw chatml format that works for thinking

**Considerations:**
- SmolLM3 was fine-tuned on adventure-command data. Other prompt modes would use the base model's capabilities, not the fine-tune. This is fine — the base SmolLM3 is a general chat model.
- Chat template: use the raw /completion endpoint for all modes (bypasses the built-in template that breaks <think> tags)
- Context window: SmolLM3 has 2048 ctx. Planning and chat prompts need to fit.

### Priority 3: Evaluate TinyLlama necessity

The L2 limbic model (TinyLlama-1.1B+LoRA) projects drive state → emotion vector. But:
- The deterministic EmotionEngine runs every tick and does the same job
- The somatic stream reads quality neuron activations, not the emotion vector
- The L2 server call runs every ~2s and slightly corrects the deterministic path
- When the thought loop is active, it handles L2 coloring server-side

**Test:** Run with L2 disabled. If behavior quality doesn't degrade, remove it. The somatic stream IS the limbic system now — quality neurons activated by drives and emotions produce the body-state representation that matters.

### Priority 4: Vagal weight tuning

Current vagal weights work for basic transitions but:
- Dorsal recovery is too slow even with co-regulation (social presence)
- Ventral can saturate at 100 and resist sympathetic onset in some configurations  
- Need a threat source (dangerous entity/event) to properly test sympathetic→dorsal→recovery arc
- Vagal neurogenesis hasn't been observed in live testing yet (needs sustained co-activation that hasn't occurred in short test sessions)

## Key files reference

### GDScript (Godot client)
- `scripts/hebbian_network.gd` — Neurons, connections, propagation, learning, neurogenesis (stress/novelty/reward/vagal/compound-quality). Quality neurons, vagal neurons, action baselines.
- `scripts/somatic_stream.gd` — Tag emission from quality neurons. Suppression, conditioning, emotion→quality feedback.
- `scripts/layer1_substrate.gd` — Wraps Hebbian network. Drives, task state, somatic timer, vagal state accessor.
- `scripts/layer2_projection.gd` — Emotion vector (27-dim), deterministic engine + async limbic server.
- `scripts/emotion_engine.gd` — Deterministic emotion projection (drive→emotion mappings). Modulation params.
- `scripts/npc_brain.gd` — Orchestrates all layers. Action selection (softmax over action neurons with server biases). Motor command handling. Thought loop integration.
- `scripts/npc_controller.gd` — CharacterBody2D. Executes actions, sends snapshots, receives push commands.
- `scripts/sensor_system.gd` — Vision (FOV + raycasting through occluders) + hearing queries.
- `scripts/memory_system.gd` — Tagged events, beliefs, relationships, place familiarity, entity threat levels.

### Server (Python)
- `server/command_model.py` — CommandModel class. llama-server subprocess on port 8423. `_format_perception()` builds the somatic tag prompt. Raw /completion endpoint.
- `server/command_parser.py` — Parses <think> + VERB NOUN commands into push protocol.
- `server/command_grammar.py` — GBNF grammar builder for constrained inference.
- `server/layer3_model.py` — SmolLM2-1.7B for planning/dialogue/chat/reflect. `generate_thought()` delegates to CommandModel.
- `server/layer3_server.py` — FastAPI + WebSocket. Thought loop lifecycle. Game client identification.
- `server/thought_loop.py` — Per-NPC async thought cycles. L2 coloring → L3 thinking → push commands.
- `server/npc_state.py` — Server-side NPC state. Thought context builder. Urgency/cadence with vagal modulation.
- `server/prompt_builder.py` — Persona preamble construction for SmolLM2 prompts.
- `server/layer2_model.py` — TinyLlama-1.1B+LoRA limbic model.

### Training
- `training/cognitive/SmolLM3-3B.Q4_K_M.gguf` — The command model (1.92GB, Q4_K_M quantized)
- `training/cognitive/command_training_shuffled.jsonl` — 3000 adventure-command training examples
- `training/cognitive/smollm3_finetune.ipynb` — Colab notebook for fine-tuning

### Personas
- `data/npcs/{name}.json` — Per-NPC persona: role, personality, schedule, neural_biases, relationships
- `data/locations.json` — Location positions and types

## Architecture reminder

```
                    Hebbian Network (GDScript, every tick)
                    ┌─────────────────────────────────┐
                    │ Drives: energy, hunger, safety,  │
                    │         social, arousal           │
                    │                                   │
                    │ Vagal: ventral ◇ sympath ◇ dorsal│
                    │   (mutual inhibition, learnable) │
                    │                                   │
                    │ Quality: 31 base + compounds     │
                    │   → somatic tag emission          │
                    │                                   │
                    │ Actions: approach, avoid, observe,│
                    │          help, flee               │
                    │   (softmax competition)           │
                    └──────────────┬────────────────────┘
                                   │ snapshot every 2s
                                   ▼
                    ┌──────────────────────────────────┐
                    │ SmolLM3-3B (llama-server:8423)   │
                    │                                   │
                    │ "You feel: gut:empty, chest:tight"│
                    │ <think>Stomach growling...</think> │
                    │ GO TO bakery                      │
                    └──────────────┬────────────────────┘
                                   │ push commands
                                   ▼
                    GDScript: motor_command → action execution
```
