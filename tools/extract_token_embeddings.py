"""Extract token embeddings via the live llama-server /embedding endpoint.

Phase 0 of docs/perception_implementation_plan.md. The output file is the decode
matrix used by AppraisalEmbeddingManager.decode() — given a drifted appraisal
embedding, find the nearest tokens via cosine similarity.

Why this approach instead of dequantizing the GGUF token_embd tensor?
- The /embedding endpoint with --pooling mean returns the model's last-layer
  pooled hidden state for the input text. Appraisal embeddings drift in that
  same space (they are produced by embedding generated thoughts via the same
  endpoint). Decoding against a matrix produced by the same encoder keeps
  cosine well-defined.
- Dequantizing the Q6_K embedding tensor from the GGUF gives input-layer
  vectors that live in a different space than the /embedding output — cosine
  between drift and decode would be apples-to-oranges.
- Cost is bounded: ~30k filtered tokens * ~50ms per call / 2-way parallelism
  ≈ 12 minutes. One-time, then the matrix is reused forever.

Filter (per spec §11.2):
- Token must contain at least one alphabetic character.
- Decoded length must be >= 2 characters after stripping whitespace.
- No special / control / unicode-only tokens.

Output: data/token_embeddings_layer0.safetensors with two tensors:
  - "token_ids":   int64  [N]
  - "embeddings": float32 [N, 2048]   (unit-normalized, row-aligned with token_ids)

Usage:
    python tools/extract_token_embeddings.py [--port 8499] [--output data/...]
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np
import requests
import safetensors.torch  # for save_file
import torch
from transformers import AutoTokenizer

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GGUF = REPO_ROOT / "training" / "cognitive" / "SmolLM3-3B.Q4_K_M.gguf"
DEFAULT_LLAMA_BIN = "/tmp/llama.cpp/build/bin/llama-server"
DEFAULT_OUTPUT = REPO_ROOT / "data" / "token_embeddings_layer0.safetensors"
DEFAULT_PORT = 8499
HF_MODEL = "HuggingFaceTB/SmolLM3-3B"
HIDDEN_DIM = 2048


def is_meaningful_token(decoded: str) -> bool:
    """Liberal filter: at least one alpha char, decoded length >= 2."""
    s = decoded.strip()
    if len(s) < 2:
        return False
    if not any(c.isalpha() for c in s):
        return False
    return True


def start_llama_server(gguf: Path, port: int, llama_bin: str) -> subprocess.Popen:
    print(f"[extract] starting llama-server on port {port}...")
    proc = subprocess.Popen(
        [
            llama_bin,
            "-m", str(gguf),
            "--port", str(port),
            "--ctx-size", "2048",
            "-t", "8",
            "-np", "4",
            "--embedding", "--pooling", "mean",
            "--log-disable",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )
    health_url = f"http://127.0.0.1:{port}/health"
    for _ in range(120):
        try:
            r = requests.get(health_url, timeout=1)
            if r.status_code == 200:
                print(f"[extract] llama-server ready on port {port}")
                return proc
        except requests.ConnectionError:
            pass
        time.sleep(1)
    proc.terminate()
    raise RuntimeError("llama-server failed to come up within 120s")


def stop_llama_server(proc: subprocess.Popen) -> None:
    print("[extract] stopping llama-server...")
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=10)
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass


def embed_one(session: requests.Session, port: int, text: str) -> np.ndarray | None:
    """Call /embedding for a single piece of text. Returns unit-norm vector or None."""
    try:
        r = session.post(
            f"http://127.0.0.1:{port}/embedding",
            json={"content": text},
            timeout=20,
        )
        r.raise_for_status()
        data = r.json()
    except Exception as e:
        print(f"[extract] embed error for {text!r}: {e}", file=sys.stderr)
        return None

    # Response shape: list of {embedding: [[...]]} OR dict with embedding field.
    emb = None
    if isinstance(data, list):
        item = data[0] if data else {}
        emb = item.get("embedding")
    elif isinstance(data, dict):
        emb = data.get("embedding")
    while isinstance(emb, list) and emb and isinstance(emb[0], list):
        emb = emb[0]
    if not emb:
        return None
    v = np.asarray(emb, dtype=np.float32)
    n = np.linalg.norm(v)
    if n < 1e-9:
        return None
    return v / n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gguf", type=Path, default=DEFAULT_GGUF)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--llama-bin", default=DEFAULT_LLAMA_BIN)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--workers", type=int, default=4,
                    help="Concurrent /embedding requests (server -np must be >= this)")
    ap.add_argument("--limit", type=int, default=0,
                    help="If >0, only encode this many tokens (smoke testing)")
    ap.add_argument("--reuse-port", action="store_true",
                    help="Use existing llama-server on --port (don't start one)")
    args = ap.parse_args()

    if not args.gguf.exists():
        print(f"GGUF not found: {args.gguf}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)

    print(f"[extract] loading tokenizer {HF_MODEL}...")
    tokenizer = AutoTokenizer.from_pretrained(HF_MODEL)
    n_total = len(tokenizer)
    print(f"[extract] vocab size = {n_total}")

    candidates: list[tuple[int, str]] = []
    for tid in range(n_total):
        decoded = tokenizer.decode([tid])
        if is_meaningful_token(decoded):
            candidates.append((tid, decoded.strip()))
    print(f"[extract] meaningful tokens after filter: {len(candidates)} ({len(candidates) / n_total * 100:.1f}%)")
    if args.limit > 0:
        candidates = candidates[: args.limit]
        print(f"[extract] limited to first {len(candidates)} tokens")

    proc = None
    if not args.reuse_port:
        proc = start_llama_server(args.gguf, args.port, args.llama_bin)
    else:
        print(f"[extract] reusing existing server on port {args.port}")

    try:
        session = requests.Session()
        n = len(candidates)
        token_ids = np.zeros(n, dtype=np.int64)
        embeddings = np.zeros((n, HIDDEN_DIM), dtype=np.float32)
        valid_mask = np.zeros(n, dtype=bool)

        t0 = time.time()
        with ThreadPoolExecutor(max_workers=args.workers) as ex:
            futures = {
                ex.submit(embed_one, session, args.port, text): (i, tid, text)
                for i, (tid, text) in enumerate(candidates)
            }
            done_count = 0
            for fut in as_completed(futures):
                i, tid, text = futures[fut]
                v = fut.result()
                if v is not None and v.shape == (HIDDEN_DIM,):
                    token_ids[i] = tid
                    embeddings[i] = v
                    valid_mask[i] = True
                done_count += 1
                if done_count % 500 == 0 or done_count == n:
                    elapsed = time.time() - t0
                    rate = done_count / max(elapsed, 1e-3)
                    remain = (n - done_count) / max(rate, 1e-3)
                    print(f"[extract] {done_count}/{n} ({100 * done_count / n:.1f}%) "
                          f"rate={rate:.1f}/s eta={remain:.0f}s")

        kept = valid_mask.sum()
        print(f"[extract] {kept}/{n} tokens encoded ({100 * kept / n:.1f}%)")

        token_ids = token_ids[valid_mask]
        embeddings = embeddings[valid_mask]

        print(f"[extract] saving to {args.output} (fp16)")
        safetensors.torch.save_file(
            {
                "token_ids": torch.from_numpy(token_ids),
                "embeddings": torch.from_numpy(embeddings).to(torch.float16),
            },
            str(args.output),
        )
        print(f"[extract] done. shape={embeddings.shape} bytes={args.output.stat().st_size:,}")
        return 0
    finally:
        if proc is not None:
            stop_llama_server(proc)


if __name__ == "__main__":
    sys.exit(main())
