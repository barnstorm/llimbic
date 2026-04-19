"""Phase 8 — v3 training-data generator tests.

Verifies:
- Replay examples are built only from post-maturity records (F5 gate).
- Synthetic scenarios populate the corpus at ≥ synthetic_ratio : 1 vs replay.
- Every corpus line has a `corpus_metadata` block with `kind` set.
- Verb coverage spans every category the §15.2 synthetic generator targets.
- Pre-maturity records from the input trace are NOT in the output corpus
  (corpus is validatable by tools/probe_maturity.py --corpus).

Run:
    python3 tests/test_v3_generator.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "training" / "cognitive"))

from generate_command_training_v3 import generate_corpus  # noqa: E402
from maturity_classifier import MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT  # noqa: E402
from synthetic_scenarios import generate as generate_scenarios, verb_coverage  # noqa: E402


def _thought(ts: float, compound_count: int, n_identity: int, mean_drift: float,
             npc: str = "hugo", command: str = "TOUCH Mabel",
             prompt_rendered: str = "You see:\n  - Mabel, 2 tiles north\nYou hear:\n  - silence",
             ) -> dict:
    active = [{"id": f"appr_identity_ent_{i}", "activation": 50.0} for i in range(n_identity)]
    drift = {f"appr_identity_ent_{i}": int(mean_drift) for i in range(n_identity)}
    return {
        "type": "thought",
        "ts": ts,
        "npc": npc,
        "compounds_state": {"active": {}, "count": compound_count},
        "active_appraisals": active,
        "appraisal_drift_counts": drift,
        "thought": "I should do something",
        "command": command,
        "command_target": None,
        "prompt_rendered": prompt_rendered,
    }


def write_trace(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def read_corpus(path: Path) -> list[dict]:
    out = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def _completion_stub(_prompt: str) -> str:
    return "<think>probe</think>\nWAIT\n"


def test_f5_gate_strips_pre_maturity(failures: list[str], tmp: Path) -> None:
    trace = tmp / "trace.jsonl"
    records = [
        # Pre-maturity — must NOT appear in replay.
        _thought(0,  1, 0, 5, command="WANDER"),
        _thought(1,  2, 1, 10, command="LOOK AT Mabel"),
        # Crossover here.
        _thought(2,  MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT, command="APPROACH Mabel"),
        _thought(3,  MIN_COMPOUND_NEURONS + 1, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT + 10, command="TOUCH Mabel"),
    ]
    write_trace(trace, records)
    out = tmp / "corpus.jsonl"
    summary = generate_corpus([trace], out, completion_fn=_completion_stub)
    corpus = read_corpus(out)
    # Every replay example must show source_ts >= first_mature_ts = 2.
    replay = [e for e in corpus if e["corpus_metadata"]["kind"] == "replay"]
    for e in replay:
        ts = float(e["corpus_metadata"]["source_ts"])
        fm = float(e["corpus_metadata"]["first_mature_ts"])
        if ts < fm:
            failures.append(f"pre-maturity leak: source_ts={ts} fm={fm} meta={e['corpus_metadata']}")
    # Expected exactly 2 replay examples (ts=2 and ts=3).
    if len(replay) != 2:
        failures.append(f"expected 2 replay examples, got {len(replay)}")
    else:
        print(f"  PASS  F5 gate: replay=2, pre-maturity records excluded")


def test_synthetic_ratio(failures: list[str], tmp: Path) -> None:
    trace = tmp / "trace.jsonl"
    # 3 mature records.
    records = [
        _thought(float(i), MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT)
        for i in range(3)
    ]
    write_trace(trace, records)
    out = tmp / "corpus.jsonl"
    summary = generate_corpus([trace], out,
                              completion_fn=_completion_stub,
                              synthetic_ratio=2.0)
    if summary["replay"] == 0 or summary["synthetic"] == 0:
        failures.append(f"one side empty: replay={summary['replay']} synth={summary['synthetic']}")
    elif summary["synthetic"] / summary["replay"] < 2.0 - 1e-9:
        failures.append(f"synthetic ratio < 2.0: {summary['synthetic'] / summary['replay']}")
    else:
        print(f"  PASS  synthetic ratio = {summary['synthetic'] / summary['replay']:.2f} (target 2.0)")


def test_every_line_has_metadata(failures: list[str], tmp: Path) -> None:
    trace = tmp / "trace.jsonl"
    records = [_thought(float(i), MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT)
               for i in range(2)]
    write_trace(trace, records)
    out = tmp / "corpus.jsonl"
    generate_corpus([trace], out, completion_fn=_completion_stub)
    corpus = read_corpus(out)
    for e in corpus:
        if "corpus_metadata" not in e:
            failures.append(f"missing corpus_metadata: {e}")
        elif "kind" not in e["corpus_metadata"]:
            failures.append(f"missing kind: {e}")
    if not failures:
        print(f"  PASS  every example carries corpus_metadata.kind")


def test_synthetic_verb_coverage(failures: list[str]) -> None:
    """§15.2 verb-coverage audit: synthetic scenarios alone must touch every
    verb class the generator maps to (TOUCH, INTERACT, APPROACH, EXAMINE,
    WATCH, LOOK AT). Missing any means the parameter space doesn't cover it."""
    scenarios = list(generate_scenarios())
    cov = verb_coverage(scenarios)
    required = {"TOUCH", "INTERACT", "APPROACH", "EXAMINE", "WATCH", "LOOK AT"}
    missing = required - set(cov.keys())
    if missing:
        failures.append(f"synthetic verbs missing: {missing} — coverage={cov}")
    elif any(v == 0 for v in cov.values()):
        failures.append(f"synthetic verb with zero count: {cov}")
    else:
        print(f"  PASS  synthetic verb coverage: {cov}")


def test_corpus_probe_clean(failures: list[str], tmp: Path) -> None:
    """End-to-end: generator's corpus passes probe_maturity --corpus validation."""
    trace = tmp / "trace.jsonl"
    records = [_thought(float(i), MIN_COMPOUND_NEURONS, MIN_APPR_IDENTITY, MIN_MEAN_DRIFT)
               for i in range(3)]
    write_trace(trace, records)
    out = tmp / "corpus.jsonl"
    generate_corpus([trace], out, completion_fn=_completion_stub)
    probe = REPO_ROOT / "tools" / "probe_maturity.py"
    proc = subprocess.run(
        [sys.executable, str(probe), "--corpus", str(out), "--quiet"],
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        failures.append(f"probe_maturity --corpus failed on generator output: {proc.stdout}{proc.stderr}")
    else:
        print("  PASS  generator output passes probe_maturity --corpus clean")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_f5_gate_strips_pre_maturity(failures, tmp)
        test_synthetic_ratio(failures, tmp)
        test_every_line_has_metadata(failures, tmp)
        test_synthetic_verb_coverage(failures)
        test_corpus_probe_clean(failures, tmp)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
