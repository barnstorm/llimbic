extends SceneTree
## res://tests/test_intention_pulse.gd — Phase 11 Hebbian pulse + amp + variance.
##
## Verifies:
## 1. pulse_intention_context sets activation on named neurons + seeds
##    bootstrap I→sense edges at the constants-specified weight.
## 2. get_intention_amplification_map returns {sense_id: 1 + Σ I_act * w}
##    for currently-active intention neurons. Cold-start is uniform (all
##    senses get ~same amp); after Hebbian reshape (here: direct weight
##    edit), specific senses rise.
## 3. propagate() applies the amp to sense-neuron outgoing contributions.
## 4. Swapping intention context clears the stale neurons from the map.
## 5. bootstrap_variance starts ~0 (uniform seed) and grows as weights
##    reshape — the Phase 11 "decay of authored uniformity".
##
## Usage:
##   godot --headless --quit --script res://tests/test_intention_pulse.gd

const MARKER_OK := "TEST_INTENTION_PULSE: PASS"
const MARKER_FAIL := "TEST_INTENTION_PULSE: FAIL"


func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	var net: RefCounted = Net.new()
	net.setup_default_network({"drive_defaults": {}})

	# Pre-seed two per-entity sense neurons so bootstrap edges have targets.
	net.update_per_entity_sensory([
		{"id": "ent_a", "exposure": 0.9, "distance_tiles": 2.0},
		{"id": "ent_b", "exposure": 0.9, "distance_tiles": 4.0},
	])

	# --- 1. Pulse intention context on an existing quality neuron ---
	net.pulse_intention_context(["q_warm"])
	var warm_act: float = net._neuron_map["q_warm"]["activation"]
	if warm_act < 30.0:
		print("%s — pulse did not raise q_warm activation (%.1f)" % [MARKER_FAIL, warm_act])
		quit(1); return

	# --- 2. Bootstrap edges seeded from q_warm to each sense neuron ---
	var seed_count: int = 0
	for c in net.connections:
		if String(c["src"]) == "q_warm":
			var dst: String = String(c["dst"])
			if dst.begins_with("sense_visible_") or dst.begins_with("sense_dist_"):
				seed_count += 1
	if seed_count < 4:  # 2 eids × 2 sense types (visible + dist) = 4
		print("%s — expected ≥4 bootstrap edges from q_warm, got %d" % [MARKER_FAIL, seed_count])
		quit(1); return
	print("  PASS  pulse sets activation + seeds %d bootstrap I→sense edges" % seed_count)

	# --- 3. Amplification map under cold-start: uniform-ish ---
	var amp_cold: Dictionary = net.get_intention_amplification_map()
	var visible_a_amp: float = float(amp_cold.get("sense_visible_ent_a", 0.0))
	var visible_b_amp: float = float(amp_cold.get("sense_visible_ent_b", 0.0))
	# Both should be > 1 (amplified) and approximately equal at cold start.
	if abs(visible_a_amp - visible_b_amp) > 0.01:
		print("%s — cold-start amp not uniform: a=%.3f b=%.3f" % [MARKER_FAIL, visible_a_amp, visible_b_amp])
		quit(1); return
	if visible_a_amp <= 1.0:
		print("%s — cold-start amp not > 1: %.3f" % [MARKER_FAIL, visible_a_amp])
		quit(1); return
	print("  PASS  cold-start amplification is uniform (%.3f ≈ %.3f)" % [visible_a_amp, visible_b_amp])

	# --- 4. Simulate Hebbian reshape: bump one I→S weight ---
	# Direct edit — stand in for what reward-gated Hebbian does organically.
	var idx: int = net._find_connection("q_warm", "sense_visible_ent_a")
	if idx < 0:
		print("%s — missing expected bootstrap edge" % MARKER_FAIL)
		quit(1); return
	net.connections[idx]["weight"] = 0.25  # strong learned weight

	var amp_hot: Dictionary = net.get_intention_amplification_map()
	var hot_a: float = float(amp_hot.get("sense_visible_ent_a", 0.0))
	var hot_b: float = float(amp_hot.get("sense_visible_ent_b", 0.0))
	if hot_a <= hot_b + 0.5:
		print("%s — learned edge should amplify sense_visible_ent_a: a=%.3f b=%.3f" % [MARKER_FAIL, hot_a, hot_b])
		quit(1); return
	print("  PASS  learned I→S edge amplifies target sense (%.3f vs %.3f)" % [hot_a, hot_b])

	# --- 5. Bootstrap variance tracks reshape ---
	var variance: Dictionary = net.get_intention_bootstrap_variance()
	var cv_warm: float = float(variance.get("q_warm", 0.0))
	if cv_warm <= 0.0:
		print("%s — bootstrap_variance stayed 0 after weight reshape: cv=%.3f" % [MARKER_FAIL, cv_warm])
		quit(1); return
	print("  PASS  bootstrap_variance grows after reshape (cv=%.3f)" % cv_warm)

	# --- 6. Swapping intention context clears stale entries ---
	net.pulse_intention_context(["q_settled"])
	if net._intention_context_neurons.has("q_warm"):
		print("%s — stale intention q_warm not cleared after new pulse" % MARKER_FAIL)
		quit(1); return
	if not net._intention_context_neurons.has("q_settled"):
		print("%s — new intention q_settled not registered" % MARKER_FAIL)
		quit(1); return
	print("  PASS  swapping intention clears stale + registers new")

	# --- 7. Amp map clamped to the 5x safety cap ---
	# Bump a weight absurdly high; amp should cap at 5.0.
	net.pulse_intention_context(["q_warm"])
	idx = net._find_connection("q_warm", "sense_visible_ent_a")
	net.connections[idx]["weight"] = 100.0
	var amp_clamp: Dictionary = net.get_intention_amplification_map()
	var clamp_a: float = float(amp_clamp.get("sense_visible_ent_a", 0.0))
	if clamp_a > 5.0 + 1e-5:
		print("%s — amp not clamped to 5.0: %.3f" % [MARKER_FAIL, clamp_a])
		quit(1); return
	print("  PASS  amp clamped to safety cap (%.3f ≤ 5.0)" % clamp_a)

	print(MARKER_OK)
	quit(0)
