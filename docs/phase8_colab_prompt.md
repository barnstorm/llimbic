# Phase 8 — v3 LoRA Training (Colab Runbook Prompt)

> Paste this entire document as the first prompt into a fresh Claude Code
> session that has Colab MCP access. The session runs on your Windows host;
> Claude drives a Colab notebook through the browser MCP. Assumes the
> `burg` repo is pushed to a git remote you can clone from in Colab.

---

## Mission

Execute the operator-gated portion of Phase 8 of
`docs/perception_implementation_plan.md`: take accelerated-sim traces, run
them through the shipped Phase 8 toolchain, produce a v3 LoRA fine-tune of
SmolLM3-3B, export to GGUF, and validate against the F1/F4/F5/F6 continuous
gates. Every piece of tooling is already in the repo and test-green at 26/26
gates — this run just executes it end-to-end with real compute.

The acceptance gates that **require** this run (and can't be closed from unit
tests):

1. v3 GGUF on v3 prompt format — verb diversity > 0 on every category.
2. §9.4 behavioral-probe diversity passes.
3. F1 semantic-probe baseline still passes against v3 (no embedding-space
   corruption from training).
4. F4/F6 CLIs still pass against v3-run traces.

The F5 gate (zero pre-maturity leaks in the corpus) is tooling-enforced and
already verified by `tests/test_phase8_acceptance.py`; this run re-verifies
it on real traces.

## Working agreement

Every step has a verification command. **Do not advance to the next step
until the prior step's verification is green.** If a verification fails,
stop and report: the plan's contract is "acceptance gate green before moving
on" — that applies here too.

## Repo layout (read these first)

