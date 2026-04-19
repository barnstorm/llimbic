"""Phase 13 capstone metrics (§9 of perception_spec.md).

The twelve acceptance metrics the capstone's green/red verdict depends on.
Each function consumes a minimal artifact set (trace jsonl, saves/
appraisals.json, graph_summary.json) and returns a `MetricResult` with
the measured value plus a pass/fail verdict against the spec threshold.

Design:
- Pure compute; no I/O side effects beyond file reads.
- Every threshold is sourced from the plan / spec — NO new authored
  numbers. Where a threshold is implicit in spec language (e.g. "strictly
  greater") that's captured literally.
- Tests in `tests/test_capstone_metrics.py` feed synthetic inputs and
  verify each metric computes correctly + gates correctly.
"""

from __future__ import annotations

import json
import math
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import numpy as np


# =============================================================================
# Common loading helpers
# =============================================================================


def iter_thought_records(path: Path):
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "thought":
                continue
            yield rec


def load_appraisal_embeddings(saves_npc_dir: Path) -> dict[str, np.ndarray]:
    """Unit-normalized appraisal embeddings from saves/{npc}/appraisals.json."""
    path = saves_npc_dir / "appraisals.json"
    if not path.exists():
        return {}
    with path.open() as f:
        data = json.load(f)
    out: dict[str, np.ndarray] = {}
    for nid, body in (data.get("neurons") or {}).items():
        emb = body.get("embedding")
        if not emb:
            continue
        v = np.asarray(emb, dtype=np.float32)
        n = np.linalg.norm(v)
        if n >= 1e-9:
            out[str(nid)] = (v / n)
    return out


def load_graph_summary(saves_npc_dir: Path) -> dict:
    """Phase 13 graph_summary.json (written at end-of-run via layer1.dump_graph_summary)."""
    path = saves_npc_dir / "graph_summary.json"
    if not path.exists():
        return {}
    with path.open() as f:
        return json.load(f)


# =============================================================================
# Result type
# =============================================================================


@dataclass
class MetricResult:
    name: str
    passed: bool
    value: float | None = None
    detail: dict = field(default_factory=dict)
    threshold: str = ""

    @property
    def verdict(self) -> str:
        return "PASS" if self.passed else "FAIL"


# =============================================================================
# Metric 1 — §9.2.7 identity-decoded-token overlap < 60%
# =============================================================================


def _trace_identity_decoded_tokens(trace_path: Path) -> dict[str, set[str]]:
    """{eid: union of decoded tokens across all ticks} for identity-appraisals."""
    out: dict[str, set[str]] = {}
    for rec in iter_thought_records(trace_path):
        tokens_by_eid = rec.get("identity_appraisal_decoded") or {}
        for eid, tokens in tokens_by_eid.items():
            out.setdefault(str(eid), set()).update(str(t) for t in (tokens or []))
    return out


def identity_decoded_overlap(trace_a: Path, trace_b: Path) -> MetricResult:
    """Jaccard overlap of decoded-token sets for entities that BOTH beings
    developed identity-appraisals for. Threshold: mean overlap < 0.60."""
    a = _trace_identity_decoded_tokens(trace_a)
    b = _trace_identity_decoded_tokens(trace_b)
    shared = sorted(set(a.keys()) & set(b.keys()))
    if not shared:
        return MetricResult(
            name="identity_decoded_overlap",
            passed=False,
            value=None,
            detail={"reason": "no shared identity-appraisal eids"},
            threshold="< 0.60",
        )
    jaccards: list[float] = []
    for eid in shared:
        union = a[eid] | b[eid]
        if not union:
            continue
        inter = a[eid] & b[eid]
        jaccards.append(len(inter) / len(union))
    mean_overlap = float(np.mean(jaccards)) if jaccards else 0.0
    return MetricResult(
        name="identity_decoded_overlap",
        passed=mean_overlap < 0.60,
        value=mean_overlap,
        detail={"shared_eids": shared, "per_eid_jaccard": jaccards},
        threshold="< 0.60",
    )


