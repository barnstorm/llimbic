"""F10 parity test: data/perception_constants.json must read identically from
both Python and GDScript.

The substrate's Tier-2 seed values are read by both languages. Drift between
the Python view and the GDScript view will surface as silent behavioral
divergence, weeks after introduction. This test catches that drift at PR time.

Pass criterion: every key/value in the JSON, parsed by Python, equals the
corresponding key/value as dumped by Godot reading the same file.

Run:
    python -m pytest tests/test_constants_parity.py -v
or:
    python tests/test_constants_parity.py

The test will skip the GDScript-side check (with a loud warning) if the
`godot` binary is not on PATH. Schema validation still runs in that case.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
CONSTANTS_PATH = REPO_ROOT / "data" / "perception_constants.json"
DUMPER_SCRIPT = "res://tests/dump_constants.gd"
DUMP_MARKER = "PARITY_DUMP:"

# Required top-level keys per docs/perception_implementation_plan.md.
# Underscore-prefixed keys are documentation strings and are not asserted.
REQUIRED_TOP_LEVEL_KEYS: set[str] = {
    "embedding_bridge",
    "hebbian",
    "neurogenesis_thresholds",
    "sensors",
    "capacity",
    "reward_magnitudes",
    "drive_thresholds",
    "thought_entity_bind_threshold",
    "identity_filter_min_rejection_rate",
    "h_min_attention_entropy_factor",
    "n_fallback_retire",
    "training_maturity",
    "magnitude_sensitivity_max_kl",
    "semantic_probe_min_pass_rate",
}

REQUIRED_NESTED_KEYS: dict[str, set[str]] = {
    "embedding_bridge": {
        "drift_rate", "gravity_rate", "drift_count_persist_threshold",
        "decode_top_k", "embedding_cache_size", "bootstrap_concepts",
    },
    "hebbian": {"eta", "theta", "beta", "reward_signal_decay_seconds"},
    "neurogenesis_thresholds": {
        "quality_constellation_min", "quality_constellation_sustained_count",
        "quality_constellation_window_seconds",
        "appraisal_constellation_min", "appraisal_constellation_threshold",
        "appraisal_constellation_sustained_seconds",
        "stress_threshold", "stress_sustained_seconds",
        "novelty_threshold", "novelty_sustained_seconds",
        "encounter_threshold",
        "distance_action_co_fire_count", "distance_action_window_seconds",
        "cross_modal_co_fire_count", "cross_modal_window_seconds",
        "temporal_persistence_seconds",
        "temporal_dwell_min", "temporal_rate_min",
    },
    "sensors": {
        "fov_pixels", "hearing_pixels", "distance_tau_tiles", "tracker_expiry_ticks",
        "dwell_ema_alpha",
    },
    "capacity": {
        "max_appraisal_per_being", "max_compound_quality", "prompt_top_k_percepts",
    },
    "reward_magnitudes": {
        "reward_drive_satisfaction", "reward_drive_stabilization",
        "reward_social_accepted", "reward_rest_recovered",
        "reward_explore_discovered", "reward_threat_avoided",
        "reward_action_succeeded",
    },
    "training_maturity": {
        "min_compound_neurons", "min_appr_identity",
        "min_mean_drift_per_appraisal", "synthetic_to_replay_ratio",
    },
}


def _strip_doc_keys(obj: Any) -> Any:
    """Recursively remove keys starting with underscore (doc-only keys)."""
    if isinstance(obj, dict):
        return {k: _strip_doc_keys(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [_strip_doc_keys(v) for v in obj]
    return obj


def load_python_side() -> dict[str, Any]:
    with CONSTANTS_PATH.open() as f:
        return json.load(f)


def load_godot_side() -> dict[str, Any] | None:
    """Run Godot headless to dump the constants. Returns None if Godot is unavailable."""
    godot_bin = shutil.which("godot") or shutil.which("godot4")
    if godot_bin is None:
        print("WARNING: 'godot' binary not on PATH — skipping GDScript-side parity check.")
        print("WARNING: Schema validation will still run, but full F10 gate is NOT green.")
        return None

    proc = subprocess.run(
        [godot_bin, "--headless", "--quit", "--script", DUMPER_SCRIPT],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )
    # Godot prints diagnostic noise to stdout; fish out our marker line.
    for line in proc.stdout.splitlines():
        if line.startswith(DUMP_MARKER):
            payload = line[len(DUMP_MARKER):]
            return json.loads(payload)
    raise RuntimeError(
        f"GDScript dumper produced no '{DUMP_MARKER}' line. "
        f"stdout=\n{proc.stdout}\nstderr=\n{proc.stderr}"
    )


def _approx_equal(a: Any, b: Any, rel: float = 1e-9, abs_tol: float = 1e-12) -> bool:
    """Equality with tolerance for floats. Lists/dicts recurse; everything else uses ==."""
    if isinstance(a, float) or isinstance(b, float):
        try:
            af, bf = float(a), float(b)
        except (TypeError, ValueError):
            return False
        return abs(af - bf) <= max(rel * max(abs(af), abs(bf)), abs_tol)
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a.keys()) != set(b.keys()):
            return False
        return all(_approx_equal(a[k], b[k], rel, abs_tol) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return False
        return all(_approx_equal(x, y, rel, abs_tol) for x, y in zip(a, b))
    return a == b


def _diff_paths(a: Any, b: Any, prefix: str = "") -> list[str]:
    """Return dotted-path descriptions of every divergence between a and b."""
    diffs: list[str] = []
    if isinstance(a, dict) and isinstance(b, dict):
        keys = set(a.keys()) | set(b.keys())
        for k in sorted(keys):
            path = f"{prefix}.{k}" if prefix else k
            if k not in a:
                diffs.append(f"{path}: missing in Python ({b[k]!r} in Godot)")
            elif k not in b:
                diffs.append(f"{path}: missing in Godot ({a[k]!r} in Python)")
            else:
                diffs.extend(_diff_paths(a[k], b[k], path))
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            diffs.append(f"{prefix}: list length differs (Python={len(a)}, Godot={len(b)})")
        else:
            for i, (x, y) in enumerate(zip(a, b)):
                diffs.extend(_diff_paths(x, y, f"{prefix}[{i}]"))
    else:
        if not _approx_equal(a, b):
            diffs.append(f"{prefix}: Python={a!r} Godot={b!r}")
    return diffs


def test_schema_required_keys() -> None:
    """The JSON contains every required top-level and nested key per the plan."""
    py = _strip_doc_keys(load_python_side())
    missing_top = REQUIRED_TOP_LEVEL_KEYS - set(py.keys())
    assert not missing_top, f"Missing required top-level keys: {missing_top}"

    for parent, required in REQUIRED_NESTED_KEYS.items():
        assert parent in py, f"Missing parent key: {parent}"
        assert isinstance(py[parent], dict), f"{parent} is not an object"
        missing = required - set(py[parent].keys())
        assert not missing, f"Missing keys under {parent}: {missing}"


def test_schema_value_types() -> None:
    """Spot-check types on values that downstream code will assume."""
    py = load_python_side()
    eb = py["embedding_bridge"]
    assert isinstance(eb["drift_rate"], (int, float))
    assert isinstance(eb["gravity_rate"], (int, float))
    assert isinstance(eb["drift_count_persist_threshold"], int)
    assert isinstance(eb["decode_top_k"], int)
    assert isinstance(eb["bootstrap_concepts"], list)
    assert all(isinstance(c, str) for c in eb["bootstrap_concepts"])
    assert isinstance(py["thought_entity_bind_threshold"], (int, float))
    assert isinstance(py["identity_filter_min_rejection_rate"], (int, float))
    assert isinstance(py["n_fallback_retire"], int)
    assert isinstance(py["semantic_probe_min_pass_rate"], (int, float))


def test_python_godot_parity() -> None:
    """Loaded values must match between Python and GDScript readers."""
    py = _strip_doc_keys(load_python_side())
    godot = load_godot_side()
    if godot is None:
        # GDScript-side check skipped; covered by the warning printed inside load_godot_side.
        return
    godot_clean = _strip_doc_keys(godot)
    diffs = _diff_paths(py, godot_clean)
    assert not diffs, "Python/GDScript parity violations:\n  " + "\n  ".join(diffs)


def main() -> int:
    """Run as a script (no pytest required)."""
    failed = 0
    for name, fn in [
        ("schema_required_keys", test_schema_required_keys),
        ("schema_value_types", test_schema_value_types),
        ("python_godot_parity", test_python_godot_parity),
    ]:
        try:
            fn()
            print(f"PASS  {name}")
        except AssertionError as e:
            print(f"FAIL  {name}: {e}")
            failed += 1
        except Exception as e:
            print(f"ERROR {name}: {e}")
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
