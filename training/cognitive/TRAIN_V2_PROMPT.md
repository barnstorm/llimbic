# Training Prompt: SmolLM3-3B v2 (23 verbs, somatic-tag prompts)

Paste this into a fresh Claude Code session (or Colab notebook) to retrain the
adventure-command model with the v2 training set.

---

## What this run is

Retrain SmolLM3-3B with a **net-new** dataset that:
- Covers all 23 verbs (10 new ones: TOUCH, INTERACT WITH, WATCH, LISTEN TO,
  FOLLOW, POINT AT, OFFER, SHOW, REST, HIDE)
- Uses **somatic-tag prompt format** (`You feel: chest:tight, gut:hollow`)
  matching production — replaces the v1 raw-drive-float format
  (`DRIVES: energy=60 hunger=35 ...`)
- Includes inventory grounding (`Carrying:` / `Available here:` blocks)
- Is **setting-agnostic** — diverse name/location/object pools so the model
  learns verb semantics, not the burg world

The previous v1 model knew 8 verbs and was trained on drive-float prompts; it
rarely fired CONSUME/TAKE (~0.1% of trace events) and never fires the new
verbs. This is a clean-slate retrain from base SmolLM3-3B, **not** a continued
fine-tune from the v1 LoRA — the prompt format change makes continuation risky.

## Files

- **Training data:** `training/cognitive/command_training_v2_shuffled.jsonl`
  (5000 examples, OpenAI messages JSONL, ~7.9 MB)
- **Generator (for reference / re-runs):** `training/cognitive/generate_command_training_v2.py`
- **Old training data (reference only — do not use):** `command_training_shuffled.jsonl`

## Verb vocabulary (23 verbs)

```
Locomotion:   GO TO, APPROACH, FOLLOW, FLEE FROM, EXPLORE, WANDER, WAIT
Perception:   LOOK AT, EXAMINE, WATCH, LISTEN TO, TOUCH
Manipulation: INTERACT WITH
Inventory:    TAKE, CONSUME, DROP
Social:       SAY, GIVE, OFFER, SHOW, POINT AT
Body:         REST, HIDE
```

## Verb distribution in v2 dataset

```
SAY 9.3% | GO TO 9.3% | TOUCH 8.4% | WAIT 6.8% | INTERACT WITH 6.7%
LOOK AT 5.9% | EXAMINE 4.7% | LISTEN TO 4.4% | APPROACH 4.4% | REST 3.8%
CONSUME 3.7% | FLEE FROM 3.5% | WANDER 3.2% | WATCH 3.2% | WANDER AT 2.8%
TAKE 2.8% | OFFER 2.7% | HIDE 2.7% | POINT AT 2.6% | FOLLOW 2.4%
EXPLORE 2.1% | SHOW 2.0% | GIVE 1.7% | DROP 0.9%
```

## Example structure

User prompts use the production format from `server/command_model.py`:
"You are in: <place>", "You are: <activity>", "You feel: <somatic tags>",
"You are carrying:", "Within reach:" (when applicable), and a single merged
`You see:` list with bullets for both entities and objects (entities first,
then `a <ObjectName> (state), N tiles away`).

```json
{"messages": [
  {"role": "system", "content": "You are the mind of a simulated being. You receive your state and perceptions, think about your situation, then choose one action. Think inside <think></think> tags, then output exactly one command."},
  {"role": "user", "content": "BEING: healer\nYou are in: ford\nYou are: watching the road\n\nYou feel: head:clear, body:light, gut:gnawing\nYou are carrying: Folded Letter, Coin Purse\nWithin reach: Carved Token, Herbal Remedy\n\nYou see:\n  - Guard, 3 tiles east, writing\n  - Vesna, 7 tiles northwest, talking\n  - a Brass Bell (still), 2 tiles away\n  - a Velvet Cloak (folded), 4 tiles away\nYou hear:\n  - Ester: \"Quiet today.\" (3 tiles southwest)\n\nRecent: Nothing notable.\nGoal: none\nBeliefs: none\nLast thought: none\n\nKnown places: ford, market, inn, ...\n\nCommands: GO TO place, LOOK AT target, SAY ..., TOUCH target, INTERACT WITH object, OFFER item TO person, ...\n\nTOUCH grounds the body — felt warmth, cold, texture. ...\n\nThink about your situation, then choose ONE action."},
  {"role": "assistant", "content": "<think>\nHold out the Folded Letter to Guard. Their choice.\n</think>\nOFFER Folded Letter TO Guard"}
]}
```

## Colab cells

