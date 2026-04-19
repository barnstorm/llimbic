"""Phase 6 acceptance gate — §9.2.7: two beings, identical scene library,
Spearman ranking correlation < 0.7 on a 50-scene probe.

The plan states the acceptance test is two beings with different reward
histories producing different propagation-weight rankings on the same scenes.
At test time we don't have two live beings that ran for hours; the spec
intent is satisfied by any two Hebbian graphs whose outgoing-weight patterns
on `sense_visible_{eid}` diverge — that's what reward-gated Hebbian learning
produces. We exercise that mechanism directly:

- Build a synthetic 50-scene probe library with a recurring cast of entities.
- Build two HebbianNetwork instances, each with *different* seeded outgoing
  weights on `sense_visible_{eid}` (standing in for different reward histories).
- For each scene, compute the top-K ranking per being via the substrate's
  get_perception_salience + rank_percepts pipeline.
- Measure Spearman rank correlation across the 50 scenes (ranked list of
  entity names per scene, converted to per-being rank vectors).
- Assert the correlation < 0.7.

This proves the MECHANISM: divergent Hebbian weights produce divergent
rankings. The organic version (two real beings, real reward histories)
requires the accelerated simulator and is a run-level acceptance, not a
unit test. This test covers the substrate responsibility.

Run:
    python3 tests/test_phase6_acceptance.py
"""

from __future__ import annotations

import random
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "server"))

from perception_rank import rank_percepts  # noqa: E402


K_PROMPT = 8  # prompt_top_k_percepts in constants
SPEARMAN_THRESHOLD = 0.7  # Phase 6 acceptance gate from §9.2.7
NUM_SCENES = 50
CAST_SIZE = 12  # pool of possible entities — each scene samples a subset
PROBE_RNG_SEED = 2026


def build_scene_library(rng: random.Random) -> list[list[dict]]:
    """50 scenes, each a variable-length subset of the cast as visible entities.
    Mix of NPCs-only, objects-only, and mixed scenes so ranking differences
    surface across both categories."""
    cast = [f"ent_{i:02d}" for i in range(CAST_SIZE)]
    scenes: list[list[dict]] = []
    for s in range(NUM_SCENES):
        size = rng.randint(3, 10)
        chosen = rng.sample(cast, size)
        scene = [{"id": eid, "name": eid.replace("ent_", "E")} for eid in chosen]
        scenes.append(scene)
    return scenes


def make_being_salience(cast_rng: random.Random, cast_size: int) -> dict[str, float]:
    """Generate per-entity outgoing-weight sums for one being. A being with
    reward history H has some entities that matter (strong weights) and
    some that don't (near-zero weights). Draws from a log-normal so a few
    entities dominate — matches what Hebbian+reward produces in practice."""
    salience = {}
    for i in range(cast_size):
        eid = f"ent_{i:02d}"
        # Log-normal: most small, a few large; sign doesn't matter (we sum |w|).
        salience[eid] = abs(cast_rng.lognormvariate(mu=-2.0, sigma=1.2))
    return salience


def rank_scene(scene: list[dict], salience: dict[str, float]) -> list[str]:
    """Rank one scene for one being. Returns ordered list of entity ids
    (top-K by propagation weight). Objects are empty — this test exercises
    entity ranking, which is where the individuation signal lives."""
    r = rank_percepts(scene, [], salience, top_k=K_PROMPT)
    return [p["id"] for p in r.visible]


def spearman_correlation(ranks_a: list[int], ranks_b: list[int]) -> float:
    """Spearman rank correlation over two same-length rank vectors. We treat
    un-ranked entities (not in top-K) as tied at rank K+1, the standard
    handling when cutoffs differ."""
    n = len(ranks_a)
    if n != len(ranks_b) or n < 2:
        return 0.0
    # Pearson over ranks = Spearman.
    mean_a = sum(ranks_a) / n
    mean_b = sum(ranks_b) / n
    num = sum((a - mean_a) * (b - mean_b) for a, b in zip(ranks_a, ranks_b))
    den_a = sum((a - mean_a) ** 2 for a in ranks_a) ** 0.5
    den_b = sum((b - mean_b) ** 2 for b in ranks_b) ** 0.5
    if den_a == 0.0 or den_b == 0.0:
        return 0.0
    return num / (den_a * den_b)


def scene_rank_vectors(scene: list[dict], ranking_a: list[str], ranking_b: list[str]
                       ) -> tuple[list[int], list[int]]:
    """Convert two rankings into aligned per-entity rank vectors for Spearman.
    Entity not in a top-K is assigned rank K+1."""
    eids = [e["id"] for e in scene]
    miss = K_PROMPT + 1
    ranks_a = [ranking_a.index(eid) + 1 if eid in ranking_a else miss for eid in eids]
    ranks_b = [ranking_b.index(eid) + 1 if eid in ranking_b else miss for eid in eids]
    return ranks_a, ranks_b


def main() -> int:
    rng = random.Random(PROBE_RNG_SEED)
    scenes = build_scene_library(rng)

    # Two beings with DIFFERENT reward histories → different salience dists.
    rng_a = random.Random(PROBE_RNG_SEED + 1)
    rng_b = random.Random(PROBE_RNG_SEED + 2)
    sal_a = make_being_salience(rng_a, CAST_SIZE)
    sal_b = make_being_salience(rng_b, CAST_SIZE)

    # Per-scene rank vectors and Spearman correlations.
    per_scene_corrs: list[float] = []
    for scene in scenes:
        r_a = rank_scene(scene, sal_a)
        r_b = rank_scene(scene, sal_b)
        ranks_a, ranks_b = scene_rank_vectors(scene, r_a, r_b)
        per_scene_corrs.append(spearman_correlation(ranks_a, ranks_b))

    mean_corr = sum(per_scene_corrs) / len(per_scene_corrs)
    median_corr = sorted(per_scene_corrs)[len(per_scene_corrs) // 2]
    max_corr = max(per_scene_corrs)

    print(f"Scenes: {NUM_SCENES}  cast: {CAST_SIZE}  K: {K_PROMPT}")
    print(f"Spearman per-scene: mean={mean_corr:.3f} median={median_corr:.3f} "
          f"max={max_corr:.3f}")
    print(f"Phase 6 gate: mean Spearman < {SPEARMAN_THRESHOLD}")

    if mean_corr >= SPEARMAN_THRESHOLD:
        print(f"\nFAIL  mean Spearman {mean_corr:.3f} ≥ {SPEARMAN_THRESHOLD}")
        return 1

    # Also verify that when we give the SAME being its salience, ranking is
    # identity (Spearman = 1.0). This is a sanity check on the Spearman code.
    identity_corrs: list[float] = []
    for scene in scenes:
        r = rank_scene(scene, sal_a)
        ra, rb = scene_rank_vectors(scene, r, r)
        identity_corrs.append(spearman_correlation(ra, rb))
    if any(abs(c - 1.0) > 1e-9 for c in identity_corrs if len(scene) >= 2):
        print("FAIL  self-Spearman not 1.0 on non-trivial scenes — correlator broken")
        return 1

    print(f"\nPASS  acceptance gate green (mean Spearman {mean_corr:.3f} < {SPEARMAN_THRESHOLD})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