# =============================================================================
# Metric 2 — §9.2.7 sensory-propagation cosine distance > 0.2
# =============================================================================


def sensory_propagation_distance(graph_a: dict, graph_b: dict) -> MetricResult:
    """Cosine distance between the two beings' sensory outgoing-weight
    profiles: vector of per-sense out_abs_sum, aligned by neuron ID with
    zero-padding for unmatched IDs. Distance > 0.2 confirms divergent
    attention landscapes."""
    neurons_a = (graph_a or {}).get("neurons") or {}
    neurons_b = (graph_b or {}).get("neurons") or {}
    sense_ids = sorted({
        nid for nid, body in {**neurons_a, **neurons_b}.items()
        if any(nid.startswith(p) for p in ("sense_visible_", "sense_heard_", "sense_dist_"))
    })
    if not sense_ids:
        return MetricResult(
            name="sensory_propagation_distance",
            passed=False,
            value=None,
            detail={"reason": "no sense neurons in either graph"},
            threshold="> 0.20",
        )
    a_vec = np.array([float((neurons_a.get(nid) or {}).get("out_abs_sum", 0.0)) for nid in sense_ids])
    b_vec = np.array([float((neurons_b.get(nid) or {}).get("out_abs_sum", 0.0)) for nid in sense_ids])
    na = np.linalg.norm(a_vec); nb = np.linalg.norm(b_vec)
    if na < 1e-9 or nb < 1e-9:
        return MetricResult(
            name="sensory_propagation_distance",
            passed=False, value=None,
            detail={"reason": "one or both sensory vectors are zero"},
            threshold="> 0.20",
        )
    cos = float(np.dot(a_vec, b_vec) / (na * nb))
    dist = 1.0 - cos
    return MetricResult(
        name="sensory_propagation_distance",
        passed=dist > 0.20,
        value=dist,
        detail={"cosine": cos, "sense_neurons_considered": len(sense_ids)},
        threshold="> 0.20",
    )


# =============================================================================
# Metric 3 — §9.2.7 behavioral verb-distribution KL > 0.4
# =============================================================================


def _verb_dist(trace_path: Path, npc_filter: str | None = None) -> dict[str, float]:
    counts: Counter = Counter()
    for rec in iter_thought_records(trace_path):
        if npc_filter and str(rec.get("npc")) != npc_filter:
            continue
        cmd = str(rec.get("command", "")).strip()
        if cmd:
            counts[cmd.split()[0]] += 1
    total = sum(counts.values())
    if total == 0:
        return {}
    return {k: v / total for k, v in counts.items()}


def _jensen_shannon(p: dict[str, float], q: dict[str, float]) -> float:
    keys = set(p) | set(q)
    if not keys:
        return 0.0
    eps = 1e-9
    p_arr = np.array([p.get(k, 0.0) + eps for k in keys]); p_arr = p_arr / p_arr.sum()
    q_arr = np.array([q.get(k, 0.0) + eps for k in keys]); q_arr = q_arr / q_arr.sum()
    m = 0.5 * (p_arr + q_arr)
    kl_pm = float(np.sum(p_arr * np.log(p_arr / m)))
    kl_qm = float(np.sum(q_arr * np.log(q_arr / m)))
    return 0.5 * (kl_pm + kl_qm)


def verb_distribution_divergence(trace_a: Path, trace_b: Path) -> MetricResult:
    """Spec §9.2.7: KL-class divergence > 0.4 between being A and being B's
    verb distributions. We use symmetric Jensen-Shannon (spec language is
    "KL" but direction-agnostic comparison is the intent)."""
    da = _verb_dist(trace_a)
    db = _verb_dist(trace_b)
    js = _jensen_shannon(da, db)
    return MetricResult(
        name="verb_distribution_divergence",
        passed=js > 0.40,
        value=js,
        detail={"a_verb_count": len(da), "b_verb_count": len(db)},
        threshold="> 0.40 (Jensen-Shannon)",
    )


# =============================================================================
# Metric 4 — §9.3.8 seed-randomization convergence within 10%
# =============================================================================


