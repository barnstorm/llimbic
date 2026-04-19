extends SceneTree
## res://tests/test_reward_gate.gd — Phase 1 smoke test.
##
## Exercises the reward path end-to-end:
##   1. signal_reward("tag", magnitude) accumulates recent_reward_signal
##   2. decay_reward(dt) decays it within the configured time constant
##   3. hebbian_update applies the (1 + β · signal) modifier to Δw
##   4. drain_recent_reward_events returns + clears the per-tick buffer
##   5. drive crossings (low energy → high energy) emit reward_drive_satisfaction
##
## Usage:
##   godot --path /home/thermos/workspace/burg --headless --quit \
##         --script res://tests/test_reward_gate.gd
## Exit code 0 = pass, non-zero = fail.

const PASS := "TEST_REWARD_GATE: PASS"
const FAIL := "TEST_REWARD_GATE: FAIL"

func _init() -> void:
	var failures: int = 0

	# ----- Test 1: signal_reward + drain -----
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	if net.recent_reward_signal != 0.0:
		print("%s: initial signal != 0" % FAIL); quit(1); return

	net.signal_reward("reward_action_succeeded", 0.4)
	if not is_equal_approx(net.recent_reward_signal, 0.4):
		print("%s: after 0.4, signal=%f expected 0.4" % [FAIL, net.recent_reward_signal])
		quit(1); return

	net.signal_reward("reward_drive_satisfaction", 0.7)
	if not is_equal_approx(net.recent_reward_signal, 1.0):
		# 0.4 + 0.7 = 1.1, clamped to 1.0
		print("%s: after +0.7, signal=%f expected 1.0 (clamped)" % [FAIL, net.recent_reward_signal])
		quit(1); return

	var drained: Array = net.drain_recent_reward_events()
	if drained.size() != 2:
		print("%s: drained %d events, expected 2" % [FAIL, drained.size()])
		quit(1); return
	if drained[0]["tag"] != "reward_action_succeeded" or drained[1]["tag"] != "reward_drive_satisfaction":
		print("%s: tags wrong: %s" % [FAIL, drained])
		quit(1); return
	if not net.drain_recent_reward_events().is_empty():
		print("%s: drain didn't clear" % FAIL); quit(1); return
	print("  PASS  signal_reward + drain")

	# ----- Test 2: decay -----
	# After ~3 * tau (default tau=2s, so 6s), signal should be ≪ 0.1.
	# We fire dt steps of 0.5s × 12 = 6s.
	for _i in range(12):
		net.decay_reward(0.5)
	if net.recent_reward_signal > 0.1:
		print("%s: decay too slow, signal=%f after 6s" % [FAIL, net.recent_reward_signal])
		quit(1); return
	print("  PASS  decay (signal=%f after 6s)" % net.recent_reward_signal)

	# ----- Test 3: hebbian gate effect on Δw -----
	# Set up two pairs of co-active neurons. Apply hebbian_update once with no
	# reward and once with reward. Verify the rewarded weight grew faster.
	# We pick task_momentum and task_frustration — both already exist as
	# unprotected on the source side, so Hebbian touches them.
	var net_a: RefCounted = Net.new()
	net_a.setup_default_network({"drive_defaults": {}})
	var net_b: RefCounted = Net.new()
	net_b.setup_default_network({"drive_defaults": {}})

	# Force two unprotected neurons high so Hebbian picks the pair.
	# Pick action_approach (unprotected) and task_momentum (unprotected) and
	# wire them — then activate both above the threshold.
	for n in [net_a, net_b]:
		n._add_connection("task_momentum", "action_approach", 0.0)
		n._neuron_map["task_momentum"]["activation"] = 90.0
		n._neuron_map["action_approach"]["activation"] = 90.0
		# Bump ages so the new-neuron 2x rate doesn't fire.
		for nid in ["task_momentum", "action_approach"]:
			n._neuron_map[nid]["age"] = 1000

	net_b.signal_reward("test", 1.0)  # full reward gate

	net_a.hebbian_update(1.0)
	net_b.hebbian_update(1.0)

	var w_a: float = 0.0
	var w_b: float = 0.0
	for c in net_a.connections:
		if c["src"] == "task_momentum" and c["dst"] == "action_approach":
			w_a = c["weight"]
	for c in net_b.connections:
		if c["src"] == "task_momentum" and c["dst"] == "action_approach":
			w_b = c["weight"]

	if w_b <= w_a:
		print("%s: rewarded weight %f not greater than baseline %f" % [FAIL, w_b, w_a])
		quit(1); return
	# β=0.5 → reward_gate=1.5 → w_b should be ~1.5x w_a.
	var ratio: float = w_b / max(w_a, 1e-9)
	if ratio < 1.4 or ratio > 1.6:
		print("%s: gate ratio=%f, expected ~1.5 (β=0.5)" % [FAIL, ratio])
		quit(1); return
	print("  PASS  hebbian gate (w_a=%f w_b=%f ratio=%.3f)" % [w_a, w_b, ratio])

	# ----- Test 4: drive-crossing emits reward_drive_satisfaction -----
	# This requires layer1_substrate. Drive starts at urgent (e.g. hunger=80),
	# crosses below urgency threshold (70) → should emit reward.
	var L1: GDScript = load("res://scripts/layer1_substrate.gd")
	var l1: RefCounted = L1.new()
	l1.setup({"drive_defaults": {"hunger": 80.0}}, null)
	# Prime: first tick records initial level.
	l1._check_drive_crossings(0.1)
	# Drop hunger below threshold.
	l1.hunger = 50.0  # well below urgency 70
	l1._check_drive_crossings(0.1)
	var l1_drained: Array = l1.drain_recent_reward_events()
	var found_satisfaction: bool = false
	for ev in l1_drained:
		if ev["tag"] == "reward_drive_satisfaction":
			found_satisfaction = true
			break
	if not found_satisfaction:
		print("%s: no reward_drive_satisfaction emitted on hunger 80→50. Drained=%s" % [FAIL, l1_drained])
		quit(1); return
	print("  PASS  drive crossing emits reward_drive_satisfaction")

	if failures == 0:
		print("%s (4/4 sub-tests)" % PASS)
		quit(0)
	else:
		print("%s (%d failures)" % [FAIL, failures])
		quit(1)
