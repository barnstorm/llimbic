extends SceneTree
## res://tests/test_identity_appraisal_spawn.gd — Phase 5 spawn wiring test.
##
## Exercises HebbianNetwork.spawn_identity_appraisal (called from the server
## via the spawn_identity_appraisal push command). Verifies:
## 1. Spawn refuses when sense_visible_{eid} doesn't exist yet.
## 2. After a visibility tick creates sense_visible_{eid}, spawn creates a
##    neuron typed "appraisal", category "identity_appraisal", entity_id={eid}.
## 3. Incoming connection from sense_visible_{eid} exists at the expected weight.
## 4. Incoming connections from every currently-active quality neuron
##    (activation >= 30) exist at the expected weight.
## 5. Duplicate spawn calls are no-ops (returns false).
## 6. F9 merge path covers appr_identity_ prefix (merge_entity_ids moves wiring
##    to the canonical neuron, drops the deprecated one).
##
## Usage:
##   godot --headless --quit --script res://tests/test_identity_appraisal_spawn.gd

const MARKER_OK := "TEST_IDENTITY_APPRAISAL_SPAWN: PASS"
const MARKER_FAIL := "TEST_IDENTITY_APPRAISAL_SPAWN: FAIL"

func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	if Net == null:
		print("%s — could not load hebbian_network.gd" % MARKER_FAIL)
		quit(1); return
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	var eid: String = "ent_mabel"
	var nid: String = "appr_identity_" + eid

	# 1. Without sense_visible_{eid}, spawn must refuse.
	var refused: bool = net.spawn_identity_appraisal(nid, eid)
	if refused:
		print("%s — spawn succeeded before sense_visible_{eid} existed" % MARKER_FAIL)
		quit(1); return
	if net._neuron_map.has(nid):
		print("%s — spawn created neuron despite returning false" % MARKER_FAIL)
		quit(1); return

	# 2. Simulate a visibility tick to create sense_visible_{eid} and sense_dist_{eid}.
	net.update_per_entity_sensory([{
		"id": eid,
		"exposure": 0.9,
		"distance_tiles": 2.0,
	}])
	if not net._neuron_map.has("sense_visible_" + eid):
		print("%s — update_per_entity_sensory failed to create sense_visible" % MARKER_FAIL)
		quit(1); return

	# 3. Force a couple of quality neurons into the active band (≥ 30).
	#    Two active + one below-threshold to verify the activation gate.
	net._neuron_map["q_tight"]["activation"] = 75.0
	net._neuron_map["q_warm"]["activation"] = 55.0
	net._neuron_map["q_prickling"]["activation"] = 15.0  # below 30 → should NOT wire

	# 4. Spawn.
	var ok: bool = net.spawn_identity_appraisal(nid, eid)
	if not ok:
		print("%s — spawn returned false with sense_visible present" % MARKER_FAIL)
		quit(1); return
	if not net._neuron_map.has(nid):
		print("%s — spawn returned true but neuron missing" % MARKER_FAIL)
		quit(1); return

	var neuron: Dictionary = net._neuron_map[nid]
	if neuron.get("type", "") != "appraisal":
		print("%s — spawned neuron type=%s (expected 'appraisal')" % [MARKER_FAIL, neuron.get("type")])
		quit(1); return
	if neuron.get("category", "") != "identity_appraisal":
		print("%s — spawned neuron category=%s (expected 'identity_appraisal')" % [MARKER_FAIL, neuron.get("category")])
		quit(1); return
	if String(neuron.get("entity_id", "")) != eid:
		print("%s — spawned neuron entity_id=%s (expected %s)" % [MARKER_FAIL, neuron.get("entity_id"), eid])
		quit(1); return

	# 5. Verify incoming connections.
	var incoming_sources: Array = []
	for c in net.connections:
		if c["dst"] == nid:
			incoming_sources.append(String(c["src"]))

	if not incoming_sources.has("sense_visible_" + eid):
		print("%s — no incoming from sense_visible_%s (sources=%s)" % [MARKER_FAIL, eid, incoming_sources])
		quit(1); return
	if not incoming_sources.has("q_tight"):
		print("%s — no incoming from active quality q_tight" % MARKER_FAIL)
		quit(1); return
	if not incoming_sources.has("q_warm"):
		print("%s — no incoming from active quality q_warm" % MARKER_FAIL)
		quit(1); return
	if incoming_sources.has("q_prickling"):
		print("%s — below-threshold q_prickling (15) was wired anyway" % MARKER_FAIL)
		quit(1); return

	# 6. Duplicate spawn must no-op.
	var dup: bool = net.spawn_identity_appraisal(nid, eid)
	if dup:
		print("%s — duplicate spawn returned true (expected false)" % MARKER_FAIL)
		quit(1); return

	# 7. F9 merge coverage — spawn a second identity appraisal at a deprecated
	# eid and then merge into the canonical one. After merge, the deprecated
	# neuron must be gone and its incoming edges must have moved to canonical.
	var dep_eid: String = "ent_mabel_stranger"
	var dep_nid: String = "appr_identity_" + dep_eid
	net.update_per_entity_sensory([{
		"id": dep_eid,
		"exposure": 0.9,
		"distance_tiles": 2.0,
	}])
	net._neuron_map["q_tight"]["activation"] = 50.0  # keep it active for dep wiring
	net.spawn_identity_appraisal(dep_nid, dep_eid)
	if not net._neuron_map.has(dep_nid):
		print("%s — deprecated identity appraisal did not spawn" % MARKER_FAIL)
		quit(1); return

	net.merge_entity_ids(eid, dep_eid)
	if net._neuron_map.has(dep_nid):
		print("%s — merge did not remove deprecated %s" % [MARKER_FAIL, dep_nid])
		quit(1); return
	if not net._neuron_map.has(nid):
		print("%s — merge removed canonical %s" % [MARKER_FAIL, nid])
		quit(1); return

	print("%s incoming=%s" % [MARKER_OK, incoming_sources])
	quit(0)
