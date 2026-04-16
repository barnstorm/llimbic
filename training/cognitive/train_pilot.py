#!/usr/bin/env python3
"""
Fine-tune Phi-3.5-mini-instruct with LoRA on the cognitive pilot data.

Uses the same approach as the limbic model training:
- LoRA rank 8, alpha 16, targeting q_proj + v_proj + k_proj + o_proj
- 3 epochs over 145 examples
- Learning rate 2e-4 with cosine schedule
- bf16 training on CUDA

Output: training/cognitive/phi35-cognitive-lora/
"""

import os
import json
import torch
from datasets import Dataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    TrainingArguments,
    Trainer,
    DataCollatorForSeq2Seq,
)
from peft import LoraConfig, get_peft_model, TaskType

# --- Config ---
BASE_MODEL = "microsoft/Phi-3.5-mini-instruct"
DATA_PATH = "training/cognitive/pilot_data.jsonl"
OUTPUT_DIR = "training/cognitive/phi35-cognitive-lora"
EPOCHS = 3
BATCH_SIZE = 1
GRAD_ACCUM = 4
LR = 2e-4
MAX_SEQ_LEN = 512
LORA_R = 8
LORA_ALPHA = 16
LORA_DROPOUT = 0.05

def main():
    print(f"Loading base model: {BASE_MODEL}")
    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL,
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
        attn_implementation="eager",  # avoid flash-attn requirement
    )

    # --- LoRA ---
    print("Applying LoRA...")
    lora_config = LoraConfig(
        task_type=TaskType.CAUSAL_LM,
        r=LORA_R,
        lora_alpha=LORA_ALPHA,
        lora_dropout=LORA_DROPOUT,
        target_modules=["qkv_proj", "o_proj"],  # Phi-3 uses fused qkv_proj
        bias="none",
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # --- Load data ---
    print(f"Loading data from {DATA_PATH}")
    examples = []
    with open(DATA_PATH) as f:
        for line in f:
            examples.append(json.loads(line))
    print(f"  {len(examples)} examples loaded")

    # --- Tokenize ---
    def tokenize(example):
        messages = example["messages"]
        text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
        # Tokenize the full conversation
        tokenized = tokenizer(
            text,
            truncation=True,
            max_length=MAX_SEQ_LEN,
            padding=False,
        )
        # For causal LM training, labels = input_ids (shifted internally by the model)
        tokenized["labels"] = tokenized["input_ids"].copy()
        return tokenized

    dataset = Dataset.from_list(examples)
    tokenized_dataset = dataset.map(tokenize, remove_columns=dataset.column_names)
    print(f"  Tokenized: {len(tokenized_dataset)} examples, "
          f"avg {sum(len(x['input_ids']) for x in tokenized_dataset)/len(tokenized_dataset):.0f} tokens")

    # --- Training ---
    training_args = TrainingArguments(
        output_dir=OUTPUT_DIR,
        num_train_epochs=EPOCHS,
        per_device_train_batch_size=BATCH_SIZE,
        gradient_accumulation_steps=GRAD_ACCUM,
        learning_rate=LR,
        lr_scheduler_type="cosine",
        warmup_ratio=0.1,
        bf16=True,
        logging_steps=10,
        save_strategy="epoch",
        save_total_limit=2,
        report_to="none",
        remove_unused_columns=False,
        dataloader_pin_memory=False,
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized_dataset,
        data_collator=DataCollatorForSeq2Seq(tokenizer, padding=True, pad_to_multiple_of=8),
    )

    print("Starting training...")
    trainer.train()

    # --- Save ---
    print(f"Saving LoRA adapter to {OUTPUT_DIR}")
    model.save_pretrained(OUTPUT_DIR)
    tokenizer.save_pretrained(OUTPUT_DIR)
    print("Done!")


if __name__ == "__main__":
    main()
