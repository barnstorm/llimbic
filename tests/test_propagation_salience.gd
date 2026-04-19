extends SceneTree
## res://tests/test_propagation_salience.gd — Phase 6 GDScript-side salience test.
##
## Verifies:
## 1. get_outgoing_weight_sum returns the sum of |weight| over all connections
##    whose src matches the neuron_id.
## 2. get_perception_salience produces {eid: sum} keyed on sense_visible_{eid}.
## 3. An eid with no sense_visible neuron maps to 0.0 (cold-start case).
## 4. Two networks with different learned weights on sense_visible_{eid} produce
##    different salience — the ranking individuation mechanism Phase 6 relies on.
##
## Usage:
##   godot --headless --quit --script res://tests/test_propagation_salience.gd

const MARKER_OK := "TEST_PROPAGATION_SALIENCE: PASS"
const MARKER_FAIL := "TEST_PROPAGATION_SALIENCE: FAIL"

func _init() -> void:
	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	if Net == null:
		print("%s — could not load hebbian_network.gd" % MARKER_FAIL)
		quit(1); return

	var netA: RefCounted = Net.new()
	netA.setup_default_network({"drive_defaults": {}})

	# --- Seed two entities' sense_visible neurons ---
	netA.update_per_entity_sensory([
		{"id": "ent_alpha", "exposure": 0.9, "distance_tiles": 2.0},
		{"id": "ent_beta",  "exposure": 0.9, "distance_tiles": 4.0},
	])

	if not netA._neuron_map.has("sense_visible_ent_alpha"):
		print("%s — sense_visible_ent_alpha not spawned" % MARKER_FAIL); quit(1); return

	# 1. Both sense neurons have zero outgoing at spawn (cold start).
	var s0_alpha: float = netA.get_outgoing_weight_sum("sense_visible_ent_alpha")
	var s0_beta: float = netA.get_outgoing_weight_sum("sense_visible_ent_beta")
	if s0_alpha != 0.0 or s0_beta != 0.0:
		print("%s — expected 0 outgoing at spawn, got alpha=%f beta=%f" % [MARKER_FAIL, s0_alpha, s0_beta])
		quit(1); return

	# 2. Manually seed outgoing weights to simulate Hebbian learning.
	# Alpha strongly connects to q_tight and q_pounding (strong attention).
	# Beta weakly connects to q_settled (quieter attention).
	netA._add_connection("sense_visible_ent_alpha", "q_tight", 0.30)
	netA._add_connection("sense_visible_ent_alpha", "q_pounding", 0.20)
	netA._add_connection("sense_visible_ent_alpha", "action_flee", -0.15)  # negative still counts
	netA._add_connection("sense_visible_ent_beta", "q_settled", 0.05)

	var s1_alpha: float = netA.get_outgoing_weight_sum("sense_visible_ent_alpha")
	var s1_beta: float = netA.get_outgoing_weight_sum("sense_visible_ent_beta")
	# 0.30 + 0.20 + 0.15 = 0.65 (abs) for alpha, 0.05 for beta.
	if abs(s1_alpha - 0.65) > 1e-5:
		print("%s — alpha outgoing sum expected 0.65, got %f" % [MARKER_FAIL, s1_alpha])
		quit(1); return
	if abs(s1_beta - 0.05) > 1e-5:
		print("%s — beta outgoing sum expected 0.05, got %f" % [MARKER_FAIL, s1_beta])
		quit(1); return
	print("  PASS  |w| sum correct (alpha=%.3f beta=%.3f)" % [s1_alpha, s1_beta])

	# 3. get_perception_salience returns the map, including 0.0 for an
	# unknown eid.
	var sal: Dictionary = netA.get_perception_salience(["ent_alpha", "ent_beta", "ent_nobody"])
	if abs(sal["ent_alpha"] - 0.65) > 1e-5:
		print("%s — sal map alpha=%f" % [MARKER_FAIL, sal["ent_alpha"]]); quit(1); return
	if abs(sal["ent_beta"] - 0.05) > 1e-5:
		print("%s — sal map beta=%f" % [MARKER_FAIL, sal["ent_beta"]]); quit(1); return
	if sal.get("ent_nobody", -1.0) != 0.0:
		print("%s — unknown eid should map to 0.0, got %s" % [MARKER_FAIL, sal.get("ent_nobody")])
		quit(1); return
	print("  PASS  perception_salience map shape correct (unknowns → 0.0)")

	# 4. A second network with DIFFERENT learned weights on the same eids
	# produces DIFFERENT salience — this is the individuation mechanism.
	var netB: RefCounted = Net.new()
	netB.setup_default_network({"drive_defaults": {}})
	netB.update_per_entity_sensory([
		{"id": "ent_alpha", "exposure": 0.9, "distance_tiles": 2.0},
		{"id": "ent_beta",  "exposure": 0.9, "distance_tiles": 4.0},
	])
	# Beta dominates B's attention; alpha is quiet.
	netB._add_connection("sense_visible_ent_alpha", "q_settled", 0.03)
	netB._add_connection("sense_visible_ent_beta", "q_tight", 0.40)
	netB._add_connection("sense_visible_ent_beta", "q_pounding", 0.25)

	var salB: Dictionary = netB.get_perception_salience(["ent_alpha", "ent_beta"])

	# Verify rankings are opposite between A and B.
	var a_prefers_alpha: bool = float(sal["ent_alpha"]) > float(sal["ent_beta"])
	var b_prefers_alpha: bool = float(salB["ent_alpha"]) > float(salB["ent_beta"])
	if a_prefers_alpha == b_prefers_alpha:
		print("%s — two networks produced SAME attention preference (A=%s B=%s)" % [
			MARKER_FAIL, sal, salB
		])
		quit(1); return
	print("  PASS  two networks produce divergent salience (A=%s B=%s)" % [sal, salB])

	print(MARKER_OK)
	quit(0)
