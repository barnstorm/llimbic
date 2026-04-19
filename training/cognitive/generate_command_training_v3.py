"""Phase 8 — v3 training-data generator.

Per docs/perception_implementation_plan.md Phase 8:

  - Replay Phase 0-7 traces through the new Phase-7 flat-Percept prompt
    renderer (`server/perception.py`).
  - Harvest ONLY post-maturity records (F5 gate).
  - Synthetic scenarios weighted 2:1 vs organic replay (§15.2).
  - Target: 5000+ examples, verb-coverage on every category.
  - Output: jsonl corpus where each line is
        {"prompt": str, "completion": str, "corpus_metadata": {...}}
    with full metadata so `tools/probe_maturity.py --corpus` can verify F5
    compliance and so Phase 12/13 comparison tools can audit provenance.

This module ships the generator. It does NOT execute a large-model inference
pass (that requires an operator-configured endpoint and hours of GPU time).
The completion hook is a pluggable callable — tests inject a stub; the
operator wires in a real large-model client at run time.

Usage (tooling test):
    from generate_command_training_v3 import generate_corpus
    generate_corpus(
        trace_paths=[Path("trace.jsonl")],
        output_path=Path("corpus_v3.jsonl"),
        completion_fn=my_large_model_callable,  # (prompt) -> str
    )

Usage (operator):
    python3 training/cognitive/generate_command_training_v3.py \\
        --trace saves/trace_*.jsonl --out training/cognitive/corpus_v3.jsonl \\
        --synthetic-ratio 2.0 --min-examples 5000
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))
sys.path.insert(0, str(REPO_ROOT / "training" / "cognitive"))

# Phase 7 flat-Percept renderer replays trace records through the new format.
from perception import render as render_perception  # noqa: E402
from maturity_classifier import (  # noqa: E402
    build_timeline, evaluate_record, SYNTHETIC_TO_REPLAY_RATIO,
)
from synthetic_scenarios import generate as generate_scenarios, verb_coverage  # noqa: E402


# Type alias: callable that produces an assistant completion given a prompt.
# Tests inject a stub; operator plugs in an HTTP client for a large model.
CompletionFn = Callable[[str], str]


@dataclass
class CorpusExample:
    prompt: str
    completion: str
    corpus_metadata: dict


def _replay_prompt(record: dict) -> str | None:
    """Return the prompt the model should see for this trace record.

    Preference order:
      1. Use `record["prompt_rendered"]` directly (Phase 7 wrote it into trace).
      2. Fall back to re-rendering from the record fields via the flat renderer
         (useful for traces recorded before the prompt_rendered field existed).
    """
    pre_rendered = record.get("prompt_rendered")
    if pre_rendered:
        return str(pre_rendered)
    # Reconstruction path — a subset of the fields the renderer reads.
    ctx = {
        "visible": record.get("visible") or [],
        "visible_objects": record.get("visible_objects") or [],
        "heard": record.get("heard") or [],
        "identity_appraisal_decoded": record.get("identity_appraisal_decoded") or {},
    }
    text, _ = render_perception(ctx)
    return text


def _replay_completion(record: dict) -> str:
    """The reference completion for a replay record. Uses the trace's own
    thought+command — these are what the mature being actually did. The
    operator may choose to discard this and run the completion_fn to get a
    large-model-generated alternative, but the default preserves the
    substrate's emergent response."""
    thought = (record.get("thought") or "").strip()
    cmd = str(record.get("command") or "WAIT")
    target = record.get("command_target")
    if target and isinstance(target, dict):
        tgt_name = target.get("name") or target.get("target_name") or ""
        if tgt_name:
            return f"<think>{thought}</think>\n{cmd} {tgt_name}\n"
    return f"<think>{thought}</think>\n{cmd}\n"


def iter_replay_examples(trace_path: Path) -> Iterable[dict]:
    """Yield post-maturity thought records, grouped by NPC, annotated with
    `first_mature_ts` so downstream metadata can be emitted."""
    per_npc: dict[str, list[dict]] = defaultdict(list)
    with trace_path.open() as f:
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
            per_npc[str(rec.get("npc", "?"))].append(rec)

    for npc, records in per_npc.items():
        timeline = build_timeline(npc, records)
        if timeline.first_mature_ts is None:
            continue
        fm_ts = float(timeline.first_mature_ts)
        for r in records:
            if float(r.get("ts", 0.0)) < fm_ts:
                continue
            # Double-check the tick itself — latching timelines can permit
            # dips; the plan says "thoughts emitted after maturity crossover",
            # not "thoughts at every mature tick", so only the crossover gate
            # matters.
            yield {"record": r, "first_mature_ts": fm_ts, "npc": npc}


def build_replay_example(entry: dict) -> CorpusExample | None:
    rec = entry["record"]
    prompt = _replay_prompt(rec)
    if prompt is None:
        return None
    completion = _replay_completion(rec)
    return CorpusExample(
        prompt=prompt,
        completion=completion,
        corpus_metadata={
            "kind": "replay",
            "npc": entry["npc"],
            "source_ts": float(rec.get("ts", 0.0)),
            "first_mature_ts": entry["first_mature_ts"],
            "compound_count": int((rec.get("compounds_state") or {}).get("count", 0)),
            "command": rec.get("command", ""),
        },
    )


