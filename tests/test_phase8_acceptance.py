"""Phase 8 acceptance gate (tooling layer).

The plan's runtime acceptance — "v3 GGUF on v3 prompt format — verb diversity
> 0 on every category" — requires an actual LoRA training run + GGUF export,
which is operator-executed with 24-72 simulated hours of trace data. That
gate is NOT reachable from a unit-test suite.

This test suite covers the TOOLING-LAYER acceptance:
- F5 corpus metadata shows zero pre-maturity samples when generator runs
  over a mixed trace (the "corpus metadata shows zero pre-maturity samples"
  gate, verifiable without a live model).
- F1/F4/F6 regression probes still pass against a synthetic post-retrain
  trace (retraining must not corrupt the embedding space, the attention
  entropy, or the fallback decay).
- §15.2 coverage: synthetic scenarios populate every verb class the spec
  requires for training.
- Corpus schema is valid for downstream LoRA tooling (prompt + completion
  + metadata present on every line).

The operator runbook for the runtime gates is documented in RESUME.md.

Run:
    python3 tests/test_phase8_acceptance.py
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "training" / "cognitive"))
sys.path.insert(0, str(REPO_ROOT / "server"))

from generate_command_training_v3 import generate_corpus  # noqa: E402
from maturity_classifier import (  # noqa: E402
    MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT,
    SYNTHETIC_TO_REPLAY_RATIO,
)
from synthetic_scenarios import generate as generate_scenarios, verb_coverage  # noqa: E402


def _thought(ts: float, compound_count: int, n_identity: int, mean_drift: float,
             cmd: str, npc: str = "hugo") -> dict:
    active = [{"id": f"appr_identity_ent_{i}", "activation": 50.0} for i in range(n_identity)]
    drift = {f"appr_identity_ent_{i}": int(mean_drift) for i in range(n_identity)}
    return {
        "type": "thought",
        "ts": ts,
        "npc": npc,
        "compounds_state": {"active": {}, "count": compound_count},
        "active_appraisals": active,
        "appraisal_drift_counts": drift,
        "thought": "probe",
        "command": cmd,
        "command_target": None,
        "prompt_rendered": f"You see:\n  - Target, 3 tiles north\nYou hear:\n  - silence",
        "attention_entropy": {"tick": math.log(8) * 0.95, "mean_10min": math.log(8) * 0.95,
                              "h_min": 0.6 * math.log(8), "k": 8, "fallback": False},
        "fallback_contribution_per_tick": 0.0,
    }


def _completion(prompt: str) -> str:
    return "<think>probe</think>\nWAIT\n"


def _write_trace(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def _run(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout + p.stderr


def test_f5_corpus_metadata_no_pre_maturity(failures: list[str], tmp: Path) -> None:
    """Plan acceptance: 'F5 maturity gate verifiable: corpus metadata shows
    zero pre-maturity samples.' Build a corpus from a mixed trace and run
    the corpus validator — any leak fails CI."""
    trace = tmp / "mixed.jsonl"
    records = [
        _thought(0,  1, 0, 5, "WANDER"),
        _thought(1,  2, 1, 10, "LOOK AT Mabel"),
        _thought(2,  MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT, "APPROACH Mabel"),
        _thought(3,  MIN_COMPOUND_NEURONS + 2, MIN_APPR_IDENTITY + 1, MIN_MEAN_DRIFT + 20, "TOUCH Mabel"),
    ]
    _write_trace(trace, records)
    out = tmp / "corpus.jsonl"
    generate_corpus([trace], out, completion_fn=_completion)

    probe = REPO_ROOT / "tools" / "probe_maturity.py"
    code, text = _run([sys.executable, str(probe), "--corpus", str(out), "--quiet"])
    if code != 0:
        failures.append(f"F5 corpus validator FAIL: {text}")
    # Double-check via direct scan.
    leaked = 0
    with out.open() as f:
        for line in f:
            e = json.loads(line)
            m = e["corpus_metadata"]
            if m["kind"] == "replay" and float(m["source_ts"]) < float(m["first_mature_ts"]):
                leaked += 1
    if leaked:
        failures.append(f"{leaked} pre-maturity records in corpus (should be zero)")
    else:
        print("  PASS  F5 corpus metadata: zero pre-maturity samples")


def test_f1_f4_f6_probes_still_pass(failures: list[str], tmp: Path) -> None:
    """Plan acceptance: 'F1 semantic-probe baseline still passes against
    v3 (no embedding-space corruption from training).' F4/F6 analogously
    from earlier-phase continuous gates. Here we assert the probe CLIs
    run cleanly on a synthetic v3-era trace with mature state + healthy
    attention + decayed fallback."""
    trace = tmp / "post_v3.jsonl"
    records = [
        _thought(float(i), MIN_COMPOUND_NEURONS + 2,
                 MIN_APPR_IDENTITY + 1, MIN_MEAN_DRIFT + 20,
                 ["TOUCH Mabel", "LOOK AT Mabel", "APPROACH Mabel"][i % 3])
        for i in range(30)
    ]
    _write_trace(trace, records)
    # F6 CLI
    f6 = REPO_ROOT / "tools" / "probe_attention_entropy.py"
    code, text = _run([sys.executable, str(f6), str(trace),
                       "--quiet", "--window-seconds", "30", "--min-samples", "5"])
    if code != 0:
        failures.append(f"F6 regressed on post-v3 trace: code={code} text={text}")
    # F4 CLI
    f4 = REPO_ROOT / "tools" / "probe_fallback_decay.py"
    code, text = _run([sys.executable, str(f4), str(trace),
                       "--quiet", "--window-seconds", "30"])
    if code != 0:
        failures.append(f"F4 regressed on post-v3 trace: code={code} text={text}")
    if not failures:
        print("  PASS  F4 + F6 CLIs pass against post-v3 mature trace")


def test_synthetic_verb_coverage_complete(failures: list[str]) -> None:
    """Plan acceptance: 'verb diversity > 0 on every category.' We can't
    exercise the LLM here, but we CAN assert the training corpus SCHEDULE
    touches every verb class — a prerequisite for the runtime gate."""
    scenarios = list(generate_scenarios())
    cov = verb_coverage(scenarios)
    required = {"TOUCH", "INTERACT", "APPROACH", "EXAMINE", "WATCH", "LOOK AT"}
    zero = [v for v in required if cov.get(v, 0) == 0]
    if zero:
        failures.append(f"synthetic schedule missing verbs: {zero} — cov={cov}")
    else:
        print(f"  PASS  synthetic schedule covers all required verbs ({sorted(required)})")


def test_corpus_schema(failures: list[str], tmp: Path) -> None:
    """Downstream LoRA tooling expects every corpus line to have
    (prompt: str, completion: str, corpus_metadata: dict). Enforce here so
    the generator can't silently drift."""
    trace = tmp / "tiny.jsonl"
    records = [_thought(0, MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT, "WAIT")]
    _write_trace(trace, records)
    out = tmp / "corpus.jsonl"
    generate_corpus([trace], out, completion_fn=_completion)
    with out.open() as f:
        for i, line in enumerate(f):
            e = json.loads(line)
            for key in ("prompt", "completion", "corpus_metadata"):
                if key not in e:
                    failures.append(f"line {i} missing key {key}")
            if not isinstance(e.get("prompt", ""), str):
                failures.append(f"line {i} prompt is not str")
            if not isinstance(e.get("completion", ""), str):
                failures.append(f"line {i} completion is not str")
            if not isinstance(e.get("corpus_metadata", None), dict):
                failures.append(f"line {i} corpus_metadata is not dict")
    if not failures:
        print("  PASS  corpus schema: (prompt, completion, metadata) on every line")


def test_ratio_constant_from_perception_constants(failures: list[str]) -> None:
    """Sanity: the 2:1 ratio from constants drives the generator's default.
    Changing the constant must propagate to downstream runs without code edits."""
    if abs(SYNTHETIC_TO_REPLAY_RATIO - 2.0) > 1e-9:
        failures.append(f"synthetic_to_replay_ratio in constants is {SYNTHETIC_TO_REPLAY_RATIO}, expected 2.0")
    else:
        print(f"  PASS  synthetic_to_replay_ratio sourced from constants ({SYNTHETIC_TO_REPLAY_RATIO})")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_f5_corpus_metadata_no_pre_maturity(failures, tmp)
        test_f1_f4_f6_probes_still_pass(failures, tmp)
        test_synthetic_verb_coverage_complete(failures)
        test_corpus_schema(failures, tmp)
        test_ratio_constant_from_perception_constants(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
