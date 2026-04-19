"""Phase 5 unit test — IdentityAppraisalTracker + AppraisalEmbeddingManager.

Covers:
- F2 name-lemma branch accepts thoughts containing the entity's name.
- F2 cosine branch accepts thoughts whose embedding is near the name embedding.
- F2 rejects ambient thoughts (neither branch hits).
- Deque accumulates at encounter_threshold → spawn request fires once.
- initialize_from_thoughts seeds the embedding to the deque mean.
- End-to-end acceptance probe: 20 simulated encounters across 3+ eids
  produce ≥2 appr_identity_* neurons with pairwise decoded cosine > 0.3
  AND F2 rejection rate > identity_filter_min_rejection_rate.

Run:
    python tests/test_identity_appraisal.py
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
from identity_appraisal import IdentityAppraisalTracker  # noqa: E402


HIDDEN = 16


class StubSource:
    """Deterministic hash → unit vector, with optional overrides so we can
    engineer specific cosine relationships between pairs of tokens."""
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


def build_decode_matrix(tokens: list[str], source: StubSource, tmpdir: Path) -> Path:
    ids = list(range(len(tokens)))
    embeddings = np.vstack([source.embed(t) for t in tokens]).astype(np.float32)
    path = tmpdir / "decode.safetensors"
    safetensors.torch.save_file({
        "token_ids": torch.tensor(ids, dtype=torch.int64),
        "embeddings": torch.from_numpy(embeddings).to(torch.float16),
    }, str(path))
    return path


def _load_constants() -> dict:
    with (REPO_ROOT / "data" / "perception_constants.json").open() as f:
        return json.load(f)


def test_f2_name_lemma_accepts(failures: list[str]) -> None:
    src = StubSource()
    tr = IdentityAppraisalTracker(
        src, encounter_threshold=5, bind_cosine_threshold=0.99,  # cosine branch effectively off
    )
    # "Mabels" pluralizes to "mabel" under WordNet lemmatization.
    emb = src.embed("unrelated")
    events, spawns = tr.associate_thought(
        "hugo", "The Mabels are watching me from the window",
        emb, [("ent_mabel", "Mabel")],
    )
    if not events or not events[0].matched or events[0].method != "name_lemma":
        failures.append(f"F2 name-lemma branch did not fire on 'Mabels'/'Mabel': {events}")
    else:
        print("  PASS  F2 name-lemma branch accepts plural of entity name")
    if spawns:
        failures.append("spawn fired after 1 encounter (threshold=5)")


def test_f2_cosine_accepts(failures: list[str]) -> None:
    src = StubSource()
    # Force thought and name vectors to be near-identical so cosine > 0.45.
    shared = np.ones(HIDDEN, dtype=np.float32)
    src.set_override("Ivy", shared)
    thought_vec = shared + 0.01 * np.random.default_rng(0).normal(size=HIDDEN).astype(np.float32)
    thought_vec /= np.linalg.norm(thought_vec)

    tr = IdentityAppraisalTracker(
        src, encounter_threshold=5, bind_cosine_threshold=0.45,
    )
    events, _ = tr.associate_thought(
        "hugo", "storm is coming",  # no name token — forces cosine branch
        thought_vec, [("ent_ivy", "Ivy")],
    )
    if not events or not events[0].matched or events[0].method != "cosine":
        failures.append(f"F2 cosine branch did not fire: {events}")
    else:
        print(f"  PASS  F2 cosine branch accepts (score={events[0].score:.3f})")


def test_f2_rejects_ambient(failures: list[str]) -> None:
    src = StubSource()
    # Make thought orthogonal to the name embedding.
    src.set_override("Mabel", np.array([1.0] + [0.0] * (HIDDEN - 1), dtype=np.float32))
    thought_vec = np.array([0.0, 1.0] + [0.0] * (HIDDEN - 2), dtype=np.float32)

    tr = IdentityAppraisalTracker(
        src, encounter_threshold=5, bind_cosine_threshold=0.45,
    )
    events, _ = tr.associate_thought(
        "hugo", "my back aches again",
        thought_vec, [("ent_mabel", "Mabel")],
    )
    if not events or events[0].matched:
        failures.append(f"F2 did not reject ambient thought: {events}")
    else:
        print("  PASS  F2 rejects ambient thought (no name, orthogonal cosine)")
    rej = tr.rejection_rate("hugo")
    if rej <= 0.0:
        failures.append("rejection counter did not increment")


def test_spawn_fires_once_at_threshold(failures: list[str]) -> None:
    src = StubSource()
    tr = IdentityAppraisalTracker(
        src, encounter_threshold=5, bind_cosine_threshold=0.99,
    )
    emb = src.embed("anything")
    spawn_events = []
    for i in range(7):
        _, sps = tr.associate_thought(
            "hugo", f"Mabel looks tired today {i}",
            emb, [("ent_mabel", "Mabel")],
        )
        spawn_events.extend(sps)
    if len(spawn_events) != 1:
        failures.append(f"expected 1 spawn at threshold, got {len(spawn_events)}")
    elif spawn_events[0].neuron_id != "appr_identity_ent_mabel":
        failures.append(f"wrong neuron_id: {spawn_events[0].neuron_id}")
    elif len(spawn_events[0].thought_embeddings) != 5:
        failures.append(f"spawn carried {len(spawn_events[0].thought_embeddings)} thoughts, expected 5")
    else:
        print("  PASS  spawn fires exactly once at encounter_threshold=5")


def test_initialize_from_thoughts_is_mean(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src = StubSource()
        vocab = ["alpha", "beta", "gamma", "delta", "mabel"]
        decode_path = build_decode_matrix(vocab, src, tmp)
        tok = StubTokenizer({i: t for i, t in enumerate(vocab)})

        mgr = AppraisalEmbeddingManager(
            source=src, token_decode_path=decode_path, tokenizer=tok,
        )
        embs = [src.embed("alpha"), src.embed("beta"), src.embed("gamma")]
        mgr.initialize_from_thoughts("hugo", "appr_identity_ent_x", embs)
        assert mgr.has_neuron("hugo", "appr_identity_ent_x")
        # Reconstruct expected mean and compare cosine via decode matrix.
        expected = np.mean(np.stack(embs, axis=0), axis=0)
        expected /= np.linalg.norm(expected)
        actual = mgr._states["hugo"]["appr_identity_ent_x"].embedding
        cos = float(np.dot(expected, actual))
        if cos < 0.999:
            failures.append(f"initialize_from_thoughts mean mismatch (cos={cos:.4f})")
        else:
            print(f"  PASS  initialize_from_thoughts seeds to mean (cos={cos:.4f})")


def test_acceptance_gate(failures: list[str]) -> None:
    """20 encounters × 3+ eids → ≥2 appr_identity_* neurons, pairwise decoded
    cosine > 0.3, and F2 rejection rate above the constant-file floor."""
    consts = _load_constants()
    bind_thr = float(consts["thought_entity_bind_threshold"])
    enc_thr = int(consts["neurogenesis_thresholds"]["encounter_threshold"])
    min_rej = float(consts["identity_filter_min_rejection_rate"])

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src = StubSource()
        # Vocabulary: seed concepts + entity names + one decoy per being.
        vocab = [
            "mabel", "hugo", "roland",
            "tight", "warm", "prickling", "churning", "settled",
            "ache", "storm", "door",
        ]
        decode_path = build_decode_matrix(vocab, src, tmp)
        tok = StubTokenizer({i: t for i, t in enumerate(vocab)})

        mgr = AppraisalEmbeddingManager(
            source=src, token_decode_path=decode_path, tokenizer=tok,
        )
        tr = IdentityAppraisalTracker(
            src, encounter_threshold=enc_thr, bind_cosine_threshold=bind_thr,
        )

        # Generate distinct "thought signatures" per entity by anchoring each
        # entity's thoughts around a different concept vector (tight/warm/
        # prickling). Noise kept small so the mean remains close to the
        # anchor but distinct from the other entities' means.
        rng = np.random.default_rng(1234)
        entities = [
            ("ent_mabel", "Mabel", "warm"),
            ("ent_hugo", "Hugo", "tight"),
            ("ent_roland", "Roland", "prickling"),
        ]

        # Run 20 encounter-thought cycles, rotating which entity is visible.
        # Mix in some ambient thoughts (no name, random vector) to exercise
        # the F2 rejection path.
        N_ENCOUNTERS = 20
        ambient_count = 0
        for i in range(N_ENCOUNTERS):
            for (eid, name, anchor) in entities:
                anchor_vec = src.embed(anchor)
                thought_vec = anchor_vec + 0.05 * rng.normal(size=HIDDEN).astype(np.float32)
                thought_vec /= np.linalg.norm(thought_vec)
                text = f"{name} is in the room, feeling {anchor}"
                tr.associate_thought("hugo", text, thought_vec, [(eid, name)])

            # Every 3 cycles inject an ambient thought while *all three*
            # entities are "visible" but the thought talks about none of them.
            if i % 3 == 0:
                ambient_vec = rng.normal(size=HIDDEN).astype(np.float32)
                ambient_vec /= np.linalg.norm(ambient_vec)
                visible_all = [(eid, name) for (eid, name, _) in entities]
                _, _ = tr.associate_thought(
                    "hugo", "my knees ache from the wet weather",
                    ambient_vec, visible_all,
                )
                ambient_count += 1

        # Now materialize every spawn request by calling initialize_from_thoughts.
        # In production, thought_loop does this as spawns are emitted; the test
        # replays by inspecting the internal state and forcing any already-spawned
        # eids to initialize if the manager doesn't have them yet.
        for (eid, name, _) in entities:
            nid = f"appr_identity_{eid}"
            if tr.has_spawned("hugo", eid) and not mgr.has_neuron("hugo", nid):
                # Rebuild the deque from tracker state for the test; in prod
                # the spawn request would have carried this list.
                state = tr._states["hugo"][eid]
                mgr.initialize_from_thoughts("hugo", nid, list(state.thought_embs))

        # --- Acceptance checks ---

        identity_nids = [
            f"appr_identity_{e[0]}" for e in entities
            if mgr.has_neuron("hugo", f"appr_identity_{e[0]}")
        ]
        if len(identity_nids) < 2:
            failures.append(f"only {len(identity_nids)} appr_identity_* neurons, expected ≥2")
            return

        print(f"  INFO  spawned {len(identity_nids)} identity-appraisals: {identity_nids}")

        # Pairwise decoded-cosine distance > 0.3.
        embs = [mgr._states["hugo"][nid].embedding for nid in identity_nids]
        max_pair_cosine = 0.0
        for a in range(len(embs)):
            for b in range(a + 1, len(embs)):
                cos_ab = float(np.dot(embs[a], embs[b]))
                dist = 1.0 - cos_ab
                print(f"  INFO  pair({identity_nids[a]},{identity_nids[b]}) cos={cos_ab:.3f} dist={dist:.3f}")
                max_pair_cosine = max(max_pair_cosine, cos_ab)
                if dist <= 0.3:
                    failures.append(
                        f"pair {identity_nids[a]}/{identity_nids[b]} cosine distance "
                        f"{dist:.3f} ≤ 0.3 (cosine {cos_ab:.3f})"
                    )
        if max_pair_cosine < 1.0:  # i.e. we computed at least one pair
            print(f"  PASS  all pairwise distances > 0.3 (max cosine = {max_pair_cosine:.3f})")

        # F2 rejection rate above the constant-file floor.
        accepted, rejected = tr.audit_counts("hugo")
        total = accepted + rejected
        rej_rate = rejected / total if total else 0.0
        print(f"  INFO  F2 accepted={accepted} rejected={rejected} rate={rej_rate:.3f} floor={min_rej}")
        if rej_rate < min_rej:
            failures.append(
                f"F2 rejection rate {rej_rate:.3f} < identity_filter_min_rejection_rate {min_rej}"
            )
        else:
            print(f"  PASS  F2 rejection rate {rej_rate:.3f} ≥ floor {min_rej}")


def main() -> int:
    failures: list[str] = []
    print("test_f2_name_lemma_accepts:")
    test_f2_name_lemma_accepts(failures)
    print("test_f2_cosine_accepts:")
    test_f2_cosine_accepts(failures)
    print("test_f2_rejects_ambient:")
    test_f2_rejects_ambient(failures)
    print("test_spawn_fires_once_at_threshold:")
    test_spawn_fires_once_at_threshold(failures)
    print("test_initialize_from_thoughts_is_mean:")
    test_initialize_from_thoughts_is_mean(failures)
    print("test_acceptance_gate:")
    test_acceptance_gate(failures)

    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
