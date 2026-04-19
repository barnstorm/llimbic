extends SceneTree
## res://tests/test_appraisal_spawn.gd — Phase 0.0 smoke test.
##
## Exercises check_appraisal_neurogenesis() in hebbian_network.gd:
## 1. Force three quality neurons above threshold.
## 2. Tick check_appraisal_neurogenesis with simulated dt totaling > sustained_sec.
## 3. Verify a new appraisal neuron exists and was published via drain.
## 4. Verify embedding_seed contains the expected concept tags + activations.
##
## Usage:
##   godot --headless --quit --script res://tests/test_appraisal_spawn.gd
## Exit code 0 = pass, non-zero = fail.

const MARKER_OK := "TEST_APPRAISAL_SPAWN: PASS"
const MARKER_FAIL := "TEST_APPRAISAL_SPAWN: FAIL"

func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	if Net == null:
		print("%s — could not load hebbian_network.gd" % MARKER_FAIL)
		quit(1); return
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	# Force three quality neurons high enough to count as a constellation.
	# Threshold default = 50; push to 80 to be unambiguous.
	for qid in ["q_tight", "q_pounding", "q_prickling"]:
		var idx_dict: Dictionary = net._neuron_map.get(qid, {})
		if idx_dict.is_empty():
			print("%s — quality neuron %s not seeded" % [MARKER_FAIL, qid])
			quit(1); return
		idx_dict["activation"] = 80.0

	# First call: kicks off the constellation tracker (dt is initially 0
	# because _last_appraisal_check_tick == 0). It should register the
	# constellation but not spawn yet.
	var spawned_first: bool = net.check_appraisal_neurogenesis()
	if spawned_first:
		print("%s — spawned on first call (no dt accumulated yet)" % MARKER_FAIL)
		quit(1); return

	# Subsequent calls accumulate dt. We can't easily fake Time.get_ticks_msec,
	# so we wait. 7 seconds of wall-clock should overshoot 6.0s sustained_sec.
	# (Quality activations stay pinned to 80; Hebbian propagation hasn't run.)
	var t_start: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_start < 7000:
		# Re-pin activations every tick so the constellation stays valid.
		for qid in ["q_tight", "q_pounding", "q_prickling"]:
			net._neuron_map[qid]["activation"] = 80.0
		net.check_appraisal_neurogenesis()
		# Brief yield so we don't busy-spin too tight.
		OS.delay_msec(50)

	# Verify spawn occurred.
	var appraisal_count: int = 0
	var spawned_id: String = ""
	var spawned_neuron: Dictionary = {}
	for n in net.neurons:
		if n["type"] == "appraisal":
			appraisal_count += 1
			spawned_id = n["id"]
			spawned_neuron = n

	if appraisal_count == 0:
		print("%s — no appraisal neuron spawned after 7s sustained" % MARKER_FAIL)
		quit(1); return

	if spawned_neuron.get("embedding_seed", {}).is_empty():
		print("%s — spawned neuron has empty embedding_seed" % MARKER_FAIL)
		quit(1); return

	# Verify embedding_seed has the expected concept tags.
	var seed: Dictionary = spawned_neuron["embedding_seed"]
	for expected_tag in ["tight", "pounding", "prickling"]:
		if not seed.has(expected_tag):
			print("%s — embedding_seed missing tag '%s'. Seed=%s" % [
				MARKER_FAIL, expected_tag, seed
			])
			quit(1); return

	# Verify the snapshot drain returns the new neuron, then is empty.
	var drained: Array = net.drain_new_appraisal_neurons()
	if drained.is_empty():
		print("%s — drain_new_appraisal_neurons returned empty after spawn" % MARKER_FAIL)
		quit(1); return
	var drained_again: Array = net.drain_new_appraisal_neurons()
	if not drained_again.is_empty():
		print("%s — drain didn't clear: still has %d entries" % [MARKER_FAIL, drained_again.size()])
		quit(1); return

	# Verify the spawned neuron has parent connections.
	var parent_conns: int = 0
	for c in net.connections:
		if c["dst"] == spawned_id and c["src"] in ["q_tight", "q_pounding", "q_prickling"]:
			parent_conns += 1
	if parent_conns < 3:
		print("%s — only %d parent connections wired (expected 3)" % [MARKER_FAIL, parent_conns])
		quit(1); return

	print("%s appraisal_id=%s parents=%s seed_keys=%s" % [
		MARKER_OK, spawned_id, spawned_neuron.get("parent_qualities", []), seed.keys()
	])
	quit(0)