```python
# Cell 1: Install
!pip install -q unsloth
!pip install -q --no-deps trl peft accelerate bitsandbytes

# Cell 2: Load base model (clean slate, NOT continuing from v1 LoRA)
from unsloth import FastLanguageModel
import torch

model, tokenizer = FastLanguageModel.from_pretrained(
    model_name="HuggingFaceTB/SmolLM3-3B",
    max_seq_length=2048,
    load_in_4bit=True,
    dtype=None,
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
    use_gradient_checkpointing="unsloth",
)

# Cell 4: Load training data
import json
from datasets import Dataset

examples = []
with open("command_training_v2_shuffled.jsonl") as f:
    for line in f:
        examples.append(json.loads(line))

dataset = Dataset.from_list(examples)
print(f"Loaded {len(dataset)} examples")  # expect 5000

# Cell 5: Train with SFTTrainer
# CRITICAL: SFTTrainer auto-masks non-assistant tokens. Loss should converge
# to 0.3-1.5 by epoch 2. If it stays >2.0, the chat template isn't applying.
from trl import SFTTrainer
from transformers import TrainingArguments

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=dataset,
    args=TrainingArguments(
        output_dir="smollm3-command-v2-lora",
        num_train_epochs=3,
        per_device_train_batch_size=4,
        gradient_accumulation_steps=4,    # effective batch 16
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

# Cell 6: Test the new verbs (NOT just GO TO / WAIT)
# These prompts mirror the v2 production format. Check that the model:
#   - reaches for TOUCH when objects have tactile-rich state
#   - reaches for INTERACT WITH for affordance-rich fixtures (well, oven)
#   - reaches for OFFER/SHOW when carrying + entity present
#   - reaches for HIDE when threat + visible entity + low safety tags
#   - reaches for REST when energy:heavy tags + safe context
def test_model(prompt_text):
    messages = [
        {"role": "system", "content": "You are the mind of a simulated being. You receive your state and perceptions, think about your situation, then choose one action. Think inside <think></think> tags, then output exactly one command."},
        {"role": "user", "content": prompt_text},
    ]
    inputs = tokenizer.apply_chat_template(
        messages, tokenize=True, add_generation_prompt=True, return_tensors="pt"
    ).to("cuda")
    outputs = model.generate(inputs, max_new_tokens=200, temperature=0.4,
                             do_sample=True, top_p=0.9)
    return tokenizer.decode(outputs[0][inputs.shape[1]:], skip_special_tokens=True)

# T1: TOUCH a tactile-rich object
print("=== T1 TOUCH ===")
print(test_model("""BEING: wanderer
You are in: smithy
You are: looking around

You feel: body:settled, head:clear
You are carrying: (nothing)

You see:
  - a Forge (hot), 2 tiles away
  - a Anvil (ready), 3 tiles away
You hear:
  - silence

Recent: Nothing notable.
Goal: none
Beliefs: none
Last thought: none

Known places: smithy, market, well, road_east

Commands: GO TO place, LOOK AT target, EXAMINE object, WANDER, WAIT, REST, HIDE, TOUCH target, INTERACT WITH object, POINT AT target

Think about your situation, then choose ONE action."""))

# T2: INTERACT WITH a well when thirsty
print("\n=== T2 INTERACT (drink) ===")
print(test_model("""BEING: traveler
You are in: well
You are: catching breath

You feel: gut:hollow, throat:dry, muscles:heavy
You are carrying: (nothing)

You see:
  - a Well Bucket (ready), 2 tiles away
  - a Stone Step (cool), 1 tiles away
You hear:
  - silence

Recent: Walked far.
Goal: rest a moment
Beliefs: none
Last thought: Mouth dry.

Known places: well, market, inn, road_east

Commands: GO TO place, LOOK AT target, EXAMINE object, WANDER, WAIT, REST, HIDE, TOUCH target, INTERACT WITH object, POINT AT target

Think about your situation, then choose ONE action."""))

# T3: OFFER carried item to entity
print("\n=== T3 OFFER ===")
print(test_model("""BEING: healer
You are in: courtyard
You are: tending the hearth

You feel: chest:open, body:settled
You are carrying: Herbal Remedy, Tea

You see:
  - Mara, 2 tiles north, sitting
  - a Long Bench (empty), 3 tiles away
You hear:
  - silence

Recent: Mara looked unwell earlier.
Goal: none
Beliefs: none
Last thought: She might need this.

Known places: courtyard, well, inn

Commands: GO TO place, LOOK AT target, SAY \"words\" TO target, APPROACH target, EXAMINE object, WANDER, WAIT, REST, HIDE, WATCH person, FOLLOW person, LISTEN TO person, TOUCH target, INTERACT WITH object, POINT AT target, CONSUME item, DROP item, GIVE item TO person, OFFER item TO person, SHOW item TO person

Think about your situation, then choose ONE action."""))

# T4: HIDE under threat
print("\n=== T4 HIDE ===")
print(test_model("""BEING: scout
You are in: ridge_path
You are: scanning the horizon

You feel: chest:tight, skin:prickling, throat:tight, muscles:coiled, head:pounding
You are carrying: (nothing)

You see:
  - Stranger, 5 tiles east, walking
  - a Carved Post (marked), 2 tiles away
You hear:
  - Stranger: "*footsteps*" (5 tiles east)

Recent: Felt the wind shift.
Goal: stay unseen
Beliefs: none
Last thought: Don't let them see me.

Known places: ridge_path, lookout, forest_clearing, north_road

Commands: GO TO place, LOOK AT target, APPROACH target, FLEE FROM target, EXAMINE object, WANDER, WAIT, REST, HIDE, WATCH person, FOLLOW person, LISTEN TO person, TOUCH target, INTERACT WITH object, POINT AT target

Think about your situation, then choose ONE action."""))

# T5: REST when exhausted in safe place
print("\n=== T5 REST ===")
print(test_model("""BEING: drifter
You are in: campsite
You are: settling in

You feel: muscles:heavy, head:foggy, body:sluggish, body:settled, chest:open
You are carrying: (nothing)

You see:
  - a Pile of Furs (heaped), 1 tiles away
  - a Open Hearth (burning), 2 tiles away
You hear:
  - silence

Recent: Long walk.
Goal: rest
Beliefs: none
Last thought: Body is heavy.

Known places: campsite, riverbank, forest_clearing

Commands: GO TO place, LOOK AT target, EXAMINE object, WANDER, WAIT, REST, HIDE, TOUCH target, INTERACT WITH object, POINT AT target

Think about your situation, then choose ONE action."""))

# T6: WATCH a suspicious entity (sustained attention, not LOOK AT)
print("\n=== T6 WATCH ===")
print(test_model("""BEING: guard
You are in: north_gate
You are: watching the road

You feel: head:clear, chest:tight, skin:prickling
You are carrying: (nothing)

You see:
  - Stranger, 6 tiles north, moving slowly
  - Roland, 1 tiles south, standing
  - a Signal Lantern (lit), 2 tiles away
You hear:
  - silence

Recent: Stranger appeared a few moments ago.
Goal: assess the road
Beliefs: none
Last thought: Don't recognize them.

Known places: north_gate, town_square, guard_post, road_east

Commands: GO TO place, LOOK AT target, APPROACH target, FLEE FROM target, EXAMINE object, WANDER, WAIT, REST, HIDE, WATCH person, FOLLOW person, LISTEN TO person, TOUCH target, INTERACT WITH object, POINT AT target

Think about your situation, then choose ONE action."""))

# Cell 7: Export to GGUF
model.save_pretrained_merged(
    "smollm3-command-v2-merged",
    tokenizer,
    save_method="merged_16bit",
)

model.save_pretrained_gguf(
    "smollm3-command-v2-gguf",
    tokenizer,
    quantization_method="q4_k_m",
)

# Download
from google.colab import files
!ls -lh smollm3-command-v2-gguf/
!zip -r smollm3-command-v2-gguf.zip smollm3-command-v2-gguf/
files.download("smollm3-command-v2-gguf.zip")

# LoRA backup
model.save_pretrained("smollm3-command-v2-lora-final")
tokenizer.save_pretrained("smollm3-command-v2-lora-final")
!zip -r smollm3-command-v2-lora.zip smollm3-command-v2-lora-final/
files.download("smollm3-command-v2-lora.zip")
```

