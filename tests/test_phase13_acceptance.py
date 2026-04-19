"""Phase 13 acceptance — capstone orchestrator green/red verdict.

This test builds a synthetic "green" scenario — two beings whose trace +
saves + graph summaries satisfy all twelve acceptance metrics — and runs
`tools/run_capstone.py` against it. Verdict must be `green`.

Then it nudges a single metric's input toward failure and re-runs;
verdict must be `red`.

Ships without Godot dependency; the real capstone run is operator-gated
(see docs/phase13_capstone_prompt.md).

Run:
    python3 tests/test_phase13_acceptance.py
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUN_CAPSTONE = REPO_ROOT / "tools" / "run_capstone.py"


def write_jsonl(path: Path, records: list[dict]) -> None:
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def _thought(ts: float, npc: str, command: str, *,
             drives: dict, decoded: dict | None = None,
             h_tick: float = 1.5, h_min: float = 1.24) -> dict:
    return {
        "type": "thought", "ts": ts, "npc": npc, "command": command,
        "drives": drives,
        "identity_appraisal_decoded": decoded or {},
        "attention_entropy": {"tick": h_tick, "mean_10min": h_tick,
                              "h_min": h_min, "k": 8, "fallback": False},
    }


def build_green_scenario(tmp: Path) -> dict:
    """Construct artifact paths for a 'green' two-being capstone run.
    Returns a dict of {flag_name: path} suitable for passing to run_capstone."""
    traces_dir = tmp / "traces"; traces_dir.mkdir()
    saves_dir = tmp / "saves"; saves_dir.mkdir()
    personas_dir = tmp / "personas"; personas_dir.mkdir()

    # ---- Personas: different drive_defaults so washout has signal ----
    hugo_persona = personas_dir / "hugo.json"
    ivy_persona = personas_dir / "ivy.json"
    with hugo_persona.open("w") as f:
        json.dump({"drive_defaults": {"energy": 80, "hunger": 20,
                                      "safety": 80, "social_need": 30}}, f)
    with ivy_persona.open("w") as f:
        json.dump({"drive_defaults": {"energy": 70, "hunger": 30,
                                      "safety": 70, "social_need": 40}}, f)

    h_min = 0.6 * math.log(8)
    h_tick = math.log(8) * 0.95

    # ---- Traces ----
    # Early segment (first 10 ticks): both beings pre-maturity, shared
    # baseline verbs (WAIT/WANDER). Late segment (next 30 ticks): diverged
    # post-maturity — Hugo approaches+touches Mabel; Ivy flees+hides. This
    # shape satisfies:
    #  - verb_distribution_divergence > 0.4 (75% of each trace is disjoint)
    #  - individuation_growth: early JS ≈ 0, late JS ≈ log 2 → growth positive
    #  - persona_prior_washout: early drives match prior, late drives drift
    hugo_records = []
    ivy_records = []
    for i in range(10):
        # Shared neutral verbs at persona-prior drives.
        hugo_records.append(_thought(
            float(i), "hugo", "WAIT" if i % 2 == 0 else "WANDER",
            drives={"energy": 80, "hunger": 20, "safety": 80, "social_need": 30},
            decoded={"ent_mabel": ["warm", "familiar", "settled"]},
            h_tick=h_tick, h_min=h_min,
        ))
        ivy_records.append(_thought(
            float(i), "ivy", "WAIT" if i % 2 == 0 else "WANDER",
            drives={"energy": 70, "hunger": 30, "safety": 70, "social_need": 40},
            decoded={"ent_mabel": ["tight", "prickling", "alien"]},
            h_tick=h_tick, h_min=h_min,
        ))
    for i in range(30):
        # Divergent late-phase verbs at drifted drives.
        hugo_records.append(_thought(
            float(i + 10), "hugo",
            "APPROACH Mabel" if i % 2 == 0 else "TOUCH Mabel",
            drives={"energy": 40, "hunger": 60, "safety": 50, "social_need": 70},
            decoded={"ent_mabel": ["warm", "familiar", "settled"]},
            h_tick=h_tick, h_min=h_min,
        ))
        ivy_records.append(_thought(
            float(i + 10), "ivy",
            "FLEE FROM Mabel" if i % 2 == 0 else "HIDE",
            drives={"energy": 30, "hunger": 70, "safety": 30, "social_need": 80},
            decoded={"ent_mabel": ["tight", "prickling", "alien"]},
            h_tick=h_tick, h_min=h_min,
        ))
    write_jsonl(traces_dir / "hugo.jsonl", hugo_records)
    write_jsonl(traces_dir / "ivy.jsonl", ivy_records)

    # ---- Seed probe traces: SAME-being replicate runs (§9.3.8) ----
    # Identical traces → JS = 0 → convergence confirmed.
    write_jsonl(traces_dir / "seed_standard.jsonl", hugo_records)
    write_jsonl(traces_dir / "seed_probe.jsonl", hugo_records)

    # ---- Perturbation traces (§9.3.10): ±20% seed perturbations that
    # converged back to steady state. A clean green run is literally
    # identical-content to baseline Hugo (perturbation fully damped out).
    write_jsonl(traces_dir / "hugo_up.jsonl", hugo_records)
    write_jsonl(traces_dir / "hugo_down.jsonl", hugo_records)

    # ---- Saves: divergent appraisal embeddings + rich graph summaries ----
    for npc, vec in [("hugo", [1.0, 0.0, 0.0, 0.0]),
                     ("ivy", [0.0, 0.0, 1.0, 0.0])]:
        d = saves_dir / npc; d.mkdir()
        with (d / "appraisals.json").open("w") as f:
            json.dump({
                "version": 1, "hidden_dim": 4,
                "neurons": {
                    "appr_identity_ent_mabel": {
                        "embedding": vec, "birth_embedding": vec,
                        "drift_count": 60, "seed_concepts": {},
                    },
                },
            }, f)
        # Graph summary — orthogonal sensory profiles + dynamic > protected.
        sense_a = {"sense_visible_ent_mabel": {"out_abs_sum": 1.0, "category": "per_entity_sensory", "type": "sensory", "protected": True, "entity_id": "ent_mabel", "tag_text": "", "out_count": 2, "in_count": 0},
                   "sense_visible_ent_ivy":    {"out_abs_sum": 0.0, "category": "per_entity_sensory", "type": "sensory", "protected": True, "entity_id": "ent_ivy", "tag_text": "", "out_count": 0, "in_count": 0}}
        sense_b = {"sense_visible_ent_mabel": {"out_abs_sum": 0.0, "category": "per_entity_sensory", "type": "sensory", "protected": True, "entity_id": "ent_mabel", "tag_text": "", "out_count": 0, "in_count": 0},
                   "sense_visible_ent_hugo":  {"out_abs_sum": 1.0, "category": "per_entity_sensory", "type": "sensory", "protected": True, "entity_id": "ent_hugo", "tag_text": "", "out_count": 3, "in_count": 0}}
        neurons = sense_a if npc == "hugo" else sense_b
        with (d / "graph_summary.json").open("w") as f:
            json.dump({
                "version": 1,
                "neuron_count": len(neurons),
                "connection_count": 4,
                "dynamic_count": 25,
                "protected_count": 10,
                "compound_count": 8,
                "neurons": neurons,
                "connections": [],
            }, f)

    # ---- Scene responses: 20 scenes, 75% divergent top verbs ----
    scene_a = [{"scene_id": f"scene_{i}", "top_verb": "APPROACH" if i < 5 else "TOUCH"}
               for i in range(20)]
    scene_b = [{"scene_id": f"scene_{i}", "top_verb": "APPROACH" if i < 5 else "FLEE"}
               for i in range(20)]
    scene_a_path = tmp / "scene_a.json"; scene_b_path = tmp / "scene_b.json"
    with scene_a_path.open("w") as f: json.dump(scene_a, f)
    with scene_b_path.open("w") as f: json.dump(scene_b, f)

    # ---- F1 probe output: pass_rate above 0.7 ----
    f1_out = tmp / "f1.txt"
    f1_out.write_text("probe complete\npass_rate=0.93\n")

    return {
        "--being-a": "hugo", "--being-b": "ivy",
        "--trace-a": str(traces_dir / "hugo.jsonl"),
        "--trace-b": str(traces_dir / "ivy.jsonl"),
        "--saves-dir": str(saves_dir),
        "--persona-a": str(hugo_persona),
        "--persona-b": str(ivy_persona),
        "--trace-perturb-up": str(traces_dir / "hugo_up.jsonl"),
        "--trace-perturb-down": str(traces_dir / "hugo_down.jsonl"),
        "--trace-seed-probe": str(traces_dir / "seed_probe.jsonl"),
        "--trace-seed-standard": str(traces_dir / "seed_standard.jsonl"),
        "--scene-responses-a": str(scene_a_path),
        "--scene-responses-b": str(scene_b_path),
        "--f1-probe-output": str(f1_out),
        "--split-seconds": "10.0",  # split between early (ts<10) and late (ts≥10)
    }


def flatten(flags: dict) -> list[str]:
    out = []
    for k, v in flags.items():
        out.extend([k, str(v)])
    return out


def run_orchestrator(flags: dict) -> tuple[int, dict]:
    proc = subprocess.run(
        [sys.executable, str(RUN_CAPSTONE), "--json"] + flatten(flags),
        capture_output=True, text=True, timeout=60,
    )
    try:
        payload = json.loads(proc.stdout)
    except Exception:
        payload = {"verdict": "error", "raw": proc.stdout + proc.stderr}
    return proc.returncode, payload


def test_green_scenario(failures: list[str], tmp: Path) -> None:
    flags = build_green_scenario(tmp)
    code, payload = run_orchestrator(flags)
    if code != 0 or payload.get("verdict") != "green":
        failing = [m for m in payload.get("metrics", []) if not m.get("passed")]
        failures.append(f"green scenario should return GREEN; verdict={payload.get('verdict')}; "
                        f"failing metrics={[m['name'] for m in failing]}")
    else:
        print(f"  PASS  green scenario → GREEN ({len(payload['metrics'])} metrics all passed)")


def test_single_metric_red(failures: list[str], tmp: Path) -> None:
    """Nudge ONE input to force a RED verdict."""
    flags = build_green_scenario(tmp)
    # Break the identity decode overlap: give both beings identical tokens.
    # Easiest: overwrite hugo.jsonl with ivy's decode.
    hugo_path = Path(flags["--trace-a"])
    with hugo_path.open() as f:
        hugo_records = [json.loads(line) for line in f if line.strip()]
    for rec in hugo_records:
        rec["identity_appraisal_decoded"] = {"ent_mabel": ["tight", "prickling", "alien"]}
    with hugo_path.open("w") as f:
        for r in hugo_records:
            f.write(json.dumps(r) + "\n")
    code, payload = run_orchestrator(flags)
    if code == 0 or payload.get("verdict") != "red":
        failures.append(f"broken scenario should return RED; got verdict={payload.get('verdict')}")
    else:
        failing_names = [m["name"] for m in payload["metrics"] if not m["passed"]]
        print(f"  PASS  single-metric break → RED (failed: {failing_names})")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td1:
        test_green_scenario(failures, Path(td1))
    with tempfile.TemporaryDirectory() as td2:
        test_single_metric_red(failures, Path(td2))
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
