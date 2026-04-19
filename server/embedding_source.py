"""EmbeddingSource — abstract bridge to the LLM's representation space.

Phase 0 of docs/perception_implementation_plan.md, spec §3.4.

The protocol is tier-agnostic so future upgrades (T1 mid-layer extraction,
T2 soft-prompt injection) can replace the implementation without touching
consumers (AppraisalEmbeddingManager, thought_loop cortical feedback, etc.).

T0 implementation (this file): calls llama-server's /embedding endpoint with
--pooling mean, returning unit-normalized last-layer pooled vectors.

Caveats (per spec §3.8):
- Input/last-layer mean-pooled embeddings are lexical-contextual, not deeply
  semantic. "tight" and "tightly" cluster together by surface co-occurrence;
  "tight" and "dangerous" may not.
- Per-being individuation WILL be measurable at T0 (drift trajectories diverge),
  but the *semantic character* of those regions is noisier than at T1.
- The F1 hard gate (tools/probe_embedding_semantics.py) verifies T0 produces
  usable semantic neighborhoods. If F1 fails, Phase 0.5 (T1) is mandatory.
"""

from __future__ import annotations

import logging
import threading
from collections import OrderedDict
from typing import Protocol, runtime_checkable

import numpy as np
import requests

log = logging.getLogger("embedding_source")


@runtime_checkable
class EmbeddingSource(Protocol):
    """Tier-agnostic interface for converting text to vectors in LLM space.

    All implementations return unit-norm vectors of identical dimensionality.
    Consumers may rely on:
        v.shape == (hidden_dim,)
        np.linalg.norm(v) ≈ 1.0
    """

    @property
    def hidden_dim(self) -> int: ...

    def embed(self, text: str) -> np.ndarray: ...

    def embed_batch(self, texts: list[str]) -> np.ndarray: ...


class _LRUCache:
    """Tiny thread-safe LRU. Standalone to avoid an external dependency."""

    def __init__(self, maxsize: int):
        self.maxsize = maxsize
        self._d: OrderedDict[str, np.ndarray] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key: str) -> np.ndarray | None:
        with self._lock:
            v = self._d.get(key)
            if v is not None:
                self._d.move_to_end(key)
            return v

    def put(self, key: str, value: np.ndarray) -> None:
        with self._lock:
            self._d[key] = value
            self._d.move_to_end(key)
            while len(self._d) > self.maxsize:
                self._d.popitem(last=False)


class LlamaServerEmbeddingSource:
    """T0 implementation — llama-server /embedding endpoint with mean pooling.

    Requires the llama-server to have been started with --embedding --pooling mean.
    See server/command_model.py:_start_server().
    """

    def __init__(
        self,
        port: int,
        hidden_dim: int = 2048,
        cache_size: int = 2048,
        timeout: float = 5.0,
        host: str = "127.0.0.1",
    ):
        self._port = port
        self._host = host
        self._url = f"http://{host}:{port}/embedding"
        self._timeout = timeout
        self._hidden_dim = hidden_dim
        self._session = requests.Session()
        self._cache = _LRUCache(maxsize=cache_size)

    @property
    def hidden_dim(self) -> int:
        return self._hidden_dim

    def embed(self, text: str) -> np.ndarray:
        cached = self._cache.get(text)
        if cached is not None:
            return cached

        try:
            r = self._session.post(self._url, json={"content": text}, timeout=self._timeout)
            r.raise_for_status()
            data = r.json()
        except Exception as e:
            log.error("embed(%r) failed: %s", text[:60], e)
            # Return zero vector with correct shape; callers can detect via norm.
            return np.zeros(self._hidden_dim, dtype=np.float32)

        vec = self._extract_vector(data)
        if vec is None or vec.shape != (self._hidden_dim,):
            log.error("embed(%r) malformed response shape", text[:60])
            return np.zeros(self._hidden_dim, dtype=np.float32)

        norm = float(np.linalg.norm(vec))
        if norm < 1e-9:
            return np.zeros(self._hidden_dim, dtype=np.float32)
        vec = (vec / norm).astype(np.float32, copy=False)
        self._cache.put(text, vec)
        return vec

    def embed_batch(self, texts: list[str]) -> np.ndarray:
        # Naive: per-text calls. llama-server's /embedding accepts arrays in
        # newer versions, but the response shape is inconsistent across builds.
        # Per-text is correct everywhere; cache catches duplicates.
        if not texts:
            return np.zeros((0, self._hidden_dim), dtype=np.float32)
        return np.vstack([self.embed(t) for t in texts])

    def _extract_vector(self, data) -> np.ndarray | None:
        # llama-server response shapes vary between versions. Handled cases:
        #   {"embedding": [floats]}
        #   {"embedding": [[floats]]}
        #   [{"embedding": [floats]}]
        #   [{"embedding": [[floats]]}]
        emb = None
        if isinstance(data, list):
            item = data[0] if data else {}
            emb = item.get("embedding") if isinstance(item, dict) else None
        elif isinstance(data, dict):
            emb = data.get("embedding")
        while isinstance(emb, list) and emb and isinstance(emb[0], list):
            emb = emb[0]
        if not emb:
            return None
        return np.asarray(emb, dtype=np.float32)


