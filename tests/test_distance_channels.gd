extends SceneTree
## res://tests/test_distance_channels.gd — Phase 3 acceptance.
##
## Verifies continuous distance + rate + dwell channels per spec §6.5:
##   1. sense_dist activation tracks 100·exp(-dist/TAU). At dist=0 → 100,
##      dist=TAU → ~37, dist=4·TAU → ~2. NO bucketing.
##   2. rate channel = activation - prev_activation (per tick).
##   3. dwell channel rises smoothly (EMA), starts at activation, drifts toward
##      sustained values.
##   4. get_per_entity_channels() returns {visible, dist, rate_*, dwell_*}.
##   5. F9 merge: sense_dist_* family also merges (not just sense_visible_*).
##   6. GC: removes both sense_visible_* AND sense_dist_* for an idle entity.
##
## Usage:
##   godot --path /home/thermos/workspace/burg --headless --quit \
##         --script res://tests/test_distance_channels.gd

const PASS := "TEST_DISTANCE_CHANNELS: PASS"
const FAIL := "TEST_DISTANCE_CHANNELS: FAIL"

func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	var eid: String = "ent_test_aaaaaaaa"

	# ----- Test 1: distance falloff is continuous -----
	# TAU=4 (default). Probe activation at several distances.
	var samples: Array = []
	for dist_tiles in [0.0, 2.0, 4.0, 8.0, 16.0]:
		net.update_per_entity_sensory([{"id": eid, "exposure": 1.0, "distance_tiles": dist_tiles}])
		var n: Dictionary = net._neuron_map.get("sense_dist_" + eid, {})
		samples.append(n.get("activation", -1.0))

	# Expected (TAU=4): 100, ~60.6, ~36.8, ~13.5, ~1.83
	var expected: Array = [100.0, 60.65, 36.79, 13.53, 1.83]
	for i in range(samples.size()):
		var measured: float = float(samples[i])
		var want: float = float(expected[i])
		if abs(measured - want) > 1.0:
			print("%s: dist falloff sample[%d]=%.2f expected ~%.2f" % [FAIL, i, measured, want])
			quit(1); return
	print("  PASS  continuous falloff: %s" % str(samples))

	# Verify NO bucketing: 4 tiles vs 4.5 tiles must give different activations.
	net.update_per_entity_sensory([{"id": eid, "exposure": 1.0, "distance_tiles": 4.0}])
	var a4: float = float(net._neuron_map["sense_dist_" + eid]["activation"])
	net.update_per_entity_sensory([{"id": eid, "exposure": 1.0, "distance_tiles": 4.5}])
	var a45: float = float(net._neuron_map["sense_dist_" + eid]["activation"])
	if abs(a4 - a45) < 0.5:
		print("%s: bucketing detected — 4t and 4.5t give nearly equal activations (%f vs %f)" %
			[FAIL, a4, a45])
		quit(1); return
	print("  PASS  no bucketing (4t=%.2f, 4.5t=%.2f, Δ=%.2f)" % [a4, a45, a4 - a45])

	# ----- Test 2: rate channel responds to changes -----
	net = Net.new()
	net.setup_default_network({"drive_defaults": {}})
	net.update_per_entity_sensory([{"id": eid, "exposure": 1.0, "distance_tiles": 8.0}])  # ~13.5
	# Then jump much closer.
	net.update_per_entity_sensory([{"id": eid, "exposure": 1.0, "distance_tiles": 0.0}])  # 100
	var n_dist: Dictionary = net._neuron_map["sense_dist_" + eid]
	var rate: float = float(n_dist.get("rate", 0.0))
	if rate < 50.0:
		print("%s: rate after 8t→0t jump = %.2f, expected > 50" % [FAIL, rate]); quit(1); return
	print("  PASS  rate tracks transition (rate=%.2f after 8t→0t)" % rate)

	# Now hold steady — rate should fall to zero on the next update.
	net.update_per_entity_sensory([{"id": eid, "exposure": 1.0, "distance_tiles": 0.0}])
	rate = float(net._neuron_map["sense_dist_" + eid].get("rate", 99.0))
	if abs(rate) > 0.1:
		print("%s: rate held at 0t = %.4f, expected ~0" % [FAIL, rate]); quit(1); return
	print("  PASS  rate→0 when activation steady (rate=%.4f)" % rate)

	# ----- Test 3: dwell channel smooths over time -----
	net = Net.new()
	net.setup_default_network({"drive_defaults": {}})
	# First tick at activation 100 (dist=0). Dwell starts at 100.
	net.update_per_entity_sensory([{"id": eid, "exposure": 1.0, "distance_tiles": 0.0}])
	var d_initial: float = float(net._neuron_map["sense_dist_" + eid].get("dwell", -1.0))
	if not is_equal_approx(d_initial, 100.0):
		print("%s: initial dwell=%.4f expected 100" % [FAIL, d_initial]); quit(1); return
	# Then drop activation to 0. Over many ticks, dwell decays toward 0.
	for _i in range(40):
		net.update_per_entity_sensory([{"id": eid, "exposure": 0.0, "distance_tiles": 1000.0}])
	var d_after: float = float(net._neuron_map["sense_dist_" + eid].get("dwell", 99.0))
	if d_after >= d_initial:
		print("%s: dwell after 40 low-act ticks = %.4f, expected < %.4f" %
			[FAIL, d_after, d_initial])
		quit(1); return
	if d_after < 1.0:
		print("%s: dwell decayed too fast (=%f); EMA α likely too aggressive" % [FAIL, d_after])
		quit(1); return
	print("  PASS  dwell EMA decays smoothly (100 → %.2f after 40 ticks)" % d_after)

	# ----- Test 4: get_per_entity_channels returns the new fields -----
	net.update_per_entity_sensory([{"id": eid, "exposure": 0.5, "distance_tiles": 4.0}])
	var ch: Dictionary = net.get_per_entity_channels()
	if not ch.has(eid):
		print("%s: channels dict missing entity %s" % [FAIL, eid]); quit(1); return
	var fields: Array = ["visible", "dist", "rate_visible", "rate_dist", "dwell_visible", "dwell_dist"]
	for f in fields:
		if not ch[eid].has(f):
			print("%s: channels[%s] missing field %s" % [FAIL, eid, f]); quit(1); return
	print("  PASS  channels accessor: %s" % str(ch[eid]))

	# ----- Test 5: F9 merge handles sense_dist_* too -----
	net = Net.new()
	net.setup_default_network({"drive_defaults": {}})
	net.update_per_entity_sensory([
		{"id": "ent_canon", "exposure": 1.0, "distance_tiles": 0.0},
		{"id": "ent_dep",   "exposure": 0.5, "distance_tiles": 4.0},
	])
	# Wire each sense_dist to action_observe with distinct weights.
	net._add_connection("sense_dist_ent_canon", "action_observe", 0.10)
	net._add_connection("sense_dist_ent_dep",   "action_observe", 0.05)
	var merged: bool = net.merge_entity_ids("ent_canon", "ent_dep")
	if not merged:
		print("%s: merge returned false" % FAIL); quit(1); return
	if net._neuron_map.has("sense_dist_ent_dep"):
		print("%s: sense_dist of deprecated id survived merge" % FAIL); quit(1); return
	if net._neuron_map.has("sense_visible_ent_dep"):
		print("%s: sense_visible of deprecated id survived merge" % FAIL); quit(1); return
	var dist_w: float = 0.0
	for c in net.connections:
		if c["src"] == "sense_dist_ent_canon" and c["dst"] == "action_observe":
			dist_w = c["weight"]
	if not is_equal_approx(dist_w, 0.15):
		print("%s: post-merge sense_dist→observe weight=%.3f expected 0.15" % [FAIL, dist_w])
		quit(1); return
	print("  PASS  merge handles sense_dist_* family (weight=%.3f)" % dist_w)

	# ----- Test 6: GC removes both families together -----
	net._per_entity_trackers["ent_canon"]["last_fire_tick"] = (
		int(net._per_entity_trackers["ent_canon"]["last_fire_tick"]) - 3600 * 1000
	)
	var removed: int = net.gc_per_entity_sensory()
	if removed != 2:
		print("%s: GC removed %d, expected 2 (visible + dist)" % [FAIL, removed]); quit(1); return
	if net._neuron_map.has("sense_visible_ent_canon") or net._neuron_map.has("sense_dist_ent_canon"):
		print("%s: post-GC family still present" % FAIL); quit(1); return
	print("  PASS  GC removes both sense_visible_* and sense_dist_* (removed=%d)" % removed)

	print("%s (6/6 sub-tests)" % PASS)
	quit(0)
