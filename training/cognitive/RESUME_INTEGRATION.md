# Resume Prompt: SmolLM3-3B Server Integration

Paste this into a new Claude Code session to continue.

---

## What was done

### Training (COMPLETE)
- Fine-tuned SmolLM3-3B with LoRA on 3,000 adventure-command examples
- Loss: 3.72 → 0.23 over 3 epochs (17 min on A100)
- GGUF exported: `training/cognitive/SmolLM3-3B.Q4_K_M.gguf` (1.92 GB, Q4_K_M)
- LoRA adapter backup on Google Drive

### Server integration (COMPLETE — tested end-to-end)
New file: `server/command_model.py`
- `CommandModel` class manages a llama-server subprocess on port 8423
- `_format_perception(context)` builds the adventure-command user prompt from NPC thought context
- `generate_command(context)` does two-pass inference: unconstrained first, GBNF-constrained fallback
- Expects GGUF at `training/cognitive/SmolLM3-3B.Q4_K_M.gguf`

Modified: `server/layer3_model.py`
- `__init__` accepts optional `command_model` parameter
- `generate_thought()` delegates to `command_model.generate_command()` when available
- Old THOUGHT/WANT/FEEL code preserved as `_legacy_generate_thought()` fallback

Modified: `server/thought_loop.py`
- Pushes `trigger_actions` (speak, examine) from command output
- Pushes `motor_command` with raw command string and resolved target
- Enhanced logging shows command alongside thought

Modified: `server/inference_server.py` + `server/layer3_server.py`
- Both try to initialize `CommandModel` at startup
- Gracefully fall back to legacy if GGUF not found

## What was completed in integration session

### Step 1: llama-server (DONE)
- Built llama.cpp from source with CUDA (`cmake -DGGML_CUDA=ON`)
- Binary at `/tmp/llama.cpp/build/bin/llama-server`
- GPU: RTX 3080 16GB, CUDA 12.0, compute capability 8.6

### Step 2: Standalone test (DONE)
- Commands contextually correct across varied scenarios
- Avg inference: 0.9-1.3s on GPU

### Step 3: Server startup (DONE)
- CommandModel initializes at `layer3_server.py` startup, graceful fallback if GGUF missing

### Step 4: End-to-end thought loop (DONE)
- Hugo (Innkeeper) registered, thought cycles firing every ~8s
- Example output:
```
THOUGHT [Hugo] "Lonely. Need to be around people." cmd=GO TO market intents=1 biases={'approach': 0.4} [1.4s]
THOUGHT [Hugo] "Quiet moment. Could use this." cmd=WAIT intents=0 biases={'approach': -0.3} [1.1s]
```

### Step 5: GDScript client handling (DONE)
- Added `_handle_motor_command()` to `npc_brain.gd`
- Converts motor commands to concrete action overrides
- Updated `_build_action_from_override()` for motor command types

### Key fix: chat template bypass
- SmolLM3's built-in chat template has `enable_thinking` mode that suppressed our fine-tuned `<think>` tags
- Switched `CommandModel._generate()` from `/v1/chat/completions` to raw `/completion` endpoint
- Uses exact chatml format matching training data — `<think>` blocks now produce inner monologue

## What could be improved next

- Thought diversity: Hugo cycles between ~3 thought patterns. More training data or epochs could help.
- Role grounding: Hugo (Innkeeper) sometimes says "Work calls. Need to be at guard_post." — role isn't strongly conditioning behavior yet.
- Multi-NPC: Only Hugo in the scene currently. More NPCs would test social command variety.
- llama-server binary: Currently at `/tmp/llama.cpp/build/bin/llama-server` (ephemeral). Should be installed permanently.

## Architecture reminder

```
GDScript L1 (every tick) → snapshot → WebSocket → thought_loop.py
                                                      ↓
                                              L2 limbic (port 8422, TinyLlama GGUF)
                                                      ↓
                                              L3 command (port 8423, SmolLM3 GGUF)
                                                      ↓
                                              parse_command_output()
                                                      ↓
                                              push commands ← WebSocket ← GDScript
```

## Files reference

- `training/cognitive/SmolLM3-3B.Q4_K_M.gguf` — the model (1.92 GB)
- `training/cognitive/command_training_shuffled.jsonl` — 3000 training examples
- `server/command_model.py` — NEW: CommandModel class (llama-server + inference)
- `server/command_grammar.py` — GBNF grammar builder (existing, used by command_model)
- `server/command_parser.py` — parse <think> + command output (existing, used by command_model)
- `server/layer3_model.py` — MODIFIED: generate_thought delegates to CommandModel
- `server/thought_loop.py` — MODIFIED: pushes motor_command + trigger_actions
- `server/inference_server.py` — MODIFIED: initializes CommandModel at startup
- `server/layer3_server.py` — MODIFIED: initializes CommandModel at startup
