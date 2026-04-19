"""IdentityAppraisalTracker — Phase 5 per-entity thought-encounter accumulator.

Responsibilities (docs/perception_implementation_plan.md §Phase 5):
- Per-NPC, per-entity_id deque of thought embeddings accumulated during
  visible encounters ("thought_embeddings_during_encounters" in the spec).
- F2 thought-entity association filter — mandatory name-token-lemma match OR
  cosine(thought_embedding, entity_name_embedding) > thought_entity_bind_threshold.
- Spawn detection: once a deque reaches `encounter_threshold` and no
  appr_identity_{entity_id} has been spawned yet, surface a spawn request.
- F2 audit trail for trace v2: which thoughts bound to which entities and
  how (name-lemma, cosine, or rejected).

The tracker owns no embeddings or Hebbian state itself. It:
- takes thought embeddings from the cortical-feedback path,
- consults an EmbeddingSource when cosine-branch matching is needed,
- returns a list of spawn requests the caller hands to AppraisalEmbeddingManager
  (for the embedding state) and to the GDScript client (for Hebbian wiring).
"""

from __future__ import annotations

import logging
import re
import threading
from collections import deque
from dataclasses import dataclass, field
from typing import Iterable

import numpy as np

from embedding_source import EmbeddingSource

log = logging.getLogger("identity_appraisal")


# Lemmatizer is lazy — NLTK + WordNet corpus are only pulled in the first
# time F2 name-matching fires. Server startup stays fast even when the
# corpus needs downloading (which happens once, out-of-band).
_LEMMATIZER = None
_LEMMATIZER_LOCK = threading.Lock()


def _get_lemmatizer():
    global _LEMMATIZER
    if _LEMMATIZER is not None:
        return _LEMMATIZER
    with _LEMMATIZER_LOCK:
        if _LEMMATIZER is not None:
            return _LEMMATIZER
        try:
            import nltk
            from nltk.stem import WordNetLemmatizer
            try:
                _LEMMATIZER = WordNetLemmatizer()
                # Trigger corpus load; download silently if absent.
                _LEMMATIZER.lemmatize("test")
            except LookupError:
                nltk.download("wordnet", quiet=True)
                nltk.download("omw-1.4", quiet=True)
                _LEMMATIZER = WordNetLemmatizer()
                _LEMMATIZER.lemmatize("test")
        except Exception as e:
            log.warning("lemmatizer unavailable (%s); F2 name match falls back to lowercase-equality", e)
            _LEMMATIZER = False  # sentinel: use identity
    return _LEMMATIZER


_WORD_RE = re.compile(r"[A-Za-z][A-Za-z]+")


def _tokens(text: str) -> list[str]:
    """Lowercase alphabetic tokens, ≥2 chars. Strips punctuation and possessives
    (`Mabel's` → `mabel`, since the trailing `s` is length-1 and filtered)."""
    return _WORD_RE.findall(text.lower())


def _lemmas(text: str) -> set[str]:
    """Token set with WordNet noun lemmas PLUS a suffix-strip fallback for
    proper-noun plurals that WordNet doesn't know ("Mabels" → "mabel").

    Falls back to raw tokens only if the lemmatizer can't initialize at all
    (e.g. offline with no corpus). Returns a set that is the union of:
      - the lemma of each token (WordNet noun POS), and
      - each token with a trailing `s`/`es` stripped (min 3 chars after strip),
        so plurals of names and other proper nouns still match.
    """
    toks = _tokens(text)
    lem = _get_lemmatizer()
    out: set[str] = set()
    for t in toks:
        if lem:
            out.add(lem.lemmatize(t, pos="n"))
        else:
            out.add(t)
        # Defensive plural strip for tokens the lemmatizer didn't shorten
        # (proper nouns, out-of-vocab words). Only strip when the remainder
        # is still recognizably a word (≥3 chars).
        if len(t) >= 5 and t.endswith("es"):
            out.add(t[:-2])
        if len(t) >= 4 and t.endswith("s") and not t.endswith("ss"):
            out.add(t[:-1])
    return out


@dataclass
class _EntityState:
    """Per-entity state for one NPC. The deque holds thought embeddings that
    passed F2 during encounters. Once the deque reaches encounter_threshold AND
    no identity-appraisal has been spawned for this eid, the next ingest
    emits a spawn request and `spawned` flips to True (preventing re-spawn).
    """
    eid: str
    name: str
    name_lemmas: frozenset[str]
    name_embedding: np.ndarray | None = None  # lazily computed
    thought_embs: deque = field(default_factory=lambda: deque(maxlen=16))
    spawned: bool = False


@dataclass
class AssociationEvent:
    """One F2 decision, emitted for trace audit."""
    eid: str
    name: str
    matched: bool
    method: str  # "name_lemma" | "cosine" | "rejected"
    score: float  # cosine score (always computed when possible)


@dataclass
class SpawnRequest:
    """A per-NPC spawn request produced when an entity's deque first fills.
    The caller uses `thought_embeddings` to seed the embedding manager and
    `neuron_id`/`entity_id` to push the Hebbian spawn command to the client.
    """
    neuron_id: str
    entity_id: str
    entity_name: str
    thought_embeddings: list[np.ndarray]