def seed_convergence(probe_trace: Path, standard_trace: Path) -> MetricResult:
    """Two beings with the SAME environment but scrambled bootstrap seeds
    should converge to verb distributions within 10% of a 'standard' run.
    10% interpreted as JS < 0.10."""
    da = _verb_dist(probe_trace)
    db = _verb_dist(standard_trace)
    js = _jensen_shannon(da, db)
    return MetricResult(
        name="seed_convergence",
        passed=js < 0.10,
        value=js,
        detail={"probe_verbs": len(da), "standard_verbs": len(db)},
        threshold="< 0.10 (Jensen-Shannon)",
    )


# =============================================================================
# Metric 5 — §9.3.9 persona-prior falsification washout
# =============================================================================


def _read_persona_drive_defaults(persona_path: Path) -> dict[str, float]:
    """Load `drive_defaults` from a persona JSON if present."""
    if not persona_path.exists():
        return {}
    with persona_path.open() as f:
        data = json.load(f)
    return {k: float(v) for k, v in (data.get("drive_defaults") or {}).items()}


def persona_prior_washout(trace_path: Path, persona_path: Path,
                          min_encounters: int = 30) -> MetricResult:
    """Persona drive_defaults bias the being initially; with experience
    (≥ min_encounters thought cycles), drive trajectories should diverge
    from the defaults — that's the washout. Metric: mean Euclidean drift
    of drive vector from the persona prior computed across the 'late'
    segment (records after min_encounters) must exceed the 'early' segment
    (first min_encounters).

    A being whose drives stay pinned at persona_defaults across all ticks
    has not been individuated by experience — persona prior never falsified.
    """
    prior = _read_persona_drive_defaults(persona_path)
    if not prior:
        return MetricResult(
            name="persona_prior_washout",
            passed=False, value=None,
            detail={"reason": "persona has no drive_defaults"},
            threshold="late_drift > early_drift",
        )
    early_drifts: list[float] = []
    late_drifts: list[float] = []
    for i, rec in enumerate(iter_thought_records(trace_path)):
        drives = rec.get("drives") or {}
        drift = 0.0
        counted = 0
        for k, v in prior.items():
            if k in drives:
                drift += (float(drives[k]) - v) ** 2
                counted += 1
        if counted == 0:
            continue
        drift = math.sqrt(drift / counted)
        (early_drifts if i < min_encounters else late_drifts).append(drift)
    if not early_drifts or not late_drifts:
        return MetricResult(
            name="persona_prior_washout",
            passed=False, value=None,
            detail={"reason": "insufficient samples",
                    "early": len(early_drifts), "late": len(late_drifts)},
            threshold=f"late_drift > early_drift after {min_encounters} encounters",
        )
    mean_early = float(np.mean(early_drifts))
    mean_late = float(np.mean(late_drifts))
    return MetricResult(
        name="persona_prior_washout",
        passed=mean_late > mean_early,
        value=mean_late - mean_early,
        detail={"mean_early_drift": mean_early, "mean_late_drift": mean_late,
                "min_encounters": min_encounters},
        threshold="late_drift > early_drift",
    )


# =============================================================================
# Metric 6 — §9.3.10 ±20% seed perturbation steady-state delta < 5%
# =============================================================================


def perturbation_steady_state(trace_baseline: Path, trace_up: Path,
                              trace_down: Path) -> MetricResult:
    """Three runs — baseline, +20% perturbation, -20% perturbation —
    steady-state verb distributions must be within 5% of each other (JS
    < 0.05 pairwise). If perturbation shifts behavior more than that,
    the substrate is sensitive to seed values beyond spec tolerance."""
    b = _verb_dist(trace_baseline)
    u = _verb_dist(trace_up)
    d = _verb_dist(trace_down)
    js_bu = _jensen_shannon(b, u)
    js_bd = _jensen_shannon(b, d)
    js_ud = _jensen_shannon(u, d)
    worst = max(js_bu, js_bd, js_ud)
    return MetricResult(
        name="perturbation_steady_state",
        passed=worst < 0.05,
        value=worst,
        detail={"baseline_vs_up": js_bu, "baseline_vs_down": js_bd,
                "up_vs_down": js_ud},
        threshold="< 0.05 (worst pairwise JS)",
    )


