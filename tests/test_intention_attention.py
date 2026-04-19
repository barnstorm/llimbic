"""Phase 11 — IntentionAttention selector unit tests.

Verifies:
- Given a goal whose embedding is near a bootstrap concept, q_{concept}
  lands in the returned neuron_ids.
- Given a goal whose embedding is near an active appraisal's drifted
  vector, that appraisal neuron ID lands in the returned list.
- Negative-cosine concepts are filtered out.
- Top-K cap honored.
- Different goals produce different selections (the individuation point
  of Phase 11).

Run:
    python3 tests/test_intention_attention.py
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import numpy as np
import safetensors.torch
import torch

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from intention_attention import IntentionAttention  # noqa: E402
from appraisal_embeddings import AppraisalEmbeddingManager  # noqa: E402


HIDDEN = 16


class StubSource:
    def __init__(self, hidden_dim: int = HIDDEN):
        self._hidden = hidden_dim
        self._cache: dict[str, np.ndarray] = {}
        self._overrides: dict[str, np.ndarray] = {}

    @property
    def hidden_dim(self) -> int:
        return self._hidden

    def set_override(self, text: str, vec: np.ndarray) -> None:
        v = vec.astype(np.float32)
        v /= np.linalg.norm(v) + 1e-9
        self._overrides[text] = v
        self._cache.pop(text, None)

    def embed(self, text: str) -> np.ndarray:
        if text in self._overrides:
            return self._overrides[text]
        if text in self._cache:
            return self._cache[text]
        rng = np.random.default_rng(abs(hash(text)) % (2**32))
        v = rng.normal(size=self._hidden).astype(np.float32)
        v /= np.linalg.norm(v) + 1e-9
        self._cache[text] = v
        return v


class StubTokenizer:
    def __init__(self, id_to_text: dict[int, str]):
        self._d = id_to_text

    def decode(self, ids):
        return self._d[int(ids[0])]


def _build_decode_matrix(tokens: list[str], source: StubSource, tmpdir: Path) -> Path:
    ids = list(range(len(tokens)))
    embeddings = np.vstack([source.embed(t) for t in tokens]).astype(np.float32)
    path = tmpdir / "decode.safetensors"
    safetensors.torch.save_file({
        "token_ids": torch.tensor(ids, dtype=torch.int64),
        "embeddings": torch.from_numpy(embeddings).to(torch.float16),
    }, str(path))
    return path


def test_bootstrap_concept_wins_on_aligned_goal(failures: list[str]) -> None:
    src = StubSource()
    # Align "find warmth" goal with "warm" concept.
    v = np.ones(HIDDEN, dtype=np.float32)
    src.set_override("find warmth", v)
    src.set_override("warm", v)  # perfectly aligned
    src.set_override("tight", np.array([1.0] + [0.0] * (HIDDEN - 1), dtype=np.float32))  # orthogonalish

    ia = IntentionAttention(src, None, bootstrap_concepts=["warm", "tight", "settled"], top_k=3)
    ctx = ia.select_intention_context("hugo", "find warmth", active_appraisal_ids=[])
    if not ctx.neuron_ids or ctx.neuron_ids[0] != "q_warm":
        failures.append(f"q_warm should lead for 'find warmth' goal; got {ctx.neuron_ids}")
    else:
        print(f"  PASS  goal 'find warmth' → top pick q_warm (scores={ctx.scores})")


def test_active_appraisal_competes_with_bootstrap(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src = StubSource()
        vocab = ["warm", "familiar", "mabel", "hugo", "approach"]
        decode_path = _build_decode_matrix(vocab, src, tmp)
        tok = StubTokenizer({i: t for i, t in enumerate(vocab)})
        mgr = AppraisalEmbeddingManager(source=src, token_decode_path=decode_path, tokenizer=tok)

        # Seed an identity-appraisal whose drifted embedding aligns with
        # the goal. Use a dedicated vector so we control cosine precisely.
        goal_vec = np.ones(HIDDEN, dtype=np.float32)
        src.set_override("talk to Mabel", goal_vec)
        mgr.initialize_from_thoughts("hugo", "appr_identity_ent_mabel",
                                     [goal_vec.copy(), goal_vec.copy()])

        ia = IntentionAttention(src, mgr, bootstrap_concepts=["warm"], top_k=2)
        ctx = ia.select_intention_context(
            "hugo", "talk to Mabel",
            active_appraisal_ids=["appr_identity_ent_mabel"],
        )
        if "appr_identity_ent_mabel" not in ctx.neuron_ids:
            failures.append(f"active appraisal did not land in intention context: {ctx.neuron_ids}")
        elif "appraisal" not in ctx.sources:
            failures.append(f"sources did not include appraisal: {ctx.sources}")
        else:
            print(f"  PASS  active appraisal competes with bootstrap (ids={ctx.neuron_ids})")


def test_negative_cosine_filtered(failures: list[str]) -> None:
    src = StubSource()
    # "fear" goal aligned to -1 direction; "calm" aligned to +1 direction.
    src.set_override("flee threat", np.array([-1.0] + [0.0] * (HIDDEN - 1), dtype=np.float32))
    src.set_override("calm", np.array([1.0] + [0.0] * (HIDDEN - 1), dtype=np.float32))
    src.set_override("prickling", np.array([-1.0] + [0.0] * (HIDDEN - 1), dtype=np.float32))
    ia = IntentionAttention(src, None, bootstrap_concepts=["calm", "prickling"], top_k=3)
    ctx = ia.select_intention_context("hugo", "flee threat", active_appraisal_ids=[])
    # "prickling" aligns with goal direction → positive cosine → included.
    # "calm" is opposite → negative cosine → filtered out.
    if "q_calm" in ctx.neuron_ids:
        failures.append(f"q_calm (negative cosine) should be filtered: {ctx.neuron_ids}")
    if "q_prickling" not in ctx.neuron_ids:
        failures.append(f"q_prickling (positive cosine) should be included: {ctx.neuron_ids}")
    print(f"  PASS  negative-cosine concepts filtered ({ctx.neuron_ids})")


def test_topk_cap(failures: list[str]) -> None:
    src = StubSource()
    ia = IntentionAttention(src, None,
                            bootstrap_concepts=["a", "b", "c", "d", "e", "f"], top_k=2)
    ctx = ia.select_intention_context("hugo", "anything", active_appraisal_ids=[])
    if len(ctx.neuron_ids) > 2:
        failures.append(f"top_k cap violated: {ctx.neuron_ids}")
    else:
        print(f"  PASS  top_k cap honored ({len(ctx.neuron_ids)} ≤ 2)")


def test_different_goals_differ(failures: list[str]) -> None:
    """Plan acceptance: same being, two intentions, two different top-K
    rankings on identical scene. This is the mechanism-level check; the
    live Godot test verifies amplification downstream."""
    src = StubSource()
    # Two goals pointing to opposite directions in embedding space.
    src.set_override("seek warmth", np.array([1.0] + [0.0] * (HIDDEN - 1), dtype=np.float32))
    src.set_override("seek rest", np.array([0.0, 1.0] + [0.0] * (HIDDEN - 2), dtype=np.float32))
    src.set_override("warm", np.array([1.0] + [0.0] * (HIDDEN - 1), dtype=np.float32))
    src.set_override("settled", np.array([0.0, 1.0] + [0.0] * (HIDDEN - 2), dtype=np.float32))
    ia = IntentionAttention(src, None, bootstrap_concepts=["warm", "settled"], top_k=2)
    a = ia.select_intention_context("hugo", "seek warmth", active_appraisal_ids=[])
    b = ia.select_intention_context("hugo", "seek rest", active_appraisal_ids=[])
    if not a.neuron_ids or not b.neuron_ids:
        failures.append("one or both intention selections empty")
    elif a.neuron_ids[0] == b.neuron_ids[0]:
        failures.append(f"two different goals produced same top pick: {a.neuron_ids} vs {b.neuron_ids}")
    else:
        print(f"  PASS  different goals → different top picks "
              f"({a.neuron_ids[0]} vs {b.neuron_ids[0]})")


def test_empty_goal_returns_empty(failures: list[str]) -> None:
    src = StubSource()
    ia = IntentionAttention(src, None, bootstrap_concepts=["warm"], top_k=3)
    ctx = ia.select_intention_context("hugo", "", active_appraisal_ids=[])
    if ctx.neuron_ids:
        failures.append(f"empty goal should return no context neurons: {ctx.neuron_ids}")
    else:
        print("  PASS  empty goal returns empty context")


def main() -> int:
    failures: list[str] = []
    test_bootstrap_concept_wins_on_aligned_goal(failures)
    test_active_appraisal_competes_with_bootstrap(failures)
    test_negative_cosine_filtered(failures)
    test_topk_cap(failures)
    test_different_goals_differ(failures)
    test_empty_goal_returns_empty(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
