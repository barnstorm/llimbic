# Entity ID Protocol

> **Status.** Pre-flight design doc for `docs/perception_implementation_plan.md`. Addresses Finding F9 — without a stable canonical ID, per-entity sense-neurons (Phase 2) and identity-appraisals (Phase 5) fragment across renames, scene reloads, or recognition events. Each entity ends up with multiple partially-developed neuron families. This document defines the contract.

## The problem

Per-entity neurons key off `entity_id`. The being develops:

- `sense_visible_{entity_id}` — Phase 2
- `appr_identity_{entity_id}` — Phase 5
- `bind_{entity_id}` — Phase 9
- Per-entity encounter accumulators (count, first/last seen, thought deque)

If `entity_id` is unstable, the substrate fragments. Concrete failure modes:

1. **Scene reload.** A being walks east, the world streams in a new chunk, Mabel's old node is freed, a new node spawns with a new ID. The being's `appr_identity_Mabel_old` keeps drifting in isolation; new encounters spawn `sense_visible_Mabel_new` without history.
2. **Recognition events.** The being first sees Mabel as "a stranger" (entity_id = `stranger_3792`). After a dialogue or proximity event, the being recognizes her (entity_id rebinds to `mabel`). Two neuron families now exist for the same person.
3. **Save/load.** The being persists `appr_identity_mabel`. On reload, the world spawns Mabel with a runtime ID `npc_4117`. The persisted appraisal can't find its referent.

## The contract

**Canonical entity ID is a stable, world-load-time-assigned UUID, independent of display name, frozen across the entity's lifetime, persisted in the save file.**

### Properties

- **Stable.** Assigned once at first spawn. Never reassigned. Persists in saves.
- **Independent of display name.** "stranger", "the woman in red", "Mabel" are all display labels. None of them are the entity_id. Display labels can change; entity_id never does.
- **Independent of node identity.** Godot node `Mabel_4117` is a runtime object. Its `entity_id` is the persistent fact. If the node is freed and respawned (scene reload, save/load), the new node carries the same `entity_id`.
- **Globally unique within a save.** A single being's substrate can refer to `entity_id_a3f2…` and trust it means one specific entity, world-wide.

### Format

```
entity_id := "ent_" + 16-char-hex-uuid

# Examples:
ent_a3f2b9d4e1c8a672
ent_5710f8c39b2da647
```

UUIDs are generated with `Crypto.generate_random_bytes(8).hex_encode()` at spawn time. Stable across sessions, scene boundaries, and restart.

### Engine-side responsibilities

- Each NPC, item, and addressable world object is assigned an `entity_id` at first spawn.
- The `entity_id` is written to the entity's saved state on every save.
- On load, entities recover their `entity_id` from save before any sensor or perception code runs.
- Scene reloads do NOT generate new IDs; they look up the entity in the save and recover its existing `entity_id`.
- The `entity_id` is exposed to GDScript via a property on every perceivable node: `node.entity_id` (string).
- Display name (`node.display_name` or equivalent) is a separate property; perception code that wants a name calls a name resolver that maps `entity_id → current_display_name_for_this_being`.

## The recognition merge protocol

When a being first sees an entity, it doesn't necessarily know who it is. The substrate spawns `sense_visible_{entity_id}` keyed off the canonical UUID — not the display name. This means **sensor neurons are correct from the first encounter**, even if the being calls the entity "stranger."

Display-name binding is a separate, social-cognitive event:

- Initially, the being's name resolver returns `"stranger"` for `ent_a3f2…`.
- After a recognition event (dialogue introduction, mentor pointing them out, repeated benign exposure), the being's name resolver gets updated to return `"Mabel"` for `ent_a3f2…`.
- **No neuron merge is required.** The neurons were always keyed on `ent_a3f2…`. Only the rendering of that ID into the prompt changes — `"stranger" → "Mabel"`.

This is the cleanest case. No fragmentation, no merge, just a relabel.

