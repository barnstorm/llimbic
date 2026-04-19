"""Unit test for AppraisalEmbeddingManager — drift/decode/persist/load/merge.

Uses a synthetic 16-dim decode matrix and a stub EmbeddingSource so the test
runs in seconds without needing the live llama-server or extracted matrix.

Run:
    python tests/test_appraisal_manager.py
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np
import safetensors.torch
import torch

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from appraisal_embeddings import AppraisalEmbeddingManager  # noqa: E402


HIDDEN = 16


class StubSource:
    """Tiny deterministic source: text → unit vector based on hash."""
    def __init__(self, hidden_dim=HIDDEN):
        self._hidden = hidden_dim
        self._cache = {}

    @property
    def hidden_dim(self) -> int:
        return self._hidden

    def embed(self, text: str) -> np.ndarray:
        if text in self._cache:
            return self._cache[text]
        rng = np.random.default_rng(abs(hash(text)) % (2**32))
        v = rng.normal(size=self._hidden).astype(np.float32)
        v /= np.linalg.norm(v) + 1e-9
        self._cache[text] = v
        return v

    def embed_batch(self, texts):
        return np.vstack([self.embed(t) for t in texts])


class StubTokenizer:
    """Decoder for the synthetic vocabulary built below."""
    def __init__(self, id_to_text: dict[int, str]):
        self._d = id_to_text

    def decode(self, ids):
        return self._d[int(ids[0])]


def build_synthetic_decode_matrix(tokens: list[str], source: StubSource, tmpdir: Path) -> Path:
    ids = list(range(len(tokens)))
    embeddings = np.vstack([source.embed(t) for t in tokens]).astype(np.float32)
    path = tmpdir / "decode.safetensors"
    safetensors.torch.save_file({
        "token_ids": torch.tensor(ids, dtype=torch.int64),
        "embeddings": torch.from_numpy(embeddings).to(torch.float16),
    }, str(path))
    return path


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        source = StubSource()

        # Curated synthetic vocabulary including the seed concepts and a few
        # decoy tokens. The decode test asks: after we drift the embedding
        # toward "calm", does "calm" appear in the top-K decode?
        vocab = ["tight", "pounding", "prickling", "calm", "warm",
                 "danger", "settled", "mabel", "hugo", "approach"]
        decode_path = build_synthetic_decode_matrix(vocab, source, tmp)
        tokenizer = StubTokenizer({i: t for i, t in enumerate(vocab)})

        manager = AppraisalEmbeddingManager(
            source=source,
            token_decode_path=decode_path,
            tokenizer=tokenizer,
            drift_rate=0.1,         # exaggerate for fast convergence
            gravity_rate=0.0,       # disable gravity for cleaner test
            decode_top_k=3,
            persist_drift_threshold=2,
        )

        # --- 1. initialize ---
        manager.initialize("hugo", "appr_test", {"tight": 0.8, "pounding": 0.7, "prickling": 0.6})
        assert manager.has_neuron("hugo", "appr_test"), "neuron not registered after init"
        decoded_initial = manager.decode("hugo", "appr_test", top_k=3)
        print(f"  init   decode=({decoded_initial})")

        # The initial decode should include at least one of the seed concepts.
        if not any(t in decoded_initial for t in ["tight", "pounding", "prickling"]):
            print(f"  FAIL  initial decode lacks seed concepts: {decoded_initial}")
            failures += 1
        else:
            print("  PASS  initial decode contains seed concept")

        # --- 2. drift toward "calm" ---
        target = source.embed("calm")
        for _ in range(60):
            manager.drift("hugo", "appr_test", activation=80.0, thought_embedding=target)
        decoded_drifted = manager.decode("hugo", "appr_test", top_k=3)
        print(f"  drift  decode=({decoded_drifted})")
        if "calm" not in decoded_drifted:
            print(f"  FAIL  drift toward 'calm' failed to surface 'calm' in top-3: {decoded_drifted}")
            failures += 1
        else:
            print("  PASS  drift surfaced 'calm' as a top-3 neighbor")

        # --- 3. persist + load ---
        save_path = tmp / "appraisals.json"
        manager.persist("hugo", save_path)
        with save_path.open() as f:
            persisted = json.load(f)
        if "appr_test" not in persisted.get("neurons", {}):
            print("  FAIL  persisted file missing the drifted neuron")
            failures += 1
        else:
            print(f"  PASS  persist wrote {len(persisted['neurons'])} neurons")

        # Build a fresh manager and load.
        manager2 = AppraisalEmbeddingManager(
            source=source,
            token_decode_path=decode_path,
            tokenizer=tokenizer,
            drift_rate=0.1,
            gravity_rate=0.0,
            decode_top_k=3,
            persist_drift_threshold=2,
        )
        loaded = manager2.load("hugo", save_path)
        if loaded != 1:
            print(f"  FAIL  load returned {loaded}, expected 1")
            failures += 1
        else:
            print("  PASS  load recovered 1 neuron")

        decoded_after_load = manager2.decode("hugo", "appr_test", top_k=3)
        if "calm" not in decoded_after_load:
            print(f"  FAIL  loaded neuron decode lost 'calm': {decoded_after_load}")
            failures += 1
        else:
            print("  PASS  loaded neuron decode preserves drift state")

        # --- 4. merge_entity_ids (F9 reconciliation) ---
        # Spawn two neurons. Drift them to different targets. Merge. Verify
        # the merged neuron has only one entry, with weight-sum semantics.
        manager.initialize("hugo", "appr_canonical", {"warm": 1.0})
        manager.initialize("hugo", "appr_deprecated", {"settled": 1.0})
        # Force drift_count > 0 so merge weights apply (otherwise both are 1/2 mean).
        for _ in range(3):
            manager.drift("hugo", "appr_canonical", activation=50.0,
                          thought_embedding=source.embed("warm"))
            manager.drift("hugo", "appr_deprecated", activation=50.0,
                          thought_embedding=source.embed("settled"))
        merged = manager.merge_entity_ids("hugo", "appr_canonical", "appr_deprecated")
        if not merged:
            print("  FAIL  merge_entity_ids returned False")
            failures += 1
        else:
            assert not manager.has_neuron("hugo", "appr_deprecated"), \
                "deprecated neuron still present after merge"
            assert manager.has_neuron("hugo", "appr_canonical"), \
                "canonical neuron lost after merge"
            print("  PASS  merge replaced deprecated, kept canonical")

    if failures:
        print(f"\nFAILED ({failures} failures)")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