- `docs/perception_implementation_plan.md` — the plan (Phase 8 is the one we're executing)
- `docs/RESUME.md` — current state: Phases 0-7 + 9 + 10 shipped, Phase 8 tooling shipped, runtime operator-gated
- `training/cognitive/generate_command_training_v3.py` — the generator
- `training/cognitive/maturity_classifier.py` — F5 gate logic
- `training/cognitive/synthetic_scenarios.py` — §15.2 coverage scenarios
- `tools/probe_maturity.py` — F5 CLI (`--trace` audit / `--corpus` validator)
- `tools/probe_attention_entropy.py` — F6 CLI
- `tools/probe_fallback_decay.py` — F4 CLI
- `tools/probe_embedding_semantics.py` — F1 CLI
- `data/perception_constants.json` — every threshold is Tier-2 seeded here; DO NOT hardcode

---

## Prerequisites (do on Windows host before Colab session)

1. **Push the repo** to a remote (GitHub/GitLab). You will clone from Colab.
2. **Produce an accelerated-sim trace** — on Windows/WSL host, this is:

    ```bash
    BURG_ACCEL=30 ./scripts/run_accelerated.sh \
        --npcs hugo,mabel,ivy \
        --duration 24h \
        --seed 42 \
        --out /tmp/trace_phase8.jsonl
    ```

    Verify maturity crossover locally first:

    ```bash
    python3 tools/probe_maturity.py --trace /tmp/trace_phase8.jsonl
    ```

    Every NPC should report `MATURE` with a `first_mature_ts`. If any report
    `COLD_START`, the run was too short — extend `--duration` and re-record.
    (Plan floor: 24 simulated hours; 72 is safer.)

3. **Upload** the trace to Colab via Google Drive OR keep it on your host
   and use the Colab MCP to drop it into the notebook upload. A 24-hour
   trace for 3 beings at a ~1Hz thought cadence is ~250k records (~40-80 MB);
   fits in Drive comfortably.

4. **Budget wall-clock time:**
   - Corpus generation: 30-60 min on an A100, 1-2 h on a T4 (bound by the
     large-model completion pass over ~5000 prompts).
   - LoRA training: 30-45 min on A100, 1.5-2.5 h on T4 (3 epochs × ~5000
     examples × SmolLM3-3B).
   - GGUF export: 10 min.
   - Validation: 10 min.

---

## Colab setup (first steps)

When the Colab notebook opens:

```python
# 1. Confirm GPU. A100/V100 strongly preferred; T4 works but triples wall-clock.
!nvidia-smi
```

Expected: a GPU with ≥ 15 GB VRAM (T4 has 15 GB; A100 has 40-80). If the
line `NVIDIA-SMI has failed` appears, the runtime is CPU-only — change to
GPU under Runtime → Change runtime type before continuing.

```python
# 2. Clone the repo. Replace REMOTE_URL and BRANCH with yours.
!git clone https://github.com/<YOU>/burg.git /content/burg
%cd /content/burg
!git checkout master   # carries Phase 8 tooling (origin/master @ b60f7ac or later)
```

```python
# 3. Install Python deps.
!pip install -q transformers>=4.45.0 peft>=0.12.0 trl>=0.11.0 \
    accelerate>=1.0.0 datasets safetensors bitsandbytes nltk
!python -c "import nltk; nltk.download('wordnet', quiet=True); nltk.download('omw-1.4', quiet=True)"
```

```python
# 4. Sanity-check the shipped toolchain's tests still pass.
#    (Only Python gates; Godot gates don't run here.)
!python tests/test_constants_parity.py
!python tests/test_maturity_classifier.py
!python tests/test_v3_generator.py
!python tests/test_phase8_acceptance.py
```

All four must exit 0 before proceeding. If any fail, something is wrong with
the checkout — re-clone, don't patch locally.

---

## Step 1 — Upload + validate the trace

```python
# Upload trace_phase8.jsonl to /content/burg/traces/
!mkdir -p /content/burg/traces
# Use the Colab file uploader OR mount Drive:
from google.colab import files
files.upload()  # pick trace_phase8.jsonl; it goes to /content
!mv /content/trace_phase8.jsonl /content/burg/traces/
```

**Verification:**

```python
!python tools/probe_maturity.py --trace traces/trace_phase8.jsonl
```

Expected: every NPC in the trace listed with `MATURE` verdict and a
`first_mature_ts`. If any show `COLD_START`, the trace is too short — go
back to the Windows host and extend.

---

## Step 2 — Generate the v3 corpus

The generator's `completion_fn` is pluggable. For Colab we wire it to a
large instruction-tuned HF model that fits alongside the training-base
model. **Default choice:** `mistralai/Mistral-7B-Instruct-v0.3`. Swap to
`meta-llama/Meta-Llama-3-8B-Instruct` or `Qwen/Qwen2.5-7B-Instruct` by
changing `LARGE_MODEL_ID` below if you prefer.

```python
# Generator completion-fn: load a 7B instruct model and wrap it as a callable.
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM

LARGE_MODEL_ID = "mistralai/Mistral-7B-Instruct-v0.3"

print(f"Loading completion model: {LARGE_MODEL_ID}")
large_tok = AutoTokenizer.from_pretrained(LARGE_MODEL_ID)
large_model = AutoModelForCausalLM.from_pretrained(
    LARGE_MODEL_ID,
    torch_dtype=torch.bfloat16,
    device_map="auto",
    load_in_8bit=True,  # fits alongside SmolLM3 in 16GB; drop if OOM-safe
)
large_model.eval()

SYSTEM_PROMPT = (
    "You are the mind of a simulated being. You receive your state and "
    "perceptions, think inside <think></think> tags, then output exactly "
    "one command. Be brief."
)

@torch.no_grad()
def completion_fn(prompt: str) -> str:
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user",   "content": prompt},
    ]
    chat = large_tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = large_tok(chat, return_tensors="pt").to(large_model.device)
    out = large_model.generate(
        **inputs,
        max_new_tokens=180,
        do_sample=True, temperature=0.4, top_p=0.9,
        pad_token_id=large_tok.eos_token_id,
    )
    text = large_tok.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)
    return text.strip() + "\n"
```

```python
# Run the v3 generator.
import sys
sys.path.insert(0, "/content/burg/training/cognitive")
from generate_command_training_v3 import generate_corpus
from pathlib import Path

summary = generate_corpus(
    trace_paths=[Path("traces/trace_phase8.jsonl")],
    output_path=Path("training/cognitive/corpus_v3.jsonl"),
    completion_fn=completion_fn,
    synthetic_ratio=2.0,   # from perception_constants.json, don't override
)
import json
print(json.dumps(summary, indent=2, default=str))
```

**Verification:**

```python
# F5 corpus-validator: MUST exit 0.
!python tools/probe_maturity.py --corpus training/cognitive/corpus_v3.jsonl --quiet

# Plan target: ≥ 5000 examples with verb-coverage on every category.
print("Corpus total:", summary["total"])
print("Replay:", summary["replay"], "Synthetic:", summary["synthetic"])
print("Verb coverage:", summary["verb_coverage"])
assert summary["total"] >= 5000, f"Corpus below plan target: {summary['total']}"
```

If `probe_maturity --corpus` returns non-zero, **stop**. The generator leaked
pre-maturity samples — this is an F5 regression, not a minor issue. Re-check
the trace and re-run. If `verb_coverage` has a zero on any required verb
(TOUCH, INTERACT, APPROACH, EXAMINE, WATCH, LOOK AT), the synthetic
scenarios didn't cover it — bug in `training/cognitive/synthetic_scenarios.py`.

**Free the completion model's VRAM before training:**

```python
del large_model, large_tok
import gc; gc.collect()
torch.cuda.empty_cache()
```

---

## Step 3 — LoRA fine-tune SmolLM3-3B on the corpus

```python
from transformers import AutoTokenizer, AutoModelForCausalLM, TrainingArguments
from peft import LoraConfig, get_peft_model
from trl import SFTTrainer, SFTConfig
from datasets import load_dataset
import torch

BASE_MODEL_ID = "HuggingFaceTB/SmolLM3-3B"
OUT_DIR = "/content/burg/training/cognitive/lora_v3"

# Convert corpus jsonl → HF dataset. Combine prompt + completion into a
# single text field the way SFTTrainer expects for completion-only training.
def format_example(ex):
    ex["text"] = f"{ex['prompt']}\n{ex['completion']}"
    return ex

ds = load_dataset("json", data_files="training/cognitive/corpus_v3.jsonl", split="train")
ds = ds.map(format_example)

tok = AutoTokenizer.from_pretrained(BASE_MODEL_ID)
if tok.pad_token is None:
    tok.pad_token = tok.eos_token

base = AutoModelForCausalLM.from_pretrained(
    BASE_MODEL_ID,
    torch_dtype=torch.bfloat16,
    device_map="auto",
)

lora = LoraConfig(
    r=16, lora_alpha=32, lora_dropout=0.05,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
    bias="none", task_type="CAUSAL_LM",
)
model = get_peft_model(base, lora)
model.print_trainable_parameters()

cfg = SFTConfig(
    output_dir=OUT_DIR,
    num_train_epochs=3,
    per_device_train_batch_size=4,    # drop to 2 if OOM on T4
    gradient_accumulation_steps=4,
    learning_rate=2e-4,
    warmup_ratio=0.03,
    lr_scheduler_type="cosine",
    logging_steps=25,
    save_strategy="epoch",
    bf16=True,
    dataset_text_field="text",
    max_seq_length=2048,
    packing=False,
    report_to="none",
)

trainer = SFTTrainer(
    model=model,
    tokenizer=tok,
    train_dataset=ds,
    args=cfg,
)
trainer.train()
trainer.save_model(OUT_DIR + "/final")
tok.save_pretrained(OUT_DIR + "/final")
```

**Verification:** training loss should decline monotonically over epochs.
End-of-run loss on ~5000 examples typically lands in the 0.8-1.5 range for
SmolLM3-3B LoRA on this kind of structured output. If loss plateaus above
2.0, the corpus has an issue (inspect 20 random lines for obvious
malformedness).

**Merge LoRA → base** so the subsequent GGUF conversion is straightforward:

```python
from peft import PeftModel

merged_dir = OUT_DIR + "/merged"
base_full = AutoModelForCausalLM.from_pretrained(
    BASE_MODEL_ID, torch_dtype=torch.bfloat16, device_map="cpu",
)
peft_model = PeftModel.from_pretrained(base_full, OUT_DIR + "/final")
merged = peft_model.merge_and_unload()
merged.save_pretrained(merged_dir, safe_serialization=True)
tok.save_pretrained(merged_dir)
print("Merged checkpoint saved to:", merged_dir)
```

---

## Step 4 — GGUF export

```python
# Install llama.cpp's conversion script.
!pip install -q sentencepiece gguf
!git clone --depth 1 https://github.com/ggerganov/llama.cpp /content/llama.cpp

!python /content/llama.cpp/convert_hf_to_gguf.py \
    /content/burg/training/cognitive/lora_v3/merged \
    --outfile /content/burg/training/cognitive/burg_v3.gguf \
    --outtype q8_0
```

**Verification:**

```python
import os
size_mb = os.path.getsize("training/cognitive/burg_v3.gguf") / (1024*1024)
print(f"GGUF size: {size_mb:.1f} MB")
# SmolLM3-3B at q8_0 should land around 3.1-3.4 GB.
assert 2500 < size_mb < 4500, "GGUF size out of expected range — check conversion"
```

---

## Step 5 — Post-deploy validation

Running the deployed GGUF through a fresh accelerated-sim pass in Colab
requires shipping Godot + the full engine scene, which is out of scope
here. Instead: run the v3 checkpoint through a **probe trace** (replay the
original prompts through the fine-tuned model and write a post-v3 trace to
check the continuous gates).

```python
from transformers import AutoTokenizer, AutoModelForCausalLM
import torch, json, time
from pathlib import Path

v3_tok = AutoTokenizer.from_pretrained("/content/burg/training/cognitive/lora_v3/merged")
v3_model = AutoModelForCausalLM.from_pretrained(
    "/content/burg/training/cognitive/lora_v3/merged",
    torch_dtype=torch.bfloat16, device_map="auto",
)
v3_model.eval()

# Replay a sample of the original trace through the v3 model to produce a
# new trace jsonl with the same fields (command, attention_entropy,
# fallback_contribution, compounds_state). The ORIGINAL record's substrate
# state is kept; only the thought + command are re-generated. This gives us
# a post-v3 trace for F1/F4/F6 probes without running the full sim.

@torch.no_grad()
def v3_generate(prompt: str) -> str:
    inputs = v3_tok(prompt, return_tensors="pt").to(v3_model.device)
    out = v3_model.generate(
        **inputs, max_new_tokens=120, do_sample=False,
        pad_token_id=v3_tok.eos_token_id,
    )
    return v3_tok.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)

post_v3_path = Path("traces/trace_post_v3.jsonl")
with open("traces/trace_phase8.jsonl") as f, post_v3_path.open("w") as g:
    for line in f:
        rec = json.loads(line)
        if rec.get("type") != "thought":
            g.write(line); continue
        prompt = rec.get("prompt_rendered") or ""
        if not prompt:
            g.write(line); continue
        completion = v3_generate(prompt)
        rec["thought"] = completion.split("<think>")[-1].split("</think>")[0].strip() if "<think>" in completion else ""
        parts = completion.split("</think>")[-1].strip().split()
        rec["command"] = parts[0] if parts else rec.get("command", "")
        rec["ts_post_v3"] = time.time()
        g.write(json.dumps(rec, default=str) + "\n")
```

**Run every continuous gate against the post-v3 trace:**

```python
# F1 — embedding-space semantic probe. Run against the base model's decode
# matrix; the v3 fine-tune should NOT have regressed neighborhoods.
!python tools/probe_embedding_semantics.py

# F4 — fallback-decay gate.
!python tools/probe_fallback_decay.py traces/trace_post_v3.jsonl --quiet

# F5 — corpus validator (re-verify the training corpus).
!python tools/probe_maturity.py --corpus training/cognitive/corpus_v3.jsonl --quiet

# F6 — attention-entropy gate.
!python tools/probe_attention_entropy.py traces/trace_post_v3.jsonl --quiet
```

All four must exit 0.

**Plan acceptance item: verb diversity > 0 on every category.** Quick
inspection of the post-v3 commands:

```python
from collections import Counter
cmds = Counter()
with open("traces/trace_post_v3.jsonl") as f:
    for line in f:
        rec = json.loads(line)
        if rec.get("type") == "thought" and rec.get("command"):
            cmds[rec["command"].split()[0]] += 1
print("Command distribution post-v3:")
for cmd, n in cmds.most_common():
    print(f"  {cmd}: {n}")

required = {"TOUCH", "INTERACT", "APPROACH", "EXAMINE", "WATCH", "LOOK AT", "SAY", "GO", "WAIT"}
missing = required - set(cmds.keys())
assert not missing, f"v3 failed verb-diversity: missing {missing}"
```

If the assertion fails, the corpus didn't have enough coverage on the
missing verbs — increase `synthetic_ratio` or re-harvest a richer trace.

---

## Step 6 — Ship artifacts back to Windows host

```python
# Package deliverables.
!tar -czf /content/burg_v3_artifacts.tar.gz \
    training/cognitive/corpus_v3.jsonl \
    training/cognitive/lora_v3/final \
    training/cognitive/lora_v3/merged \
    training/cognitive/burg_v3.gguf \
    traces/trace_post_v3.jsonl

from google.colab import files
files.download("/content/burg_v3_artifacts.tar.gz")
```

On Windows: extract the archive, move `burg_v3.gguf` to the location
`server/command_model.py` expects, and restart the game. Record a live
trace and re-run F4/F6 against it to confirm the deployed model preserves
all gates.

---

## If a gate fails

- **F1 (semantic probe):** embedding space corrupted by training. Roll back
  the fine-tune; the training corpus had enough weight on the decode-token
  distribution to shift it. Likely cause: too many epochs, or LoRA rank too
  high. Drop epochs to 2 and rerun Step 3.
- **F4 (fallback decay):** the v3 model is routing too many verbs through
  the crude distance fallback despite being "mature". Likely cause: corpus
  under-represented the compound-gated verbs. Re-run generator with more
  organic traces (record a longer accelerated sim).
- **F5 (corpus validator):** pre-maturity leaks. Re-run the generator; if
  the leak persists, there's a bug in `training/cognitive/maturity_classifier.py`
  — open a separate fix PR, don't paper over the leak.
- **F6 (attention entropy):** post-v3 attention entropy collapsed — the
  model tunneled on a few percepts. Likely cause: training temperature too
  low during replay. Regenerate post-v3 trace with `do_sample=True,
  temperature=0.5` and re-probe; if still failing, the corpus biased the
  top-K too hard, which is an F6 regression on Phase 6.
- **Verb diversity:** one or more required verbs absent from v3 output.
  Check `summary["verb_coverage"]` from Step 2 — if a verb had < 50 samples
  there, the model didn't learn it. Re-harvest.

Any of these failures is a STOP condition, not a warning. Do not ship a
v3 GGUF that leaves a gate red — the plan's contract is broken.

---

## When all green

1. Commit `training/cognitive/corpus_v3.jsonl`'s metadata (NOT the corpus
   itself — keep it out of git via `.gitignore`). A short provenance file
   in `training/cognitive/corpus_v3_metadata.json` with the summary output
   is fine.
2. Update `docs/perception_implementation_plan.md` Phase 8's Status block
   from "TOOLING SHIPPED" to "SHIPPED" with the run summary + post-v3 gate
   results.
3. Update `docs/RESUME.md` row 8 to reflect the completed run.
4. Write a memory entry `project_phase8_runtime.md` capturing:
   - Trace source (host/seed/duration)
   - Large model used for completions
   - LoRA hyperparameters
   - Loss curve shape
   - Post-deploy gate results
5. The v3 GGUF is now the active `command_model.py` backend; Phase 13
   capstone (when reached) will use traces generated by this model.