### When a true merge IS required

The protocol must still handle the case where the substrate accidentally spawned two neuron families for what turns out to be one entity. This happens when:

1. **Initial misidentification.** The being thought two distant glimpses were two strangers. Later they realize it was the same person. (Pixel-distance disambiguation failed.)
2. **Pre-protocol data.** Saves from before this protocol existed have inconsistent IDs.
3. **Cross-being entity-fusion event.** (Future.) Beings discuss and agree two entities are the same.

In these cases, an explicit merge:

```
merge_entity_ids(canonical_id, deprecated_id) -> void:
    For each per-entity neuron family keyed on deprecated_id:
        - sense_visible_{deprecated_id}     → merge into sense_visible_{canonical_id}
        - sense_heard_{deprecated_id}       → merge into sense_heard_{canonical_id}
        - sense_dist_{deprecated_id}        → merge into sense_dist_{canonical_id}
        - appr_identity_{deprecated_id}     → merge into appr_identity_{canonical_id}
        - bind_{deprecated_id}              → merge into bind_{canonical_id}

    Merge rule for each neuron pair:
        - activation: max(canonical, deprecated)
        - outgoing connection weights: weight-sum (clamp to [0, 1] if needed)
        - incoming connection weights: weight-sum
        - encounter accumulator: sum counts, max(last_seen), min(first_seen),
          concat thought_embeddings_during_encounters deques

    For appraisal embeddings specifically:
        - canonical.embedding := normalize(
              canonical.drift_count * canonical.embedding +
              deprecated.drift_count * deprecated.embedding
          )
        - canonical.drift_count := canonical.drift_count + deprecated.drift_count
        - canonical.birth_embedding := unchanged (canonical's birth wins)

    Delete deprecated neurons.
    Update name-resolver entries to map deprecated_id → canonical_id transparently.
```

This is implemented in `scripts/hebbian_network.gd:merge_entity_ids()` and the parallel `server/appraisal_embeddings.py:merge_entity_ids()`. Phase 2 introduces the function (when per-entity neurons first exist); Phase 5 extends it for appraisals.

## Save file integration

- Each NPC's save file (`saves/{npc}/state.json` or equivalent) records the `entity_id` of every other entity it has neurons or memory for.
- On load, the engine first reconstructs the world (each entity gets its `entity_id` from world save), then loads each NPC's save (which references those `entity_id`s).
- If an `entity_id` referenced in an NPC save no longer exists in the world (entity was deleted, save corruption), the orphan neurons are GC'd after `TRACKER_EXPIRY` ticks of non-firing.

## What perception code must NOT do

- Never key Hebbian neurons or appraisal state on display name (`"Mabel"`, `"stranger"`).
- Never key on Godot runtime node ID, instance ID, or path.
- Never assume two display names refer to different entities; always check `entity_id`.
- Never assume two entity_ids refer to different entities at the entity-canonical level; merges are possible but explicit.

## Verification (gates this protocol's correctness)

Two test scenarios that must pass before Phase 2 ships:

1. **Scene-reload preservation.** Spawn Hugo and Mabel. Hugo accumulates 10 encounters with Mabel. Force a scene reload (engine restart with save/reload). Verify Hugo's `sense_visible_{mabel_id}` and encounter count survive intact.

2. **Stranger-to-name preservation.** Spawn Hugo and Mabel with display name "stranger" (Hugo doesn't know her name yet). Hugo accumulates 5 encounters keyed on Mabel's canonical `entity_id`. Trigger a name-binding event ("Hi, I'm Mabel"). Verify:
   - The neuron `sense_visible_{mabel_id}` is unchanged (count = 5, weights unchanged).
   - Hugo's prompt now renders Mabel's name as "Mabel" instead of "stranger."
   - No new neuron family was spawned.

These tests live in `tests/test_entity_id_stability.gd` and run in CI alongside the constants parity test.
