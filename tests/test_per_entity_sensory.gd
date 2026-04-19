extends SceneTree
## res://tests/test_per_entity_sensory.gd — Phase 2 acceptance.
##
## Verifies:
##   1. Two visible entities → two distinct sense_visible_{id} neurons.
##   2. Activation tracks exposure (e.g., exposure 0.7 → activation 70).
##   3. F9 merge: spawning neurons for ent_A and ent_B then merging into
##      canonical ent_A leaves one neuron with combined activation/connections.
##   4. GC: a tracker that hasn't fired in > tracker_expiry_ticks gets removed.
##
## Usage:
##   godot --path /home/thermos/workspace/burg --headless --quit \
##         --script res://tests/test_per_entity_sensory.gd

const PASS := "TEST_PER_ENTITY_SENSORY: PASS"
const FAIL := "TEST_PER_ENTITY_SENSORY: FAIL"

func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	# ----- Test 1: two distinct entities, distinct neurons -----
	var visible: Array = [
		{"id": "ent_aaaaaaaaaaaaaaaa", "name": "Mabel", "exposure": 0.7},
		{"id": "ent_bbbbbbbbbbbbbbbb", "name": "Hugo",  "exposure": 0.4},
	]
	net.update_per_entity_sensory(visible)

	var n_a: Dictionary = net._neuron_map.get("sense_visible_ent_aaaaaaaaaaaaaaaa", {})
	var n_b: Dictionary = net._neuron_map.get("sense_visible_ent_bbbbbbbbbbbbbbbb", {})
	if n_a.is_empty() or n_b.is_empty():
		print("%s: missing per-entity neuron(s). a=%s b=%s" % [FAIL, n_a, n_b]); quit(1); return

	if not is_equal_approx(float(n_a["activation"]), 70.0):
		print("%s: ent_A activation=%f expected 70" % [FAIL, n_a["activation"]]); quit(1); return
	if not is_equal_approx(float(n_b["activation"]), 40.0):
		print("%s: ent_B activation=%f expected 40" % [FAIL, n_b["activation"]]); quit(1); return
	if n_a["category"] != "per_entity_sensory":
		print("%s: category not set on per-entity neuron: %s" % [FAIL, n_a]); quit(1); return
	print("  PASS  two distinct entities → two neurons (act=%f / %f)" % [n_a["activation"], n_b["activation"]])

	# ----- Test 2: re-encounter increments tracker, refreshes activation -----
	visible[0]["exposure"] = 0.3  # entity A now barely visible
	net.update_per_entity_sensory([visible[0]])  # B not visible this tick
	var n_a2: Dictionary = net._neuron_map["sense_visible_ent_aaaaaaaaaaaaaaaa"]
	if not is_equal_approx(float(n_a2["activation"]), 30.0):
		print("%s: re-encounter activation=%f expected 30" % [FAIL, n_a2["activation"]]); quit(1); return
	var tr_a: Dictionary = net._per_entity_trackers["ent_aaaaaaaaaaaaaaaa"]
	if int(tr_a["encounter_count"]) < 2:
		print("%s: tracker count=%d expected >= 2" % [FAIL, tr_a["encounter_count"]]); quit(1); return
	print("  PASS  re-encounter refresh (act=%f, count=%d)" % [n_a2["activation"], tr_a["encounter_count"]])

	# ----- Test 3: F9 merge -----
	# Wire each per-entity neuron to action_observe with distinct weights.
	# After merge, the canonical should have weight = sum of both.
	net._add_connection("sense_visible_ent_aaaaaaaaaaaaaaaa", "action_observe", 0.10)
	net._add_connection("sense_visible_ent_bbbbbbbbbbbbbbbb", "action_observe", 0.05)
	# Merge B into A.
	var merged: bool = net.merge_entity_ids("ent_aaaaaaaaaaaaaaaa", "ent_bbbbbbbbbbbbbbbb")
	if not merged:
		print("%s: merge_entity_ids returned false" % FAIL); quit(1); return
	if net._neuron_map.has("sense_visible_ent_bbbbbbbbbbbbbbbb"):
		print("%s: deprecated neuron still in map after merge" % FAIL); quit(1); return
	if net._per_entity_trackers.has("ent_bbbbbbbbbbbbbbbb"):
		print("%s: deprecated tracker still present" % FAIL); quit(1); return
	# Canonical should keep its own weight + B's weight summed.
	var combined_w: float = 0.0
	for c in net.connections:
		if c["src"] == "sense_visible_ent_aaaaaaaaaaaaaaaa" and c["dst"] == "action_observe":
			combined_w = c["weight"]
	if not is_equal_approx(combined_w, 0.15):
		print("%s: merged weight=%f expected 0.15 (0.10 + 0.05)" % [FAIL, combined_w]); quit(1); return
	# Tracker encounter_count should sum.
	var tr_canon: Dictionary = net._per_entity_trackers["ent_aaaaaaaaaaaaaaaa"]
	if int(tr_canon["encounter_count"]) < 2:
		print("%s: post-merge tracker count=%d, expected >= 2" % [FAIL, tr_canon["encounter_count"]])
		quit(1); return
	print("  PASS  merge: weights summed (%.3f), trackers combined (count=%d)" %
		[combined_w, tr_canon["encounter_count"]])

	# ----- Test 4: GC removes idle neurons -----
	# Force the tracker's last_fire_tick way into the past (1 hour ago in ms).
	net._per_entity_trackers["ent_aaaaaaaaaaaaaaaa"]["last_fire_tick"] = (
		int(net._per_entity_trackers["ent_aaaaaaaaaaaaaaaa"]["last_fire_tick"]) - 3600 * 1000
	)
	var removed: int = net.gc_per_entity_sensory()
	# Phase 3: each entity has TWO per-entity neurons (sense_visible + sense_dist),
	# so GC of one entity removes 2 nodes.
	if removed != 2:
		print("%s: gc removed %d, expected 2 (visible + dist)" % [FAIL, removed]); quit(1); return
	if net._neuron_map.has("sense_visible_ent_aaaaaaaaaaaaaaaa"):
		print("%s: gc'd visible neuron still in map" % FAIL); quit(1); return
	if net._neuron_map.has("sense_dist_ent_aaaaaaaaaaaaaaaa"):
		print("%s: gc'd dist neuron still in map" % FAIL); quit(1); return
	# Connections involving the gc'd neuron should be gone too.
	for c in net.connections:
		if c["src"] == "sense_visible_ent_aaaaaaaaaaaaaaaa" or c["dst"] == "sense_visible_ent_aaaaaaaaaaaaaaaa":
			print("%s: orphan connection survived GC: %s" % [FAIL, c]); quit(1); return
	print("  PASS  GC removed idle neuron family (removed=%d)" % removed)

	print("%s (4/4 sub-tests)" % PASS)
	quit(0)