class TransformersMidLayerEmbeddingSource:
    """T1 implementation — mid-layer residual extraction via transformers.

    F1 hard gate (tools/probe_embedding_semantics.py) demonstrated that T0
    (last-layer mean-pooled via /embedding) clusters on surface co-occurrence,
    not semantics. T1 reads the residual stream at a mid-layer (default 24,
    ~66% deep into SmolLM3-3B's 36 layers), where body/quality concepts
    cluster by emotional-somatic role per appraisal_layer_spec.md.

    The model is loaded lazily on the first embed() call so server startup
    isn't blocked by a 6 GB load. After warmup, each embed() is a single
    forward pass: ~30-100 ms on GPU, 200-600 ms on CPU.

    The decode matrix that pairs with this source must also be at the same
    layer — produced by tools/extract_token_embeddings_t1.py.
    """

    def __init__(
        self,
        model_name: str = "HuggingFaceTB/SmolLM3-3B",
        layer: int = 24,
        device: str | None = None,
        dtype=None,
        cache_size: int = 2048,
    ):
        self._model_name = model_name
        self._layer = layer
        self._cache = _LRUCache(maxsize=cache_size)
        self._lock = threading.Lock()
        self._loaded = False
        self._tokenizer = None
        self._model = None
        self._hidden_dim = 2048  # SmolLM3-3B; verified after load

        # Defer heavy imports until first use — keeps the server import-time light.
        self._device = device
        self._dtype = dtype

    @property
    def hidden_dim(self) -> int:
        return self._hidden_dim

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        with self._lock:
            if self._loaded:
                return
            log.info("TransformersMidLayerEmbeddingSource: loading %s (this may take ~10-30s)...",
                     self._model_name)
            import torch
            from transformers import AutoModelForCausalLM, AutoTokenizer
            self._torch = torch
            if self._device is None:
                self._device = "cuda" if torch.cuda.is_available() else "cpu"
            if self._dtype is None:
                self._dtype = torch.float16 if self._device != "cpu" else torch.float32
            self._tokenizer = AutoTokenizer.from_pretrained(self._model_name)
            self._model = AutoModelForCausalLM.from_pretrained(
                self._model_name, torch_dtype=self._dtype,
                device_map=self._device if self._device != "cpu" else None,
            )
            if self._device == "cpu":
                self._model = self._model.to(self._device)
            self._model.eval()
            cfg = self._model.config
            self._hidden_dim = int(getattr(cfg, "hidden_size", self._hidden_dim))
            n_layers = int(getattr(cfg, "num_hidden_layers", 0))
            if self._layer > n_layers:
                raise ValueError(
                    f"Configured layer {self._layer} exceeds model layer count {n_layers}"
                )
            self._loaded = True
            log.info("TransformersMidLayerEmbeddingSource: ready on %s, layer %d, hidden_dim %d",
                     self._device, self._layer, self._hidden_dim)

    def embed(self, text: str) -> np.ndarray:
        cached = self._cache.get(text)
        if cached is not None:
            return cached
        try:
            self._ensure_loaded()
        except Exception as e:
            log.error("TransformersMidLayerEmbeddingSource: load failed: %s", e)
            return np.zeros(self._hidden_dim, dtype=np.float32)

        torch = self._torch
        try:
            with self._lock, torch.no_grad():
                # Always prepend BOS so single-token inputs match the encoding
                # used by tools/extract_token_embeddings_t1.py — that script
                # uses [BOS, token] and reads position 1. Without this, the
                # matrix and source live in different per-position regions of
                # the layer-24 manifold and cosine becomes meaningless.
                ids = self._tokenizer(text, return_tensors="pt", truncation=True, max_length=256,
                                       add_special_tokens=False)
                tok_ids = ids["input_ids"].to(self._device)
                bos = self._tokenizer.bos_token_id
                if bos is None:
                    bos = self._tokenizer.eos_token_id or 0
                bos_tensor = torch.tensor([[bos]], device=self._device, dtype=tok_ids.dtype)
                input_ids = torch.cat([bos_tensor, tok_ids], dim=1)
                outputs = self._model(input_ids, output_hidden_states=True, use_cache=False)
                layer_resid = outputs.hidden_states[self._layer]  # [1, seq, H]
                # Skip the BOS position; mean-pool the actual content tokens.
                # For single-token inputs, this collapses to position 1, matching
                # the per-token matrix exactly.
                content = layer_resid[:, 1:, :]
                if content.shape[1] == 0:
                    vec = layer_resid[:, 0, :].squeeze(0).float().cpu().numpy()
                else:
                    vec = content.mean(dim=1).squeeze(0).float().cpu().numpy()
        except Exception as e:
            log.error("TransformersMidLayerEmbeddingSource: embed(%r) failed: %s",
                      text[:60], e)
            return np.zeros(self._hidden_dim, dtype=np.float32)

        norm = float(np.linalg.norm(vec))
        if norm < 1e-9:
            return np.zeros(self._hidden_dim, dtype=np.float32)
        vec = (vec / norm).astype(np.float32, copy=False)
        self._cache.put(text, vec)
        return vec

    def embed_batch(self, texts: list[str]) -> np.ndarray:
        if not texts:
            return np.zeros((0, self._hidden_dim), dtype=np.float32)
        return np.vstack([self.embed(t) for t in texts])