# =============================================================================
# Metric 7 — §9.4.11 top-1-verb divergence on 50-scene probe ≥ 60%
# =============================================================================


def scene_top_verb_divergence(scene_responses_a: list[tuple[str, str]],
                              scene_responses_b: list[tuple[str, str]]) -> MetricResult:
    """Given (scene_id, top_verb) per being, compute the fraction of scenes
    where the two beings chose different top verbs. ≥ 60% divergence means
    the probe library discriminates the beings' learned affordances."""
    a = {sid: v for sid, v in scene_responses_a}
    b = {sid: v for sid, v in scene_responses_b}
    shared = sorted(set(a) & set(b))
    if len(shared) < 10:
        return MetricResult(
            name="scene_top_verb_divergence",
            passed=False, value=None,
            detail={"reason": "fewer than 10 shared scenes",
                    "count": len(shared)},
            threshold="≥ 0.60 divergence over ≥ 10 scenes",
        )
    diffs = sum(1 for sid in shared if a[sid] != b[sid])
    rate = diffs / len(shared)
    return MetricResult(
        name="scene_top_verb_divergence",
        passed=rate >= 0.60,
        value=rate,
        detail={"scenes_considered": len(shared), "diverging_scenes": diffs},
        threshold="≥ 0.60",
    )


# =============================================================================
# Metric 8 — §9.4.12 t=1-week individuation > t=0 individuation
# =============================================================================


def individuation_growth(trace_a: Path, trace_b: Path,
                          split_point_seconds: float) -> MetricResult:
    """Split each trace into "early" (before split_point) and "late" (after).
    Individuation = JS divergence between A's and B's verb distributions.
    At t=1-week, late-individuation must exceed early-individuation."""
    def split(path: Path) -> tuple[dict[str, float], dict[str, float]]:
        early: Counter = Counter(); late: Counter = Counter()
        for rec in iter_thought_records(path):
            ts = float(rec.get("ts", 0.0))
            cmd = str(rec.get("command", "")).strip()
            if not cmd:
                continue
            verb = cmd.split()[0]
            (early if ts < split_point_seconds else late)[verb] += 1
        def norm(c: Counter) -> dict[str, float]:
            t = sum(c.values())
            return {k: v / t for k, v in c.items()} if t else {}
        return norm(early), norm(late)

    a_early, a_late = split(trace_a)
    b_early, b_late = split(trace_b)
    early_div = _jensen_shannon(a_early, b_early)
    late_div = _jensen_shannon(a_late, b_late)
    return MetricResult(
        name="individuation_growth",
        passed=late_div > early_div,
        value=(late_div - early_div),
        detail={"early_divergence": early_div, "late_divergence": late_div,
                "split_point_seconds": split_point_seconds},
        threshold="late > early (strictly)",
    )


# =============================================================================
# Metric 9 — §9.4.13 dynamic-neuron count > protected-neuron count at t=1wk
# =============================================================================


def dynamic_vs_protected(graph_summary: dict) -> MetricResult:
    dyn = int(graph_summary.get("dynamic_count", 0))
    pro = int(graph_summary.get("protected_count", 0))
    return MetricResult(
        name="dynamic_vs_protected",
        passed=dyn > pro,
        value=float(dyn - pro),
        detail={"dynamic": dyn, "protected": pro},
        threshold="dynamic > protected (strictly)",
    )


# =============================================================================
# Metric 10 — §9.4.14 per-entity identity-appraisal silhouette > 0.3
# =============================================================================


