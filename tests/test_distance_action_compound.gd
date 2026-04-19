extends SceneTree
## res://tests/test_distance_action_compound.gd — Phase 4 acceptance.
##
## Verifies spec §5.1 distance-action compound emergence:
##   1. signal_action_success creates the transient action_success_{verb}
##      neuron at activation 50.
##   2. The neuron decays to ~0 within ACTION_SUCCESS_DECAY_SECONDS.
##   3. Two distinct verbs at distinct distance bands → two q_*able compound
##      neurons with distinct receptive_centers.
##   4. update_qable_activations samples sense_dist_* and fires the compound
##      when an entity is in the receptive band; doesn't fire otherwise.
##   5. F9 invariant: receptive fields are per-verb, not per-target — the
##      compound generalizes across entities at similar distances.
##
## Usage:
##   godot --path /home/thermos/workspace/burg --headless --quit \
##         --script res://tests/test_distance_action_compound.gd

const PASS := "TEST_DISTANCE_ACTION_COMPOUND: PASS"
const FAIL := "TEST_DISTANCE_ACTION_COMPOUND: FAIL"

func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	var ent_close: String = "ent_close_aaaa"
	var ent_far: String = "ent_far_bbbb"

	# Make the two entities visible at characteristic distances.
	# touch successes at ~0.5 tiles, approach successes at ~5 tiles.
	net.update_per_entity_sensory([
		{"id": ent_close, "exposure": 1.0, "distance_tiles": 0.5},
		{"id": ent_far,   "exposure": 1.0, "distance_tiles": 5.0},
	])

	# ----- Test 1: action_success neuron spawns at activation 50 -----
	net.signal_action_success("touch", ent_close)
	var sn: Dictionary = net._neuron_map.get("action_success_touch", {})
	if sn.is_empty():
		print("%s: action_success_touch not spawned" % FAIL); quit(1); return
	if not is_equal_approx(float(sn["activation"]), 50.0):
		print("%s: action_success_touch activation=%f expected 50" % [FAIL, sn["activation"]])
		quit(1); return
	print("  PASS  action_success_touch spawned (act=%f)" % sn["activation"])

	# ----- Test 2: decay within ~2s -----
	for _i in range(20):
		net.propagate(0.1)  # 20 × 0.1s = 2.0s total
	var act_after: float = float(net._neuron_map["action_success_touch"]["activation"])
	if act_after > 1.0:
		print("%s: action_success decayed too slowly (=%f after 2s, expected ~0)" %
			[FAIL, act_after])
		quit(1); return
	print("  PASS  decay over 2s (act=%f)" % act_after)

	# ----- Test 3: build distance history → compound spawn -----
	# 10 touch successes at ~0.5 tiles (close).
	for i in range(10):
		net.update_per_entity_sensory([{"id": ent_close, "exposure": 1.0, "distance_tiles": 0.5 + (i % 2) * 0.1}])
		net.signal_action_success("touch", ent_close)
	# 10 approach successes at ~5 tiles (mid-range).
	for i in range(10):
		net.update_per_entity_sensory([{"id": ent_far, "exposure": 1.0, "distance_tiles": 5.0 + (i % 2) * 0.2}])
		net.signal_action_success("approach", ent_far)

	# Trigger neurogenesis pass.
	var spawned1: bool = net.check_distance_action_neurogenesis()
	var spawned2: bool = net.check_distance_action_neurogenesis()
	if not (spawned1 or spawned2):
		print("%s: no compound spawned after 2×10 successes" % FAIL); quit(1); return

	var qt: Dictionary = net._neuron_map.get("q_touchable", {})
	var qa: Dictionary = net._neuron_map.get("q_approachable", {})
	if qt.is_empty() or qa.is_empty():
		print("%s: missing compound — q_touchable=%s q_approachable=%s" % [FAIL, qt, qa])
		quit(1); return
	var ct: float = float(qt["receptive_center"])
	var ca: float = float(qa["receptive_center"])
	if abs(ct - 0.55) > 0.5:
		print("%s: q_touchable center=%.2f expected ~0.55" % [FAIL, ct]); quit(1); return
	if abs(ca - 5.1) > 0.5:
		print("%s: q_approachable center=%.2f expected ~5.1" % [FAIL, ca]); quit(1); return
	if abs(ct - ca) < 2.0:
		print("%s: receptive centers too close: %.2f vs %.2f" % [FAIL, ct, ca]); quit(1); return
	print("  PASS  spawned q_touchable@%.2f and q_approachable@%.2f (Δ=%.2f)" %
		[ct, ca, abs(ct - ca)])

	# ----- Test 4: receptive-field activation -----
	# Mark ent_close + ent_far out-of-vision (exposure=0, distance huge) so the
	# only visible entity is the one we're probing with. update_qable_activations
	# filters out near-zero sense_dist activations (act < 1.0).
	for stale in [ent_close, ent_far]:
		net.update_per_entity_sensory([{"id": stale, "exposure": 0.0, "distance_tiles": 10000.0}])

	# Probe entity at 0.5 tiles → q_touchable should fire ~100, q_approachable ~low.
	var probe: String = "ent_probe_dddd"
	net.update_per_entity_sensory([{"id": probe, "exposure": 1.0, "distance_tiles": 0.5}])
	# Re-zero the stale entities (their previous fakes are now in the registry too).
	for stale in [ent_close, ent_far]:
		net.update_per_entity_sensory([{"id": stale, "exposure": 0.0, "distance_tiles": 10000.0}])
	net.update_qable_activations()
	var qt_act_close: float = float(net._neuron_map["q_touchable"]["activation"])
	var qa_act_close: float = float(net._neuron_map["q_approachable"]["activation"])
	if qt_act_close < 80.0:
		print("%s: q_touchable should fire ≥80 at 0.5t (got %.2f)" % [FAIL, qt_act_close])
		quit(1); return
	if qa_act_close > 30.0:
		print("%s: q_approachable should be quiet at 0.5t (got %.2f)" % [FAIL, qa_act_close])
		quit(1); return

	# Move probe entity to 5 tiles → q_approachable should dominate.
	net.update_per_entity_sensory([{"id": probe, "exposure": 1.0, "distance_tiles": 5.0}])
	for stale in [ent_close, ent_far]:
		net.update_per_entity_sensory([{"id": stale, "exposure": 0.0, "distance_tiles": 10000.0}])
	net.update_qable_activations()
	var qt_act_far: float = float(net._neuron_map["q_touchable"]["activation"])
	var qa_act_far: float = float(net._neuron_map["q_approachable"]["activation"])
	if qa_act_far < 80.0:
		print("%s: q_approachable should fire ≥80 at 5t (got %.2f)" % [FAIL, qa_act_far])
		quit(1); return
	if qt_act_far > 30.0:
		print("%s: q_touchable should be quiet at 5t (got %.2f)" % [FAIL, qt_act_far])
		quit(1); return
	print("  PASS  receptive-field firing: t@close(%.0f) t@far(%.0f) a@close(%.0f) a@far(%.0f)" %
		[qt_act_close, qt_act_far, qa_act_close, qa_act_far])

	# ----- Test 5: per-verb generalization (not per-target) -----
	# A different entity at touch-distance should also drive q_touchable —
	# proving the compound generalizes the verb, not memorizes the target.
	var new_ent: String = "ent_new_cccc"
	net.update_per_entity_sensory([{"id": new_ent, "exposure": 1.0, "distance_tiles": 0.5}])
	for stale in [ent_close, ent_far, probe]:
		net.update_per_entity_sensory([{"id": stale, "exposure": 0.0, "distance_tiles": 10000.0}])
	net.update_qable_activations()
	var qt_new: float = float(net._neuron_map["q_touchable"]["activation"])
	if qt_new < 80.0:
		print("%s: q_touchable did not generalize to new entity (act=%.2f)" % [FAIL, qt_new])
		quit(1); return
	print("  PASS  generalization: q_touchable fires on new entity at 0.5t (act=%.2f)" % qt_new)

	print("%s (5/5 sub-tests)" % PASS)
	quit(0)
