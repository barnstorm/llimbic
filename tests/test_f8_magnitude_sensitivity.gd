extends SceneTree
## res://tests/test_f8_magnitude_sensitivity.gd — F8 gate, Phase 1 scope.
##
## Per docs/perception_implementation_plan.md (F8): if doubling reward
## magnitudes shifts behavior more than 5–15%, magnitudes are bypassing
## reward-gating's normalization (clamping + decay). The plan's full version
## measures verb-distribution KL after 10 simulated minutes — that requires
## the accelerated simulator (also Phase 1.5 in the plan) which isn't built
## yet. This phase-1 substitute measures the underlying property: weight
## distribution divergence between baseline and 2x magnitude beings must
## stay bounded by the gate's normalization.
##
## Procedure:
##   1. Construct two identical Hebbian networks (same persona seed).
##   2. Drive both with the same scripted stimulation: deterministic bursts
##      of co-activation, deterministic reward events.
##   3. Network B emits each reward at 2x the magnitude of Network A.
##   4. After N=400 update cycles (~ proxy for 10 min play), compute the
##      L1-normalized weight delta between A and B.
##   5. PASS if delta <= 0.15 (constants:magnitude_sensitivity_max_kl).
##      Higher = magnitudes punching through normalization (bug).
##
## Why bounded? signal_reward CLAMPS the accumulator at 1.0, and decay returns
## it toward zero each tick. The gate is (1 + beta * signal), capped at
## (1 + beta) = 1.5 by the clamp. So 2x magnitudes can't double the gate;
## they just hit saturation faster.
##
## Usage:
##   godot --path /home/thermos/workspace/burg --headless --quit \
##         --script res://tests/test_f8_magnitude_sensitivity.gd

const PASS := "TEST_F8_MAGNITUDE_SENSITIVITY: PASS"
const FAIL := "TEST_F8_MAGNITUDE_SENSITIVITY: FAIL"

const N_CYCLES: int = 400
const TICK_DT: float = 0.5  # seconds per Hebbian update
const MAX_DELTA: float = 0.15  # match perception_constants.magnitude_sensitivity_max_kl

const REWARD_TAGS: Array = [
	"reward_action_succeeded",
	"reward_drive_satisfaction",
	"reward_social_accepted",
	"reward_rest_recovered",
	"reward_explore_discovered",
	"reward_threat_avoided",
	"reward_drive_stabilization",
]

# Baseline magnitudes (from perception_constants.json:reward_magnitudes).
const BASELINE_MAGS: Dictionary = {
	"reward_drive_satisfaction": 0.7,
	"reward_drive_stabilization": 0.3,
	"reward_social_accepted": 0.6,
	"reward_rest_recovered": 0.4,
	"reward_explore_discovered": 0.5,
	"reward_threat_avoided": 0.8,
	"reward_action_succeeded": 0.2,
}

func _init() -> void:
	# Seed Godot's global RNG so hebbian_update's tie-breaking randf_range
	# is reproducible across A and B steps within a single run.
	seed(0xF8DEADBEEF)

	var Net: GDScript = load("res://scripts/hebbian_network.gd")
	var net_a: RefCounted = Net.new()
	var net_b: RefCounted = Net.new()
	net_a.setup_default_network({"drive_defaults": {}})
	net_b.setup_default_network({"drive_defaults": {}})

	# Run both networks through the same scripted protocol.
	var rng_a := RandomNumberGenerator.new()
	var rng_b := RandomNumberGenerator.new()
	rng_a.seed = 42
	rng_b.seed = 42

	for cycle in range(N_CYCLES):
		# Re-seed global before each pair so net_a and net_b see identical
		# tie-breaking values for their respective hebbian_update calls.
		seed(0xF800 + cycle)
		_step(net_a, rng_a, cycle, false)
		seed(0xF800 + cycle)
		_step(net_b, rng_b, cycle, true)

	# Collect weights into matched dicts and compute divergence.
	var w_a: Dictionary = _weight_map(net_a)
	var w_b: Dictionary = _weight_map(net_b)

	var diff_sum: float = 0.0
	var base_sum: float = 0.0
	var matched: int = 0
	for key in w_a.keys():
		if not w_b.has(key):
			continue
		var a: float = w_a[key]
		var b: float = w_b[key]
		diff_sum += abs(a - b)
		base_sum += abs(a)
		matched += 1

	var rel_delta: float = diff_sum / max(base_sum, 1e-9)
	print("  matched_connections: %d" % matched)
	print("  Σ|w_a|:        %.4f" % base_sum)
	print("  Σ|w_b - w_a|:  %.4f" % diff_sum)
	print("  rel_delta:     %.4f  (threshold %.4f)" % [rel_delta, MAX_DELTA])

	if rel_delta > MAX_DELTA:
		print("%s — magnitudes punched through normalization. " % FAIL +
			"signal_reward clamping/decay isn't enough; either tighten the " +
			"gate or reduce reward magnitudes in perception_constants.json.")
		quit(1)
		return

	print("%s (rel_delta=%.4f <= %.4f)" % [PASS, rel_delta, MAX_DELTA])
	quit(0)

func _step(net: RefCounted, rng: RandomNumberGenerator, cycle: int, doubled: bool) -> void:
	# Drive the same handful of unprotected neurons high so Hebbian sees
	# co-activation. Pick a different pair each cycle for variety.
	var actives: Array = ["task_momentum", "action_approach", "action_observe",
		"action_avoid", "action_help", "task_frustration"]
	# Deterministic: same cycle → same pair on both nets.
	rng.set_state(cycle * 1000 + 1)
	var i: int = rng.randi() % actives.size()
	var j: int = (i + 1 + rng.randi() % (actives.size() - 1)) % actives.size()
	for n in net.neurons:
		if n["id"] in [actives[i], actives[j]]:
			n["activation"] = 88.0
			n["age"] = 1000  # disable new-neuron 2x rate
		else:
			n["activation"] = 10.0

	# Fire a reward event every 3 cycles (deterministic timing).
	if cycle % 3 == 0:
		var tag_idx: int = (cycle / 3) % REWARD_TAGS.size()
		var tag: String = REWARD_TAGS[tag_idx]
		var mag: float = float(BASELINE_MAGS[tag])
		if doubled:
			mag *= 2.0
		net.signal_reward(tag, mag)

	# Propagate handles decay; hebbian_update applies the gated weight change.
	net.propagate(TICK_DT)
	net.hebbian_update(1.0)

func _weight_map(net: RefCounted) -> Dictionary:
	var d: Dictionary = {}
	for c in net.connections:
		var key: String = c["src"] + "->" + c["dst"]
		d[key] = float(c["weight"])
	return d
