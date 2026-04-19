"""Phase 6 — rank_percepts unit tests.

Verifies the Python-side ranking module:
- Top-K selected across both lists by propagation-weight sum.
- Stable tiebreak preserves input order for equal scores.
- Cold-start (all-zero salience) collapses to input order with fallback=True.
- Category-first bias is GONE: a high-salience object outranks a low-salience
  entity even though entities are listed first in the input.

Run:
    python3 tests/test_perception_rank.py
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from perception_rank import rank_percepts, attention_entropy, h_floor


def test_basic_top_k(failures: list[str]) -> None:
    visible = [
        {"id": "ent_a", "name": "A"},
        {"id": "ent_b", "name": "B"},
        {"id": "ent_c", "name": "C"},
    ]
    objects = [
        {"id": "obj_x", "name": "X"},
        {"id": "obj_y", "name": "Y"},
    ]
    sal = {"ent_a": 0.10, "ent_b": 0.80, "ent_c": 0.05, "obj_x": 0.60, "obj_y": 0.02}
    r = rank_percepts(visible, objects, sal, top_k=3)
    # Top-3 by score: B (0.80), X (0.60), A (0.10). Weights should reflect.
    if [p["name"] for p in r.visible] != ["B", "A"]:
        failures.append(f"expected [B, A] visible, got {[p['name'] for p in r.visible]}")
    if [p["name"] for p in r.visible_objects] != ["X"]:
        failures.append(f"expected [X] objects, got {[p['name'] for p in r.visible_objects]}")
    if r.weights != [0.80, 0.60, 0.10]:
        failures.append(f"weights wrong: {r.weights}")
    if r.fallback:
        failures.append("unexpected fallback=True for non-zero salience")
    else:
        print("  PASS  top-K selection ranks across both lists")


def test_category_bias_is_gone(failures: list[str]) -> None:
    """The old scaffold did `visible[:6] + visible_objects[:4]` which meant
    high-salience objects could be starved by low-salience entities. Verify
    an object with overwhelming salience outranks every entity."""
    visible = [{"id": f"ent_{i}", "name": f"E{i}"} for i in range(6)]
    objects = [{"id": "obj_hot", "name": "HOT"}]
    sal = {f"ent_{i}": 0.05 for i in range(6)}
    sal["obj_hot"] = 5.0
    r = rank_percepts(visible, objects, sal, top_k=3)
    # Top-1 must be HOT even though entities are iterated first.
    if not r.visible_objects or r.visible_objects[0]["name"] != "HOT":
        failures.append(f"HOT object did not win top-1; got vis={r.visible} obj={r.visible_objects}")
    else:
        print("  PASS  high-salience object outranks entities (category bias gone)")


def test_cold_start_fallback(failures: list[str]) -> None:
    """All-zero salience: input order preserved, fallback=True."""
    visible = [{"id": "ent_a", "name": "A"}, {"id": "ent_b", "name": "B"}]
    objects = [{"id": "obj_x", "name": "X"}, {"id": "obj_y", "name": "Y"}]
    r = rank_percepts(visible, objects, {}, top_k=3)
    if [p["name"] for p in r.visible] != ["A", "B"]:
        failures.append(f"cold-start visible order lost: {[p['name'] for p in r.visible]}")
    if [p["name"] for p in r.visible_objects] != ["X"]:
        failures.append(f"cold-start objects order lost: {[p['name'] for p in r.visible_objects]}")
    if not r.fallback:
        failures.append("fallback flag not set on cold start")
    else:
        print("  PASS  cold-start preserves input order and reports fallback=True")


def test_stable_tiebreak(failures: list[str]) -> None:
    """Equal scores → original-index stable sort. First visible, then objects."""
    visible = [{"id": "ent_a", "name": "A"}, {"id": "ent_b", "name": "B"}]
    objects = [{"id": "obj_x", "name": "X"}]
    sal = {"ent_a": 0.5, "ent_b": 0.5, "obj_x": 0.5}
    r = rank_percepts(visible, objects, sal, top_k=3)
    if [p["name"] for p in r.visible] != ["A", "B"]:
        failures.append(f"tiebreak violated visible order: {[p['name'] for p in r.visible]}")
    if [p["name"] for p in r.visible_objects] != ["X"]:
        failures.append(f"tiebreak violated objects order: {[p['name'] for p in r.visible_objects]}")
    else:
        print("  PASS  equal scores tiebreak to input order")


def test_attention_entropy(failures: list[str]) -> None:
    import math
    # Uniform over K weights → H = log(K).
    h_uniform = attention_entropy([1.0, 1.0, 1.0, 1.0])
    if abs(h_uniform - math.log(4)) > 1e-6:
        failures.append(f"H(uniform 4) expected {math.log(4):.4f}, got {h_uniform:.4f}")
    else:
        print(f"  PASS  H(uniform K=4) = log(4) ({h_uniform:.4f})")

    # Tunnel vision: one dominant weight → H ≈ 0.
    h_tunnel = attention_entropy([100.0, 0.001, 0.001, 0.001])
    if h_tunnel > 0.1:
        failures.append(f"H(tunnel) should be ~0, got {h_tunnel:.4f}")
    else:
        print(f"  PASS  H(tunnel) ≈ 0 ({h_tunnel:.4f})")

    # All zero → 0.
    if attention_entropy([0, 0, 0]) != 0.0:
        failures.append("H(all zero) should be 0")

    # Floor function: factor * log(K).
    if abs(h_floor(8, 0.6) - 0.6 * math.log(8)) > 1e-9:
        failures.append("h_floor(8, 0.6) wrong")
    else:
        print(f"  PASS  h_floor(K=8, factor=0.6) = {h_floor(8, 0.6):.4f}")


def test_empty_inputs(failures: list[str]) -> None:
    r = rank_percepts([], [], {}, top_k=8)
    if r.visible or r.visible_objects or r.weights:
        failures.append("empty input should yield empty ranking")
    elif not r.fallback:
        failures.append("empty input should set fallback=True")
    else:
        print("  PASS  empty input handled (fallback=True, nothing returned)")


def main() -> int:
    failures: list[str] = []
    print("test_basic_top_k:");             test_basic_top_k(failures)
    print("test_category_bias_is_gone:");   test_category_bias_is_gone(failures)
    print("test_cold_start_fallback:");     test_cold_start_fallback(failures)
    print("test_stable_tiebreak:");         test_stable_tiebreak(failures)
    print("test_attention_entropy:");       test_attention_entropy(failures)
    print("test_empty_inputs:");            test_empty_inputs(failures)
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