def build_synthetic_example(scenario, completion_fn: CompletionFn) -> CorpusExample:
    prompt, _ = render_perception(scenario.context)
    completion = completion_fn(prompt)
    return CorpusExample(
        prompt=prompt,
        completion=completion,
        corpus_metadata={
            "kind": "synthetic",
            "scenario_id": scenario.scenario_id,
            "probe_verb": scenario.probe_verb,
            "reward_context": scenario.reward_context,
            "distance_band": scenario.distance_band,
            "target_kind": scenario.target_kind,
            "persona_name": scenario.metadata.get("persona_name"),
        },
    )


def _write_example(fp, example: CorpusExample) -> None:
    fp.write(json.dumps(asdict(example), default=str) + "\n")


def generate_corpus(
    trace_paths: list[Path],
    output_path: Path,
    *,
    completion_fn: CompletionFn | None = None,
    synthetic_ratio: float = SYNTHETIC_TO_REPLAY_RATIO,
    entity_names: list[str] | None = None,
    object_names: list[str] | None = None,
    persona_names: list[str] | None = None,
) -> dict:
    """Produce a v3 training corpus jsonl at `output_path`.

    Returns a summary dict with counts + verb coverage so tests and the
    operator CLI can assert behavior without re-parsing the output.
    """
    # Default completion_fn for tests: echoes a canned "mature" response that
    # passes grammar checks. Operator configures a real one.
    if completion_fn is None:
        def completion_fn(prompt: str) -> str:  # type: ignore
            return "<think>...</think>\nWAIT\n"

    replay_examples: list[CorpusExample] = []
    for tp in trace_paths:
        for entry in iter_replay_examples(tp):
            ex = build_replay_example(entry)
            if ex is not None:
                replay_examples.append(ex)

    # Synthetic count — `synthetic_ratio : 1` vs replay. Ensure at least one
    # scenario is generated even if replay is empty (cold-start corpus build).
    persona_list = persona_names or ["probe_being"]
    scenarios = []
    for persona in persona_list:
        scenarios.extend(generate_scenarios(
            persona_name=persona,
            entity_names=entity_names,
            object_names=object_names,
        ))

    target_synth = max(
        int(round(len(replay_examples) * synthetic_ratio)),
        len(scenarios),  # at minimum, use the full scenario battery once
    )
    # Tile scenarios up to target_synth with index-stable deduplication.
    synth_examples: list[CorpusExample] = []
    si = 0
    while len(synth_examples) < target_synth and scenarios:
        sc = scenarios[si % len(scenarios)]
        synth_examples.append(build_synthetic_example(sc, completion_fn))
        si += 1

    # Interleave to avoid pathological ordering in downstream shufflers.
    interleaved: list[CorpusExample] = []
    r = s = 0
    while r < len(replay_examples) or s < len(synth_examples):
        # roughly 1 replay per `synthetic_ratio` synthetic: in practice most
        # downstream trainers shuffle, so interleave is just hygiene.
        if r < len(replay_examples):
            interleaved.append(replay_examples[r]); r += 1
        # Push approximately ceil(synthetic_ratio) synthetic per replay.
        pushed = 0
        while s < len(synth_examples) and pushed < max(1, int(synthetic_ratio)):
            interleaved.append(synth_examples[s]); s += 1; pushed += 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as fp:
        for ex in interleaved:
            _write_example(fp, ex)

    # Build summary.
    cov: dict[str, int] = defaultdict(int)
    replay_count = 0
    synth_count = 0
    for ex in interleaved:
        k = ex.corpus_metadata.get("kind", "?")
        if k == "replay":
            replay_count += 1
            # Replay samples don't carry probe_verb; derive from command.
            cmd = (ex.corpus_metadata.get("command") or "").split()
            verb = cmd[0] if cmd else "UNKNOWN"
            cov[verb] += 1
        else:
            synth_count += 1
            cov[ex.corpus_metadata.get("probe_verb", "?")] += 1

    return {
        "output_path": str(output_path),
        "total": len(interleaved),
        "replay": replay_count,
        "synthetic": synth_count,
        "verb_coverage": dict(cov),
        "synthetic_ratio_target": synthetic_ratio,
        "synthetic_ratio_actual": (synth_count / replay_count) if replay_count else None,
        "generated_at": time.time(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="v3 training corpus generator")
    parser.add_argument("--trace", action="append", default=[],
                        help="Trace jsonl path(s); pass multiple --trace flags")
    parser.add_argument("--out", required=True, help="Output corpus jsonl path")
    parser.add_argument("--synthetic-ratio", type=float, default=SYNTHETIC_TO_REPLAY_RATIO)
    parser.add_argument("--min-examples", type=int, default=5000)
    args = parser.parse_args()

    trace_paths = [Path(p) for p in args.trace]
    out_path = Path(args.out)

    summary = generate_corpus(
        trace_paths=trace_paths,
        output_path=out_path,
        synthetic_ratio=args.synthetic_ratio,
    )
    print(json.dumps(summary, indent=2, default=str))
    if summary["total"] < args.min_examples:
        print(f"WARN: produced {summary['total']} examples; plan target is ≥ {args.min_examples}",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
