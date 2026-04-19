"""Extract per-token layer-24 residuals (T1) for SmolLM3-3B.

Phase 0.5 of docs/perception_implementation_plan.md.

Background. F1 hard gate (tools/probe_embedding_semantics.py) failed at T0 with
62.1% pass — last-layer mean-pooled embeddings cluster on surface co-occurrence,
not semantics. Six failures landed on bootstrap quality concepts (heavy,
churning, hollow, foggy, buzzing, numb) — the very seed vocabulary Phase 5
identity-appraisal depends on. "familiar" decoded to its antonym "unusual".

Per appraisal_layer_spec.md and perception_spec §3.8: layer 24 (~66% deep into
SmolLM3-3B's 36 layers) is the semantic sweet spot — body/quality concepts
cluster by emotional-somatic role, not surface tokens.

Approach. For each meaningful vocab token:
  1. Construct input as [BOS, token_id]
  2. Forward through the model with output_hidden_states=True
  3. Take hidden_states[24] at position 1 (the actual token, not BOS)
  4. Unit-normalize, store

Batched on GPU; ~1-2 minutes for ~113k tokens vs. ~20 min via /embedding at T0.

Output: data/token_embeddings_layer24.safetensors with the same keys/shape as
the T0 file, just in a different latent space. Consumers (AppraisalEmbeddingManager,
F1 probe) switch via a single path argument.

Usage:
    python tools/extract_token_embeddings_t1.py [--limit 200] [--batch 64]
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import safetensors.torch
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "data" / "token_embeddings_layer24.safetensors"
HF_MODEL = "HuggingFaceTB/SmolLM3-3B"
LAYER = 24                  # 1-indexed; hidden_states[24] is the residual after layer 23
HIDDEN_DIM = 2048           # SmolLM3-3B
BATCH_SIZE_DEFAULT = 64


def is_meaningful_token(decoded: str) -> bool:
    """Same filter as T0: alpha-only, length >= 2."""
    s = decoded.strip()
    return len(s) >= 2 and any(c.isalpha() for c in s)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--batch", type=int, default=BATCH_SIZE_DEFAULT)
    ap.add_argument("--limit", type=int, default=0,
                    help="If >0, only encode this many tokens (smoke testing)")
    ap.add_argument("--device", default=None,
                    help="cuda|cpu|auto (default: cuda if available)")
    ap.add_argument("--layer", type=int, default=LAYER,
                    help="Hidden state index to extract (default 24)")
    args = ap.parse_args()

    if args.device is None:
        device = "cuda" if torch.cuda.is_available() else "cpu"
    else:
        device = args.device
    dtype = torch.float16 if device != "cpu" else torch.float32
    print(f"[t1] device={device} dtype={dtype} layer={args.layer}", file=sys.stderr)

    args.output.parent.mkdir(parents=True, exist_ok=True)

    print(f"[t1] loading tokenizer + model {HF_MODEL}...", file=sys.stderr)
    t0 = time.time()
    tokenizer = AutoTokenizer.from_pretrained(HF_MODEL)
    model = AutoModelForCausalLM.from_pretrained(
        HF_MODEL,
        torch_dtype=dtype,
        device_map=device if device != "cpu" else None,
    )
    if device == "cpu":
        model = model.to(device)
    model.eval()
    print(f"[t1] model loaded in {time.time() - t0:.1f}s", file=sys.stderr)

    # Sanity-check the layer count and hidden dim.
    cfg = model.config
    n_layers = getattr(cfg, "num_hidden_layers", None) or getattr(cfg, "n_layer", None)
    if args.layer > (n_layers or 0):
        raise SystemExit(f"--layer {args.layer} exceeds model layer count {n_layers}")
    real_hidden = getattr(cfg, "hidden_size", None)
    if real_hidden != HIDDEN_DIM:
        print(f"[t1] WARNING: model hidden_size={real_hidden} != expected {HIDDEN_DIM}",
              file=sys.stderr)

    bos_id = tokenizer.bos_token_id
    if bos_id is None:
        # SmolLM3 uses <|im_start|> formatting; fall back to a benign token.
        bos_id = tokenizer.eos_token_id or 0
        print(f"[t1] no bos_token_id; using token {bos_id} as prefix", file=sys.stderr)

    # Build candidate list once.
    print(f"[t1] enumerating vocab and filtering...", file=sys.stderr)
    n_vocab = len(tokenizer)
    candidates: list[int] = []
    for tid in range(n_vocab):
        decoded = tokenizer.decode([tid])
        if is_meaningful_token(decoded):
            candidates.append(tid)
    print(f"[t1] {len(candidates)}/{n_vocab} meaningful tokens "
          f"({len(candidates) / n_vocab * 100:.1f}%)", file=sys.stderr)
    if args.limit > 0:
        candidates = candidates[: args.limit]
        print(f"[t1] limited to first {len(candidates)}", file=sys.stderr)

    n = len(candidates)
    embeddings = np.zeros((n, real_hidden or HIDDEN_DIM), dtype=np.float32)
    token_ids_arr = np.asarray(candidates, dtype=np.int64)

    t0 = time.time()
    with torch.no_grad():
        for batch_start in range(0, n, args.batch):
            batch = candidates[batch_start: batch_start + args.batch]
            input_ids = torch.tensor(
                [[bos_id, t] for t in batch], device=device, dtype=torch.long
            )
            outputs = model(input_ids, output_hidden_states=True, use_cache=False)
            # outputs.hidden_states is a tuple of length n_layers+1
            # hidden_states[L] shape: [B, seq_len=2, H]
            # Position 1 is our actual token (position 0 is BOS).
            layer_residuals = outputs.hidden_states[args.layer][:, 1, :]
            # Normalize to unit length on the GPU before transfer.
            norms = layer_residuals.norm(dim=1, keepdim=True).clamp_min(1e-9)
            unit = (layer_residuals / norms).float().cpu().numpy()
            embeddings[batch_start: batch_start + len(batch)] = unit

            done = batch_start + len(batch)
            if done % (args.batch * 16) == 0 or done == n:
                elapsed = time.time() - t0
                rate = done / max(elapsed, 1e-3)
                eta = (n - done) / max(rate, 1e-3)
                print(f"[t1] {done}/{n} ({100 * done / n:.1f}%) "
                      f"rate={rate:.0f}/s eta={eta:.0f}s", file=sys.stderr)

    print(f"[t1] saving to {args.output} (fp16)", file=sys.stderr)
    safetensors.torch.save_file(
        {
            "token_ids": torch.from_numpy(token_ids_arr),
            "embeddings": torch.from_numpy(embeddings).to(torch.float16),
        },
        str(args.output),
    )
    print(f"[t1] done. shape={embeddings.shape} bytes={args.output.stat().st_size:,}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
