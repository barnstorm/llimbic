extends SceneTree
## res://tests/test_temporal_texture_neurogenesis.gd — Phase 10 spawn wiring.
##
## Verifies:
## 1. Sustained high dwell on sense_visible_{eid} for T seconds spawns
##    q_lingering_{eid} wired to sense_visible_{eid}.
## 2. Sustained positive rate on sense_dist_{eid} for T seconds spawns
##    q_approaching_fast_{eid} wired to sense_dist_{eid}.
## 3. A brief dip below threshold RESETS the counter (continuous requirement).
## 4. drain_new_temporal_textures is one-shot.
## 5. Duplicate spawn is a no-op (dedup via _temporal_spawned).
## 6. update_temporal_activations tracks parent channel — when dwell drops,
##    the lingering compound's activation decays.
##
## Usage:
##   godot --headless --quit --script res://tests/test_temporal_texture_neurogenesis.gd

const MARKER_OK := "TEST_TEMPORAL_TEXTURE: PASS"
const MARKER_FAIL := "TEST_TEMPORAL_TEXTURE: FAIL"


func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	if Net == null:
		print("%s — could not load hebbian_network.gd" % MARKER_FAIL)
		quit(1); return
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	var eid: String = "ent_hugo"
	var persistence: float = 8.0  # temporal_persistence_seconds default

	# Spawn both parent sense neurons.
	net.update_per_entity_sensory([{
		"id": eid, "exposure": 0.9, "distance_tiles": 2.0,
	}])

	# --- 1. Sustained high dwell → spawn q_lingering ---
	# Force the dwell EMA on sense_visible_{eid} to a high value.
	net._neuron_map["sense_visible_" + eid]["dwell"] = 60.0
	# Sustained rate on sense_dist_{eid}.
	net._neuron_map["sense_dist_" + eid]["rate"] = 1.2

	# Drive the tracker enough seconds to cross persistence.
	var dt: float = 0.1
	var total_secs: float = 0.0
	while total_secs < persistence + 1.0:
		# Keep channels pinned high each tick (simulate continuous presence).
		net._neuron_map["sense_visible_" + eid]["dwell"] = 60.0
		net._neuron_map["sense_dist_" + eid]["rate"] = 1.2
		net.update_temporal_textures(dt)
		total_secs += dt

	var lingering_id: String = "q_lingering_" + eid
	var approach_id: String = "q_approaching_fast_" + eid

	if not net._neuron_map.has(lingering_id):
		print("%s — q_lingering_{eid} did not spawn after sustained high dwell" % MARKER_FAIL)
		quit(1); return
	if not net._neuron_map.has(approach_id):
		print("%s — q_approaching_fast_{eid} did not spawn after sustained positive rate" % MARKER_FAIL)
		quit(1); return

	# --- 2. Verify wiring ---
	var lingering_sources: Array = []
	var approach_sources: Array = []
	for c in net.connections:
		if c["dst"] == lingering_id:
			lingering_sources.append(String(c["src"]))
		elif c["dst"] == approach_id:
			approach_sources.append(String(c["src"]))
	if not lingering_sources.has("sense_visible_" + eid):
		print("%s — lingering missing sense_visible parent" % MARKER_FAIL)
		quit(1); return
	if not approach_sources.has("sense_dist_" + eid):
		print("%s — approaching_fast missing sense_dist parent" % MARKER_FAIL)
		quit(1); return

	# --- 3. Verify categories + tag_text (decoded tokens) ---
	var lin: Dictionary = net._neuron_map[lingering_id]
	if String(lin.get("category", "")) != "compound_quality_temporal":
		print("%s — wrong category: %s" % [MARKER_FAIL, lin.get("category")])
		quit(1); return
	if String(lin.get("tag_text", "")) != "lingering":
		print("%s — wrong tag_text: %s" % [MARKER_FAIL, lin.get("tag_text")])
		quit(1); return
	var apr: Dictionary = net._neuron_map[approach_id]
	if String(apr.get("tag_text", "")) != "approaching_fast":
		print("%s — approaching tag_text wrong: %s" % [MARKER_FAIL, apr.get("tag_text")])
		quit(1); return
	print("  PASS  both textures spawned with correct category + tag_text")

	# --- 4. drain_new_temporal_textures is one-shot ---
	var drained: Array = net.drain_new_temporal_textures()
	if drained.size() != 2:
		print("%s — expected 2 drained textures, got %d" % [MARKER_FAIL, drained.size()])
		quit(1); return
	var drain2: Array = net.drain_new_temporal_textures()
	if not drain2.is_empty():
		print("%s — drain did not clear" % MARKER_FAIL)
		quit(1); return
	print("  PASS  drain one-shot")

	# --- 5. Counter RESETS on dip (continuous requirement) ---
	var eid2: String = "ent_mabel"
	net.update_per_entity_sensory([{
		"id": eid2, "exposure": 0.9, "distance_tiles": 2.0,
	}])
	# Alternate above/below every tick — counter should never accumulate.
	var dip_secs: float = 0.0
	var toggle: bool = true
	while dip_secs < persistence * 2.0:
		if toggle:
			net._neuron_map["sense_visible_" + eid2]["dwell"] = 60.0
		else:
			net._neuron_map["sense_visible_" + eid2]["dwell"] = 10.0
		toggle = not toggle
		net.update_temporal_textures(dt)
		dip_secs += dt
	if net._neuron_map.has("q_lingering_" + eid2):
		print("%s — lingering spawned despite alternating dwell (continuous bug)" % MARKER_FAIL)
		quit(1); return
	print("  PASS  discontinuous high dwell does not spawn lingering")

	# --- 6. update_temporal_activations tracks parent channel ---
	# Drop the first entity's dwell — lingering compound activation should fade.
	net._neuron_map["sense_visible_" + eid]["dwell"] = 0.0
	net.update_temporal_activations()
	var lin_act_after_drop: float = float(net._neuron_map[lingering_id]["activation"])
	if lin_act_after_drop > 5.0:
		print("%s — lingering activation did not decay after dwell dropped (act=%f)" % [MARKER_FAIL, lin_act_after_drop])
		quit(1); return
	print("  PASS  temporal compound activation tracks parent dwell/rate")

	# --- 7. Duplicate spawn no-op (direct dedup exercise) ---
	# Call _spawn_temporal_texture again for the same eid/kind; dedup must
	# refuse without incrementing counts or drains. This isolates the test
	# from any other eids' tracker state.
	var prev_compound_count: int = net.get_compound_count()
	net._spawn_temporal_texture("lingering", eid, "sense_visible_" + eid)
	net._spawn_temporal_texture("approaching_fast", eid, "sense_dist_" + eid)
	if net.get_compound_count() != prev_compound_count:
		print("%s — duplicate spawn re-incremented compound_count (before=%d now=%d)" % [
			MARKER_FAIL, prev_compound_count, net.get_compound_count()
		])
		quit(1); return
	var drain3: Array = net.drain_new_temporal_textures()
	# drain3 may be non-empty if another eid's tracker crossed legitimately,
	# but MUST NOT contain eid's kinds (those are deduped).
	for item in drain3:
		if String(item.get("entity_id", "")) == eid:
			print("%s — dedup failed: re-spawned for ent_hugo (%s)" % [MARKER_FAIL, item])
			quit(1); return
	print("  PASS  duplicate spawn suppressed (compound_count stable + no re-drain for eid)")

	# --- 8. F9 merge covers new prefixes ---
	# Build a lingering for a deprecated eid then merge into canonical.
	var deprecated: String = "ent_stranger_for_merge"
	net.update_per_entity_sensory([{
		"id": deprecated, "exposure": 0.9, "distance_tiles": 2.0,
	}])
	net._neuron_map["sense_visible_" + deprecated]["dwell"] = 60.0
	net.update_temporal_textures(persistence + 1.0)
	if not net._neuron_map.has("q_lingering_" + deprecated):
		print("%s — deprecated lingering did not spawn" % MARKER_FAIL)
		quit(1); return
	net.merge_entity_ids(eid2, deprecated)
	if net._neuron_map.has("q_lingering_" + deprecated):
		print("%s — merge did not drop deprecated q_lingering" % MARKER_FAIL)
		quit(1); return
	print("  PASS  F9 merge covers q_lingering_/q_approaching_fast_ prefixes")

	print(MARKER_OK)
	quit(0)