class IdentityAppraisalTracker:
    """Per-NPC per-entity thought accumulator + F2 filter + spawn detection.

    Thread-safe for the case where snapshot ingest and thought-loop ingest
    race on the same NPC (they don't today, but cheap insurance). All state
    is partitioned by NPC then entity_id so there is zero cross-NPC coupling.
    """

    def __init__(
        self,
        source: EmbeddingSource,
        *,
        encounter_threshold: int,
        bind_cosine_threshold: float,
        deque_maxlen: int | None = None,
    ):
        self._source = source
        self._threshold = int(encounter_threshold)
        self._bind_cos = float(bind_cosine_threshold)
        # Deque bound: default to encounter_threshold. Until the spawn fires
        # we only need N vectors; after spawn the deque is dormant. Holding
        # a few extra allows re-spawn after an F9 merge deletes the neuron,
        # but that's a Phase 5+ concern; the bound is defensive, not tuning.
        self._deque_maxlen = int(deque_maxlen if deque_maxlen is not None else encounter_threshold)
        self._lock = threading.Lock()
        self._states: dict[str, dict[str, _EntityState]] = {}
        # F2 audit counters per NPC: (accepted, rejected). Persisted across
        # ticks; a caller can read the rolling rejection rate.
        self._audit: dict[str, list[int]] = {}

    # --- F2 ingest ------------------------------------------------------------

    def associate_thought(
        self,
        npc: str,
        thought_text: str,
        thought_emb: np.ndarray,
        visible_entities: Iterable[tuple[str, str]],
    ) -> tuple[list[AssociationEvent], list[SpawnRequest]]:
        """For every visible (eid, name) pair, run F2 and (if accepted) append
        the thought embedding to that entity's deque. Return per-entity audit
        events and any spawn requests triggered this call.

        visible_entities: iterable of (entity_id, display_name) pairs that were
            visible when `thought_text` was generated.
        """
        events: list[AssociationEvent] = []
        spawns: list[SpawnRequest] = []
        if thought_emb is None or thought_emb.size == 0:
            return events, spawns
        thought_lemmas = _lemmas(thought_text)

        with self._lock:
            npc_states = self._states.setdefault(npc, {})
            self._audit.setdefault(npc, [0, 0])

            for eid, name in visible_entities:
                if not eid or not name:
                    continue
                st = npc_states.get(eid)
                if st is None:
                    st = _EntityState(
                        eid=eid,
                        name=name,
                        name_lemmas=frozenset(_lemmas(name)),
                        thought_embs=deque(maxlen=self._deque_maxlen),
                    )
                    npc_states[eid] = st

                # (a) name-lemma branch
                name_hit = bool(st.name_lemmas & thought_lemmas)

                # (b) cosine branch (only if name didn't already match)
                score = 0.0
                if not name_hit:
                    if st.name_embedding is None:
                        try:
                            st.name_embedding = self._source.embed(name)
                        except Exception as e:
                            log.warning("embed(name=%s) failed for %s: %s", name, npc, e)
                            st.name_embedding = np.zeros(self._source.hidden_dim, dtype=np.float32)
                    denom = (np.linalg.norm(thought_emb) * np.linalg.norm(st.name_embedding))
                    if denom > 1e-9:
                        score = float(np.dot(thought_emb, st.name_embedding) / denom)
                cos_hit = (not name_hit) and (score > self._bind_cos)

                matched = name_hit or cos_hit
                method = "name_lemma" if name_hit else ("cosine" if cos_hit else "rejected")
                events.append(AssociationEvent(
                    eid=eid, name=name, matched=matched, method=method, score=score,
                ))
                if matched:
                    st.thought_embs.append(np.asarray(thought_emb, dtype=np.float32).copy())
                    self._audit[npc][0] += 1
                else:
                    self._audit[npc][1] += 1

                # Spawn detection: first time the deque reaches threshold AND
                # no identity-appraisal has been spawned yet for this eid.
                if not st.spawned and len(st.thought_embs) >= self._threshold:
                    st.spawned = True
                    spawns.append(SpawnRequest(
                        neuron_id=f"appr_identity_{eid}",
                        entity_id=eid,
                        entity_name=name,
                        thought_embeddings=[e.copy() for e in st.thought_embs],
                    ))

        return events, spawns

    # --- Maintenance ---------------------------------------------------------

    def rejection_rate(self, npc: str) -> float:
        """Lifetime rejection rate since process start. F2 audit uses this to
        verify the filter is doing work (>= identity_filter_min_rejection_rate)."""
        with self._lock:
            a = self._audit.get(npc, [0, 0])
            total = a[0] + a[1]
            return 0.0 if total == 0 else a[1] / total

    def audit_counts(self, npc: str) -> tuple[int, int]:
        with self._lock:
            a = self._audit.get(npc, [0, 0])
            return int(a[0]), int(a[1])

    def has_spawned(self, npc: str, eid: str) -> bool:
        with self._lock:
            st = self._states.get(npc, {}).get(eid)
            return bool(st and st.spawned)

    def forget_npc(self, npc: str) -> None:
        with self._lock:
            self._states.pop(npc, None)
            self._audit.pop(npc, None)

    def merge_entity_ids(self, npc: str, canonical_id: str, deprecated_id: str) -> bool:
        """F9: when stranger→named binding fires, carry the deprecated eid's
        state onto the canonical one. The deques combine (order-preserved up
        to maxlen), spawn flag OR's, name/name_embedding prefer canonical."""
        with self._lock:
            npc_states = self._states.get(npc, {})
            dep = npc_states.pop(deprecated_id, None)
            if dep is None:
                return False
            can = npc_states.get(canonical_id)
            if can is None:
                dep.eid = canonical_id
                npc_states[canonical_id] = dep
                return True
            for emb in dep.thought_embs:
                can.thought_embs.append(emb)
            can.spawned = can.spawned or dep.spawned
            return True