def identity_appraisal_silhouette(embs_a: dict[str, np.ndarray],
                                  embs_b: dict[str, np.ndarray]) -> MetricResult:
    """Mean cosine distance across shared identity-appraisals' embeddings.
    > 0.3 confirms the beings have individuated their representations of
    shared entities (Phase 5's §5.2 core promise, measured at capstone)."""
    shared = sorted(set(embs_a) & set(embs_b))
    shared = [nid for nid in shared if nid.startswith("appr_identity_")]
    if not shared:
        return MetricResult(
            name="identity_appraisal_silhouette",
            passed=False, value=None,
            detail={"reason": "no shared identity-appraisal IDs"},
            threshold="> 0.30 (mean cosine distance)",
        )
    dists = [1.0 - float(np.dot(embs_a[nid], embs_b[nid])) for nid in shared]
    mean = float(np.mean(dists))
    return MetricResult(
        name="identity_appraisal_silhouette",
        passed=mean > 0.30,
        value=mean,
        detail={"shared_count": len(shared), "per_id_distance": dists},
        threshold="> 0.30",
    )


# =============================================================================
# Metric 11 — F1 semantic probe still passes
# =============================================================================


def f1_semantic_probe_status(probe_output: str | None) -> MetricResult:
    """Wraps the output of `tools/probe_embedding_semantics.py`. Caller
    invokes the probe; we parse its pass_rate and compare to the
    semantic_probe_min_pass_rate from constants. `probe_output` is the
    textual output; None if the probe wasn't run."""
    if probe_output is None:
        return MetricResult(
            name="f1_semantic_probe",
            passed=False, value=None,
            detail={"reason": "F1 CLI not invoked"},
            threshold="≥ semantic_probe_min_pass_rate",
        )
    # The probe prints a line like "pass_rate=0.931" at the end.
    pass_rate = None
    for line in probe_output.splitlines():
        if "pass_rate" in line.lower():
            try:
                pass_rate = float(line.split("=")[-1].split()[0])
            except Exception:
                pass
    # Read threshold from constants.
    repo_root = Path(__file__).resolve().parent.parent
    with (repo_root / "data" / "perception_constants.json").open() as f:
        thr = float(json.load(f).get("semantic_probe_min_pass_rate", 0.7))
    return MetricResult(
        name="f1_semantic_probe",
        passed=(pass_rate is not None and pass_rate >= thr),
        value=pass_rate,
        detail={"threshold": thr, "parsed_pass_rate": pass_rate},
        threshold=f"≥ {thr}",
    )


# =============================================================================
# Metric 12 — F6 attention entropy stability
# =============================================================================


def f6_attention_entropy_ok(trace_path: Path, window_seconds: float = 600.0,
                            min_samples: int = 5) -> MetricResult:
    """Thin wrapper computing the F6 rolling-mean check directly. Avoids
    depending on the F6 CLI subprocess; tests can exercise this in-process."""
    samples: list[tuple[float, float, float]] = []  # (ts, tick, h_min)
    for rec in iter_thought_records(trace_path):
        ae = rec.get("attention_entropy") or {}
        if "tick" not in ae:
            continue
        samples.append((float(rec.get("ts", 0.0)), float(ae.get("tick", 0.0)),
                        float(ae.get("h_min", 0.0))))
    if not samples:
        return MetricResult(
            name="f6_attention_entropy",
            passed=False, value=None,
            detail={"reason": "no attention_entropy samples"},
            threshold="rolling mean ≥ h_min",
        )
    samples.sort(key=lambda s: s[0])
    violations = 0
    worst_gap = 0.0
    left = 0
    running = 0.0
    for i, (ts, tick, _hmin) in enumerate(samples):
        running += tick
        while left <= i and samples[left][0] < ts - window_seconds:
            running -= samples[left][1]
            left += 1
        window_size = i - left + 1
        if window_size < min_samples:
            continue
        rolling_mean = running / window_size
        h_min_at_i = samples[i][2]
        if rolling_mean < h_min_at_i:
            violations += 1
            worst_gap = max(worst_gap, h_min_at_i - rolling_mean)
    return MetricResult(
        name="f6_attention_entropy",
        passed=(violations == 0),
        value=float(violations),
        detail={"violations": violations, "worst_gap_below_h_min": worst_gap,
                "total_samples": len(samples)},
        threshold="zero rolling-mean violations of h_min",
    )
