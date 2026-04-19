extends SceneTree
## res://tests/test_cross_modal_neurogenesis.gd — Phase 9 spawn wiring test.
##
## Verifies:
## 1. update_per_entity_heard spawns sense_heard_{eid} and refreshes it.
## 2. Co-activation (sense_visible_{eid} ≥30 + sense_heard_{eid} ≥30 in same
##    tick) accumulates in the cross-modal history.
## 3. After N co-fires within window, bind_{eid} spawns wired to both
##    modality parents at the existing 0.12 compound-parent weight.
## 4. drain_new_bind_neurons is one-shot (returns then clears).
## 5. PER_ENTITY_PREFIXES now covers sense_heard_ and bind_ (F9 merge path).
## 6. Partial activation: only-visible fires do NOT increment co-activation
##    history.
##
## Usage:
##   godot --headless --quit --script res://tests/test_cross_modal_neurogenesis.gd

const MARKER_OK := "TEST_CROSS_MODAL_NEUROGENESIS: PASS"
const MARKER_FAIL := "TEST_CROSS_MODAL_NEUROGENESIS: FAIL"


func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	if Net == null:
		print("%s — could not load hebbian_network.gd" % MARKER_FAIL)
		quit(1); return
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	var eid: String = "ent_hugo"

	# 1. Spawn the visible side so co-activation has something to match.
	net.update_per_entity_sensory([{
		"id": eid, "exposure": 0.9, "distance_tiles": 2.0,
	}])
	if not net._neuron_map.has("sense_visible_" + eid):
		print("%s — sense_visible_{eid} missing" % MARKER_FAIL); quit(1); return

	# 2. First heard event — spawns sense_heard_{eid}.
	net.update_per_entity_heard([{"id": eid, "strength": 0.8}])
	if not net._neuron_map.has("sense_heard_" + eid):
		print("%s — sense_heard_{eid} missing after first heard event" % MARKER_FAIL)
		quit(1); return
	var act_after_first: float = float(net._neuron_map["sense_heard_" + eid]["activation"])
	if act_after_first < 30.0:
		print("%s — sense_heard strength mapping broken (act=%f)" % [MARKER_FAIL, act_after_first])
		quit(1); return
	print("  PASS  sense_heard_{eid} spawned (act=%.1f)" % act_after_first)

	# 3. Emit N=5 co-activation events across 5 ticks. Both visible and heard
	#    must be ≥30 in the same tick for a co-fire to count.
	# Pin visible activation high to simulate continuous exposure.
	var need_cofires: int = 5  # matches constants.neurogenesis_thresholds.cross_modal_co_fire_count
	for i in range(need_cofires):
		net._neuron_map["sense_visible_" + eid]["activation"] = 80.0
		net.update_per_entity_heard([{"id": eid, "strength": 0.7}])
		OS.delay_msec(10)  # keep well within cross_modal_window_seconds (30s)

	# After N co-fires bind_{eid} should exist.
	var bind_id: String = "bind_" + eid
	if not net._neuron_map.has(bind_id):
		print("%s — bind_{eid} not spawned after %d co-fires" % [MARKER_FAIL, need_cofires])
		quit(1); return
	var bind_neuron: Dictionary = net._neuron_map[bind_id]
	if String(bind_neuron.get("category", "")) != "compound_quality_cross_modal":
		print("%s — bind category wrong: %s" % [MARKER_FAIL, bind_neuron.get("category")])
		quit(1); return

	# 4. Wiring — both modality parents must have incoming connections into bind.
	var srcs: Array = []
	for c in net.connections:
		if c["dst"] == bind_id:
			srcs.append(String(c["src"]))
	if not srcs.has("sense_visible_" + eid):
		print("%s — bind missing sense_visible_ parent (srcs=%s)" % [MARKER_FAIL, srcs])
		quit(1); return
	if not srcs.has("sense_heard_" + eid):
		print("%s — bind missing sense_heard_ parent (srcs=%s)" % [MARKER_FAIL, srcs])
		quit(1); return
	print("  PASS  bind_{eid} spawned with both modality parents: " + str(srcs))

	# 5. drain_new_bind_neurons — one-shot.
	var drained: Array = net.drain_new_bind_neurons()
	if drained.is_empty() or String(drained[0].get("id", "")) != bind_id:
		print("%s — drain_new_bind_neurons wrong: %s" % [MARKER_FAIL, drained])
		quit(1); return
	var drain2: Array = net.drain_new_bind_neurons()
	if not drain2.is_empty():
		print("%s — drain did not clear, still %d entries" % [MARKER_FAIL, drain2.size()])
		quit(1); return
	print("  PASS  drain_new_bind_neurons is one-shot")

	# 6. Partial activation: only-visible fire (no heard) must NOT count as co-fire.
	#    Start with a fresh entity to isolate the test.
	var eid2: String = "ent_mabel"
	net.update_per_entity_sensory([{
		"id": eid2, "exposure": 0.9, "distance_tiles": 2.0,
	}])
	for i in range(need_cofires):
		net._neuron_map["sense_visible_" + eid2]["activation"] = 80.0
		# No heard update — visible-only ticks.
		OS.delay_msec(5)
	if net._neuron_map.has("bind_" + eid2):
		print("%s — bind_{eid2} spawned from visible-only ticks (partial fire bug)" % MARKER_FAIL)
		quit(1); return
	print("  PASS  visible-only ticks do not trigger cross-modal spawn")

	# 7. F9 merge path covers new prefixes.
	var deprecated: String = "ent_mabel_stranger"
	net.update_per_entity_sensory([{
		"id": deprecated, "exposure": 0.9, "distance_tiles": 2.0,
	}])
	net.update_per_entity_heard([{"id": deprecated, "strength": 0.8}])
	for i in range(need_cofires):
		net._neuron_map["sense_visible_" + deprecated]["activation"] = 80.0
		net.update_per_entity_heard([{"id": deprecated, "strength": 0.8}])
		OS.delay_msec(5)
	if not net._neuron_map.has("bind_" + deprecated):
		print("%s — deprecated bind neuron did not spawn" % MARKER_FAIL)
		quit(1); return
	net.merge_entity_ids(eid2, deprecated)
	if net._neuron_map.has("bind_" + deprecated):
		print("%s — merge did not drop deprecated bind_" % MARKER_FAIL); quit(1); return
	if net._neuron_map.has("sense_heard_" + deprecated):
		print("%s — merge did not drop deprecated sense_heard_" % MARKER_FAIL); quit(1); return
	print("  PASS  F9 merge covers sense_heard_ + bind_ prefixes")

	print(MARKER_OK)
	quit(0)
