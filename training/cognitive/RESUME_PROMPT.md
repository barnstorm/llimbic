# Resume Prompt: SmolLM3-3B Adventure-Command Fine-Tuning

Paste this entire prompt into a new Claude Code session (or use it to set up Colab manually).

---

## What this project is

I'm building a cognitive architecture for NPCs in a Godot game. The architecture has 3 layers:
- **Layer 1** (GDScript, every tick): Hebbian neural network managing drives (energy, hunger, safety, social) and action neuron activations
- **Layer 2** (tiny LLM, ~300ms): Limbic system — colors perception/thoughts with emotions (27-dim GoEmotions vector)  
- **Layer 3** (this model): Executive — receives perception state, thinks about the situation, outputs a motor command

## What we decided

We designed an **adventure-game command interface** for L3. Instead of free-form text (`THOUGHT: / WANT: / FEEL:`) that gets keyword-matched, the model outputs:

1. A `<think>` block — rich inner monologue (the being's conscious experience)
2. A single command — `VERB NOUN [PREP NOUN]` (the motor intention)

**Model choice: SmolLM3-3B** (`HuggingFaceTB/SmolLM3-3B`)
- Apache 2.0, 3B params, 92.3 BFCL tool calling, 76.7 IFEval
- Native `<think>` / `</think>` thinking mode
- Q4_K_M GGUF ~2.0GB VRAM
- 65 quantized checkpoints already available on HuggingFace

## Command vocabulary (8 verbs)

```
GO TO <location|entity>      → pathfind to target
APPROACH <entity>            → close distance (social intent)
LOOK AT <entity|object>      → face and watch
EXAMINE <object>             → inspect closely
FLEE FROM <entity>           → run away
WANDER [AT <location>]       → idle exploration
WAIT                         → do nothing
SAY "<text>" [TO <entity>]   → speak aloud
```

## Training data (ALREADY GENERATED)

File: `training/cognitive/command_training_shuffled.jsonl`  
**3,000 examples**, shuffled, JSONL format.

Each example has this structure:
```json
{"messages": [
  {"role": "system", "content": "You are the mind of a simulated being. You receive your state and perceptions, think about your situation, then choose one action. Think inside <think></think> tags, then output exactly one command."},
  {"role": "user", "content": "BEING: baker\nDRIVES: energy=60 hunger=35 social=55 safety=85\nMOOD: contentment 0.4, mild curiosity 0.2\nLOCATION: bakery\nDOING: kneading dough\n\nYou see:\n  Ivy -- 4 tiles north, walking past\nYou hear:\n  (nothing)\nNearby objects:\n  Brick Oven (working)\n  Flour Sacks (full)\n\nRecent: Finished the morning batch.\nGoal: bake afternoon bread\nBeliefs: Ivy is friendly (0.7)\nLast thought: The morning batch turned out well.\n\nAvailable places: bakery, market, inn, town_square, well, herbalist_shop\n\nThink about your situation, then choose ONE action."},
  {"role": "assistant", "content": "<think>\nIvy is walking by. Haven't talked to anyone all morning and could use a break. But the dough won't knead itself.\n</think>\nLOOK AT Ivy"}
]}
```

Command distribution in the data:
```
GO TO            943 (31.4%)
WAIT             763 (25.4%)
SAY              277 (9.2%)
WANDER AT        234 (7.8%)
LOOK AT          218 (7.3%)
WANDER           212 (7.1%)
APPROACH         155 (5.2%)
EXAMINE          102 (3.4%)
FLEE FROM         96 (3.2%)
```

## What needs to happen now

### Step 1: Upload training data to Colab

The file `command_training_shuffled.jsonl` (3000 lines) needs to get into the Colab runtime. Either:
- Upload via `files.upload()` 
- Upload to Google Drive and mount
- Paste inline if using colab-mcp

### Step 2: Fine-tune SmolLM3-3B with LoRA

**Use Unsloth** for 2x training speed on Colab. Here's the exact setup:

```python
# Cell 1: Install
!pip install -q unsloth
!pip install -q --no-deps trl peft accelerate bitsandbytes

# Cell 2: Load model
from unsloth import FastLanguageModel
import torch

model, tokenizer = FastLanguageModel.from_pretrained(
    model_name="HuggingFaceTB/SmolLM3-3B",
    max_seq_length=2048,
    load_in_4bit=True,
    dtype=None,  # auto-detect
)

# Cell 3: Apply LoRA
model = FastLanguageModel.get_peft_model(
    model,
    r=32,
    lora_alpha=64,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                     "gate_proj", "up_proj", "down_proj"],
    lora_dropout=0.05,
    bias="none",
    use_gradient_checkpointing="unsloth",  # saves 60% VRAM
)

# Cell 4: Load training data
import json
from datasets import Dataset

examples = []
with open("command_training_shuffled.jsonl") as f:
    for line in f:
        examples.append(json.loads(line))

dataset = Dataset.from_list(examples)
print(f"Loaded {len(dataset)} examples")

# Cell 5: Train with SFTTrainer
# CRITICAL: SFTTrainer handles label masking automatically.
# The previous Phi-3.5 training FAILED because labels included the full
# prompt (loss floor at ~4.85). SFTTrainer masks non-assistant tokens
# so loss only measures the model's actual output quality.
from trl import SFTTrainer
from transformers import TrainingArguments

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=dataset,
    args=TrainingArguments(
        output_dir="smollm3-command-lora",
        num_train_epochs=3,
        per_device_train_batch_size=4,
        gradient_accumulation_steps=4,  # effective batch size 16
        learning_rate=1.5e-4,
        lr_scheduler_type="cosine",
        warmup_ratio=0.1,
        bf16=True,
        logging_steps=10,
        save_strategy="epoch",
        save_total_limit=2,
        report_to="none",
        optim="adamw_8bit",
    ),
    max_seq_length=2048,
)

trainer.train()

# Cell 6: Test before exporting
def test_model(prompt_text):
    messages = [
        {"role": "system", "content": "You are the mind of a simulated being. You receive your state and perceptions, think about your situation, then choose one action. Think inside <think></think> tags, then output exactly one command."},
        {"role": "user", "content": prompt_text},
    ]
    inputs = tokenizer.apply_chat_template(messages, tokenize=True, 
                                            add_generation_prompt=True,
                                            return_tensors="pt").to("cuda")
    outputs = model.generate(inputs, max_new_tokens=200, temperature=0.4,
                              do_sample=True, top_p=0.9)
    return tokenizer.decode(outputs[0][inputs.shape[1]:], skip_special_tokens=True)

# Test 1: Social + visible entity
print(test_model("""BEING: baker
DRIVES: energy=60 hunger=35 social=70 safety=85
MOOD: contentment 0.4
LOCATION: bakery
DOING: kneading dough

You see:
  Ivy -- 3 tiles north, walking past
You hear:
  (nothing)
Nearby objects:
  Brick Oven (working)

Recent: Quiet morning.
Goal: bake afternoon bread
Beliefs: Ivy is friendly (0.7)
Last thought: Haven't talked to anyone today.

Available places: bakery, market, inn, town_square, well, herbalist_shop

Think about your situation, then choose ONE action."""))

# Test 2: Hungry, no one around
print("---")
print(test_model("""BEING: guard
DRIVES: energy=30 hunger=85 social=40 safety=70
MOOD: fatigue 0.5, frustration 0.3
LOCATION: guard_post
DOING: standing watch

You see:
  (no one)
You hear:
  (nothing)
Nearby objects:
  Weapon Rack (working)

Recent: Nothing notable.
Goal: finish the watch
Beliefs: none
Last thought: Stomach won't stop growling.

Available places: guard_post, inn, market, town_square, home_north

Think about your situation, then choose ONE action."""))

# Test 3: Threat
print("---")
print(test_model("""BEING: farmer
DRIVES: energy=50 hunger=40 social=30 safety=35
MOOD: fear 0.4, nervousness 0.3
LOCATION: farm
DOING: mending the fence

You see:
  Player -- 2 tiles east, standing
You hear:
  (nothing)
Nearby objects:
  Plow (working)

Recent: Heard rumors about strangers causing trouble.
Goal: finish mending the fence
Beliefs: strangers are dangerous (0.6)
Last thought: Something doesn't feel right.

Available places: farm, home_west, market, inn, town_square

Think about your situation, then choose ONE action."""))

# Test 4: Animal (terse thinking)
print("---")
print(test_model("""BEING: cat
DRIVES: energy=70 hunger=60 social=20 safety=55
MOOD: curiosity 0.4
LOCATION: bakery
DOING: sitting on a windowsill

You see:
  Edith -- 2 tiles south, working
You hear:
  (nothing)
Nearby objects:
  Bread Basket (full)

Recent: Nothing notable.
Goal: none
Beliefs: none
Last thought: none

Available places: bakery, inn, market, herbalist_shop

Think about your situation, then choose ONE action."""))

# Cell 7: Export to GGUF
# Merge LoRA + quantize in one step with Unsloth
model.save_pretrained_merged(
    "smollm3-command-merged",
    tokenizer,
    save_method="merged_16bit",
)

# Convert to GGUF Q4_K_M
model.save_pretrained_gguf(
    "smollm3-command-gguf",
    tokenizer,
    quantization_method="q4_k_m",
)

# Download
from google.colab import files
!ls -lh smollm3-command-gguf/
!zip -r smollm3-command-gguf.zip smollm3-command-gguf/
files.download("smollm3-command-gguf.zip")

# Also save the LoRA adapter separately (much smaller, ~100MB)
model.save_pretrained("smollm3-command-lora-final")
tokenizer.save_pretrained("smollm3-command-lora-final")
!zip -r smollm3-command-lora.zip smollm3-command-lora-final/
files.download("smollm3-command-lora.zip")
```

### Step 3: What to check

1. **Loss curve**: Should converge to 0.3-1.5 (NOT 4-5 like the failed Phi run). If loss stays above 2.0 after epoch 1, something is wrong with tokenization or chat template.

2. **Test outputs**: Should follow the format:
   ```
   <think>
   Inner monologue here, grounded in perception.
   </think>
   VERB NOUN
   ```

3. **Grounding**: Command nouns must appear in the input. If the model says `GO TO church` but church isn't in "Available places", that's a grounding failure.

4. **Being variation**: Animals should think tersely ("Hungry. Food smell. Go."), humans richly, spirits sparsely.

### Step 4: After training

Download:
- `smollm3-command-gguf.zip` — the quantized GGUF model for llama.cpp
- `smollm3-command-lora.zip` — the LoRA adapter (backup)

Place the GGUF file in `training/cognitive/` on the WSL side. The server integration (replacing SmolLM2 in `server/layer3_model.py`) will use this GGUF via llama-server, same pattern as L2.

## What was already done (DON'T REDO)

- `server/command_grammar.py` — Dynamic GBNF grammar builder (builds grammar per-NPC from perception)
- `server/command_parser.py` — Parses `<think>` block + command → push protocol (intentions, biases, triggers)
- `training/cognitive/GENERATION_PROMPT.md` — Rewritten for adventure-command format
- `training/cognitive/generate_command_training.py` — Template-based generator (produced the 3000 examples)
- `training/cognitive/command_training_shuffled.jsonl` — The 3000 training examples (READY)

## Known issues from previous training attempt

The Phi-3.5-mini training FAILED because:
1. **Labels weren't masked** — `labels = input_ids.copy()` penalized the model for not predicting the prompt
2. **Only 145 of 4210 examples were loaded** — wrong data file
3. **Loss plateau at ~4.85** — way too high, should be 0.3-1.5 with proper masking

**SFTTrainer fixes issue #1 automatically.** It masks all non-assistant tokens in the loss calculation. This is why we switched from raw Trainer to SFTTrainer.

## Colab runtime requirements

- **GPU**: A100 preferred (training ~15-30 min). T4 works but slower (~60-90 min) and may need `load_in_4bit=True`
- **RAM**: 40GB+ (A100 high-RAM)
- **Disk**: ~15GB for model + training artifacts
- Make sure to select **GPU runtime** before starting

## After Colab: What's next

Once you have the GGUF file:
1. Wire it into `server/layer3_model.py` (replace SmolLM2 with llama-server + GGUF)
2. Two-pass inference: unconstrained `<think>` generation, then GBNF-constrained command
3. Replace `_parse_simple_thought()` with `command_parser.parse_command()`
4. Test the thought loop end-to-end

The L2 limbic model (switching from TinyLlama to Qwen2.5-0.5B) is a separate parallel track.