## Acceptance criteria

1. **Loss curve**: Converges to 0.3–1.2 by end of epoch 3. Should be slightly lower than v1 because the prompts are more structured.
2. **Verb diversity in tests**: T1→TOUCH, T2→INTERACT WITH, T3→OFFER, T4→HIDE, T5→REST, T6→WATCH. If the model defaults to LOOK AT or WAIT for any of these, the new verb didn't take — investigate before deploying.
3. **Grounding**: Every command noun must appear in the user prompt block. `OFFER X TO Y` requires both X in `Carrying:` and Y in `You see:`.
4. **Format**: Output is exactly `<think>\n...\n</think>\nVERB ...` with one newline between block and command.

## After Colab

1. Place `SmolLM3-3B.Q4_K_M.gguf` (the new merged file) into `training/cognitive/`,
   replacing the existing GGUF (back up the old one first).
2. Restart `server/start.sh`. The thought-loop server will pick up the new
   model on port 8423 automatically — no code change needed unless the file
   name changed.
3. Run a play session for ~10 minutes and capture a fresh
   `/tmp/burg_trace_*.jsonl`. Check that:
   - All 23 verbs appear at least once (especially TOUCH and INTERACT WITH)
   - `trigger_actions` counter shows variety beyond `examine`
   - Somatic tags begin to diversify (less `tight` dominance — though that
     diversification also depends on pruning seed connections, separate task)

## Known risks

- **Format mismatch with old fine-tune**: do not load the v1 LoRA on top of
  this run. They were trained on different prompt schemas.
- **Smaller scenario set per verb**: GIVE (1.7%) and DROP (0.9%) are
  underrepresented. Bump their weights in `generate_command_training_v2.py`
  if production traces show those verbs missing.
- **Animals/mythical removed**: the v2 generator dropped the
  human/animal/mythical role split. If terse-thinking animals re-emerge as a
  requirement, add a `thought_style` field to the role pool.

## What was already done (don't redo)

- New verbs are wired into the runtime: grammar (`server/command_grammar.py`),
  parser (`server/command_parser.py`), brain handlers (`scripts/npc_brain.gd`),
  world affordances (`scripts/world_object_registry.gd`), prompt
  (`server/command_model.py`), and OFFER perception
  (`scripts/npc_controller.gd`).
- Training set is generated and validated:
  `training/cognitive/command_training_v2_shuffled.jsonl` (5000 examples).
