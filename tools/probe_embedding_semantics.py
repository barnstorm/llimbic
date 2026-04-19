"""F1 semantic-neighborhood probe — HARD GATE for Phase 0.

Per docs/perception_implementation_plan.md Phase 0 (F1):

> Phase 0 acceptance is satisfiable without validating the architecture: drift
> happens regardless of whether the embedding space is semantic. Input-layer
> T0 clusters by surface co-occurrence ("tight" ~ "tightly", but maybe NOT
> "tight" ~ "clenched"). You can ship Phase 0 green while the bridge is
> producing lexical noise that won't serve the downstream phases.

This probe runs a fixed set of (anchor, expected_neighbors) pairs through
the live /embedding endpoint and the token decode matrix. For each anchor,
it asks: does at least one of the expected neighbors appear in the top-10
cosine-nearest tokens?

PASS criterion: ≥ semantic_probe_min_pass_rate (default 0.7) of probes pass.
- PASS  → T0 is sufficient. Continue Phase 0 implementation.
- FAIL  → T0 produces lexical noise. Phase 0.5 (T1 mid-layer extraction) is
           mandatory before continuing — the substrate cannot deliver the
           identity-appraisal divergence Phase 5 requires on a noisy bridge.

Run:
    python tools/probe_embedding_semantics.py [--port 8499] [--start-server]
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import requests
import safetensors.torch
import torch
from transformers import AutoTokenizer

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from embedding_source import LlamaServerEmbeddingSource, TransformersMidLayerEmbeddingSource  # noqa: E402

DEFAULT_DECODE_MATRIX = REPO_ROOT / "data" / "token_embeddings_layer0.safetensors"
DEFAULT_DECODE_MATRIX_T1 = REPO_ROOT / "data" / "token_embeddings_layer24.safetensors"
DEFAULT_GGUF = REPO_ROOT / "training" / "cognitive" / "SmolLM3-3B.Q4_K_M.gguf"
DEFAULT_LLAMA_BIN = "/tmp/llama.cpp/build/bin/llama-server"
DEFAULT_CONSTANTS = REPO_ROOT / "data" / "perception_constants.json"
DEFAULT_PORT = 8499
HF_MODEL = "HuggingFaceTB/SmolLM3-3B"
HIDDEN_DIM = 2048
TOP_K = 10

# Probe set. Each entry: (anchor_text, [expected_neighbor_words]).
# An anchor PASSES if any expected neighbor appears in the top-K nearest tokens.
# Probes cover the bootstrap concept set, reward-relevant vocabulary, and a
# handful of high-stakes cross-domain semantics that downstream phases depend on.
PROBES: list[tuple[str, list[str]]] = [
    # Bootstrap quality concepts (must cluster with synonymous quality words).
    ("tight",       ["tightly", "tighten", "clenched", "constricted", "taut", "tense"]),
    ("loose",       ["loosen", "loosely", "slack", "relaxed", "limp"]),
    ("warm",        ["warmth", "hot", "cozy", "toasty", "heated", "balmy"]),
    ("heavy",       ["weight", "weighty", "ponderous", "leaden", "massive"]),
    ("settled",     ["settle", "calm", "still", "quiet", "peaceful"]),
    ("churning",    ["churn", "swirling", "roiling", "tumbling", "agitated"]),
    ("pounding",    ["pound", "thumping", "throbbing", "hammering", "drumming"]),
    ("hollow",      ["hollowness", "empty", "void", "vacant", "cavernous"]),
    ("prickling",   ["prickle", "tingling", "stinging", "needling"]),
    ("open",        ["openness", "wide", "spacious"]),
    ("clear",       ["clearly", "clarity", "lucid", "transparent"]),
    ("foggy",       ["fog", "hazy", "murky", "muddy", "cloudy"]),
    ("buzzing",     ["buzz", "humming", "vibrating"]),
    ("numb",        ["numbness", "deadened", "frozen", "paralyzed"]),

    # Reward-relevant: threat / danger / safety axis.
    ("threat",      ["threatening", "danger", "dangerous", "menace", "peril", "risk"]),
    ("danger",      ["dangerous", "threat", "peril", "hazard", "risk", "menace"]),
    ("safe",        ["safety", "secure", "protected", "unharmed"]),
    ("fear",        ["afraid", "fearful", "frightened", "scared", "terrified", "dread"]),

    # Reward-relevant: hunger / food / consumption axis.
    ("hungry",      ["hunger", "starving", "famished", "ravenous", "appetite"]),
    ("food",        ["meal", "eat", "nourishment", "sustenance", "bread"]),

    # Reward-relevant: social / familiarity axis.
    ("friend",      ["friends", "companion", "ally", "buddy", "comrade"]),
    ("familiar",    ["familiarity", "known", "recognized", "acquainted"]),
    ("stranger",    ["strangers", "unknown", "unfamiliar", "outsider"]),

    # Action / verb concepts that downstream affordance compounds key on.
    ("approach",    ["approaching", "near", "toward", "draw close"]),
    ("touch",       ["touching", "feel", "contact", "handle", "grasp"]),
    ("flee",        ["fleeing", "escape", "run", "retreat", "withdraw"]),
    ("rest",        ["resting", "sleep", "repose", "relax", "recover"]),

    # Place / environment.
    ("home",        ["dwelling", "house", "abode", "shelter"]),
    ("forest",      ["forests", "woods", "trees", "woodland"]),
]

# Each probe checks word-stem matches case-insensitively, allowing for plural/
# tense variants the model may decode (e.g. anchor "warm" might decode "warms",
# "warmth", "warming" — all count as the "warm" family).


def _matches(decoded: str, expected_word: str) -> bool:
    d = decoded.lower().strip()
    e = expected_word.lower().strip()
    if not d or not e:
        return False
    # Exact match, or one is a prefix/contains the other (catches plural/tense).
    return d == e or d.startswith(e) or e.startswith(d) or e in d or d in e


def _start_server(gguf: Path, port: int, llama_bin: str) -> subprocess.Popen:
    print(f"[probe] starting llama-server on port {port}...", file=sys.stderr)
    proc = subprocess.Popen(
        [
            llama_bin,
            "-m", str(gguf),
            "--port", str(port),
            "--ctx-size", "2048",
            "-t", "8", "-np", "2",
            "--embedding", "--pooling", "mean",
            "--log-disable",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )
    for _ in range(120):
        try:
            r = requests.get(f"http://127.0.0.1:{port}/health", timeout=1)
            if r.status_code == 200:
                print(f"[probe] llama-server ready", file=sys.stderr)
                return proc
        except requests.ConnectionError:
            pass
        time.sleep(1)
    proc.terminate()
    raise RuntimeError("llama-server failed to come up within 120s")


def _stop_server(proc: subprocess.Popen) -> None:
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=10)
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass


def _load_decode_matrix(path: Path):
    tensors = safetensors.torch.load_file(str(path))
    token_ids = tensors["token_ids"].numpy().astype(np.int64)
    embeddings = tensors["embeddings"].to(torch.float32).numpy()
    norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
    norms = np.where(norms < 1e-9, 1.0, norms)
    return token_ids, (embeddings / norms).astype(np.float32, copy=False)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tier", choices=["t0", "t1"], default="t0",
                    help="Which embedding tier to probe. t0=llama-server /embedding, "
                         "t1=transformers layer-24 residual")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--decode-matrix", type=Path, default=None,
                    help="Decode matrix path. Defaults vary by tier: "
                         "t0→data/token_embeddings_layer0.safetensors, "
                         "t1→data/token_embeddings_layer24.safetensors")
    ap.add_argument("--constants", type=Path, default=DEFAULT_CONSTANTS)
    ap.add_argument("--gguf", type=Path, default=DEFAULT_GGUF)
    ap.add_argument("--llama-bin", default=DEFAULT_LLAMA_BIN)
    ap.add_argument("--start-server", action="store_true",
                    help="(t0 only) Start a dedicated llama-server")
    ap.add_argument("--layer", type=int, default=24,
                    help="(t1 only) Mid-layer index to extract")
    ap.add_argument("--top-k", type=int, default=TOP_K)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--report", type=Path, default=None,
                    help="Write detailed JSON report to this path")
    args = ap.parse_args()

    if args.decode_matrix is None:
        args.decode_matrix = (
            DEFAULT_DECODE_MATRIX_T1 if args.tier == "t1" else DEFAULT_DECODE_MATRIX
        )

    if not args.decode_matrix.exists():
        print(f"FAIL: decode matrix missing at {args.decode_matrix}.\n"
              f"      Run: python tools/extract_token_embeddings.py", file=sys.stderr)
        return 2

    with args.constants.open() as f:
        constants = json.load(f)
    pass_threshold = float(constants.get("semantic_probe_min_pass_rate", 0.7))

    print(f"[probe] loading tokenizer + decode matrix...", file=sys.stderr)
    tokenizer = AutoTokenizer.from_pretrained(HF_MODEL)
    token_ids, decode = _load_decode_matrix(args.decode_matrix)
    print(f"[probe] decode matrix: {decode.shape[0]} tokens × {decode.shape[1]}d", file=sys.stderr)

    proc = None
    source = None
    if args.tier == "t0":
        if args.start_server:
            proc = _start_server(args.gguf, args.port, args.llama_bin)
        source = LlamaServerEmbeddingSource(port=args.port, hidden_dim=HIDDEN_DIM)
    else:
        # T1: transformers, layer-24 residual. Loads SmolLM3-3B in-process
        # (~10s, ~6GB GPU mem). The decode matrix must also be at the same layer.
        print(f"[probe] T1 mode: loading SmolLM3 + extracting layer {args.layer}",
              file=sys.stderr)
        source = TransformersMidLayerEmbeddingSource(layer=args.layer)

    try:

        results = []
        passed = 0
        for anchor, expected in PROBES:
            v = source.embed(anchor)
            if np.linalg.norm(v) < 1e-9:
                results.append({"anchor": anchor, "ok": False, "reason": "zero embedding",
                                "neighbors": [], "expected": expected})
                continue
            sims = decode @ v
            top_idx = np.argpartition(-sims, args.top_k)[: args.top_k]
            top_idx = top_idx[np.argsort(-sims[top_idx])]
            neighbors: list[str] = []
            for idx in top_idx:
                tid = int(token_ids[idx])
                tok = tokenizer.decode([tid]).strip()
                if tok:
                    neighbors.append(tok)

            ok = any(_matches(n, e) for n in neighbors for e in expected)
            results.append({
                "anchor": anchor,
                "ok": ok,
                "neighbors": neighbors,
                "expected": expected,
                "match": [n for n in neighbors if any(_matches(n, e) for e in expected)],
            })
            if ok:
                passed += 1

        # Report.
        n = len(results)
        rate = passed / n if n else 0.0
        gate_pass = rate >= pass_threshold
        verdict = "PASS" if gate_pass else "FAIL"

        for r in results:
            mark = "PASS" if r["ok"] else "FAIL"
            if args.verbose or not r["ok"]:
                print(f"[{mark}] {r['anchor']:12s} → top10: {r['neighbors']}")
                if not r["ok"]:
                    print(f"          expected any of: {r['expected']}")

        print()
        print(f"[probe] passed {passed}/{n} probes ({rate:.1%})")
        print(f"[probe] threshold: {pass_threshold:.1%}")
        print(f"[probe] VERDICT: {verdict}")
        if not gate_pass:
            print()
            print("  T0 input-layer/last-pooled embeddings produce lexical noise.")
            print("  Identity-appraisal divergence (Phase 5) cannot rest on this bridge.")
            print("  Phase 0.5 (T1 mid-layer extraction) is MANDATORY before continuing.")
            print("  See docs/perception_implementation_plan.md Phase 0.5.")

        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            with args.report.open("w") as f:
                json.dump({
                    "verdict": verdict,
                    "rate": rate,
                    "threshold": pass_threshold,
                    "results": results,
                }, f, indent=2)
            print(f"[probe] wrote detailed report → {args.report}")

        return 0 if gate_pass else 1
    finally:
        if proc is not None:
            _stop_server(proc)


if __name__ == "__main__":
    sys.exit(main())
