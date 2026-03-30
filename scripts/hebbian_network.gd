extends RefCounted
## res://scripts/hebbian_network.gd — Hebbian neural network with neurogenesis
## Core "reptile brain": neurons, weighted connections, associative learning, neurogenesis.
## No LLM. Pure numeric dynamics.

# --- Neuron storage ---
# Each neuron: {id: String, type: String, activation: float, protected: bool,
#               category: String, age: int, label: String}
var neurons: Array = []
var _neuron_map: Dictionary = {}  # id -> neuron dict (fast lookup)

# --- Connection storage ---
# Each connection: {src: String, dst: String, weight: float}
var connections: Array = []

# --- Hebbian state ---
var _recent_pairs: Dictionary = {}  # "src:dst" -> cooldown ticks remaining
const HEBBIAN_TOP_K: int = 2
const HEBBIAN_THRESHOLD: float = 70.0  # both neurons must exceed this
const HEBBIAN_LR: float = 0.01
const HEBBIAN_DECAY: float = 0.001
const PAIR_COOLDOWN: int = 3  # cycles to skip after updating a pair

# --- Neurogenesis state ---
var stress_count: int = 0
var novelty_count: int = 0
var reward_count: int = 0
const MAX_STRESS: int = 5
const MAX_NOVELTY: int = 6
const MAX_REWARD: int = 6
const MAX_DYNAMIC: int = 32
var _dynamic_count: int = 0
var _next_id: int = 0

# Trigger accumulators (updated externally by substrate)
var sustained_stress_timer: float = 0.0
var novelty_exposure_timer: float = 0.0
var recent_reward_signal: float = 0.0

# Last event for debug
var last_neurogenesis_event: Dictionary = {}  # {type, context, tick}

# --- Propagation constants ---
const PROPAGATION_SCALE: float = 0.1
const DECAY_PER_FRAME: float = 0.998
const NOISE_RANGE: float = 0.05

# Action neuron baselines (floors to prevent collapse)
const ACTION_BASELINES: Dictionary = {
	"action_approach": 20.0,
	"action_avoid": 5.0,
	"action_observe": 20.0,
	"action_help": 15.0,
	"action_flee": 0.0,
}

# =========================================================================
# SETUP
# =========================================================================

func setup_default_network(persona: Dictionary) -> void:
	neurons.clear()
	connections.clear()
	_neuron_map.clear()
	_dynamic_count = 0
	stress_count = 0
	novelty_count = 0
	reward_count = 0
	_next_id = 0

	# Read drive defaults from persona data
	var drives: Dictionary = persona.get("drive_defaults", {})
	var init_energy: float = float(drives.get("energy", 80.0))
	var init_hunger: float = float(drives.get("hunger", 20.0))
	var init_social: float = float(drives.get("social", 30.0))
	var init_safety: float = float(drives.get("safety", 80.0))

	# --- Fixed neurons ---
	_add_neuron("drive_energy", "drive", init_energy, false, "", "Energy")
	_add_neuron("drive_hunger", "drive", init_hunger, false, "", "Hunger")
	_add_neuron("drive_social", "drive", init_social, false, "", "Social")
	_add_neuron("drive_safety", "drive", init_safety, false, "", "Safety")

	# Task state (stored 0-100, exposed as 0-1 by substrate)
	_add_neuron("task_momentum", "task", 0.0, false, "", "Momentum")
	_add_neuron("task_frustration", "task", 0.0, false, "", "Frustration")
	_add_neuron("task_int_tolerance", "task", 50.0, false, "", "IntTolerance")

	# Sensory (protected)
	_add_neuron("sense_at_home", "sensory", 0.0, true, "", "AtHome")
	_add_neuron("sense_at_work", "sensory", 0.0, true, "", "AtWork")
	_add_neuron("sense_hour", "sensory", 25.0, true, "", "Hour")
	_add_neuron("sense_nearby_npcs", "sensory", 0.0, true, "", "NearbyNPCs")
	_add_neuron("sense_is_stalled", "sensory", 0.0, true, "", "IsStalled")
	_add_neuron("sense_loc_familiarity", "sensory", 30.0, true, "", "LocFamiliar")
	_add_neuron("sense_is_night", "sensory", 0.0, true, "", "IsNight")
	_add_neuron("sense_at_food", "sensory", 0.0, true, "", "AtFood")

	# Action tendencies (emergent, read-only from outside)
	_add_neuron("action_approach", "action", 50.0, false, "", "Approach")
	_add_neuron("action_avoid", "action", 10.0, false, "", "Avoid")
	_add_neuron("action_observe", "action", 30.0, false, "", "Observe")
	_add_neuron("action_help", "action", 30.0, false, "", "Help")
	_add_neuron("action_flee", "action", 0.0, false, "", "Flee")

	# --- Initial connections ---
	var role: String = persona.get("role", "Villager")
	_seed_connections(role)

	# Apply persona-specific neural biases
	var biases: Array = persona.get("neural_biases", [])
	for bias in biases:
		if bias is Dictionary and bias.has("src") and bias.has("dst") and bias.has("weight"):
			_adjust_weight(str(bias["src"]), str(bias["dst"]), float(bias["weight"]))

func _add_neuron(id: String, type: String, activation: float, protected: bool, category: String, label: String) -> void:
	var neuron: Dictionary = {
		"id": id,
		"type": type,
		"activation": activation,
		"protected": protected,
		"category": category,
		"age": 1000,  # fixed neurons treated as mature
		"label": label,
	}
	neurons.append(neuron)
	_neuron_map[id] = neuron

func _add_connection(src: String, dst: String, weight: float) -> void:
	connections.append({"src": src, "dst": dst, "weight": weight})

func _seed_connections(role: String) -> void:
	# --- Sensory -> Drive (homeostatic) ---
	_add_connection("sense_at_home", "drive_energy", 0.3)    # energy recovers at home
	_add_connection("sense_at_home", "drive_safety", 0.2)    # safe at home
	_add_connection("sense_is_night", "drive_energy", 0.15)  # night + home = sleep recovery
	_add_connection("sense_at_food", "drive_hunger", -0.2)   # hunger drops at food locations
	_add_connection("sense_nearby_npcs", "drive_social", -0.15)  # company satisfies social
	_add_connection("sense_loc_familiarity", "drive_safety", 0.2)  # familiar = safe

	# --- Sensory -> Task ---
	_add_connection("sense_is_stalled", "task_frustration", 0.15)  # stalling builds frustration
	_add_connection("sense_is_stalled", "task_momentum", -0.02)    # stalling erodes momentum

	# --- Task -> Task ---
	_add_connection("task_momentum", "task_int_tolerance", 0.05)   # momentum builds tolerance

	# --- Drive/Task -> Action (replace _update_tendencies formulas) ---
	# approach = f(social_need_inv, energy, exploration_bias)
	_add_connection("drive_social", "action_approach", -0.06)    # high social_need suppresses approach
	_add_connection("drive_energy", "action_approach", 0.03)     # energy enables approach

	# avoid = f(frustration, safety_inv)
	_add_connection("task_frustration", "action_avoid", 0.05)    # frustration drives avoidance
	_add_connection("drive_safety", "action_avoid", -0.03)       # low safety increases avoid

	# observe = f(frustration, attention)
	_add_connection("task_frustration", "action_observe", 0.04)  # frustrated agents scan harder
	_add_connection("sense_is_stalled", "action_observe", 0.03)  # stalled agents look around

	# help = f(trust_avg, frustration_inv) — trust handled externally via modulation
	_add_connection("task_frustration", "action_help", -0.03)    # frustration reduces helpfulness

	# flee = f(safety_inv, energy_inv)
	_add_connection("drive_safety", "action_flee", -0.05)        # low safety triggers flee
	_add_connection("drive_energy", "action_flee", -0.02)        # low energy triggers flee

	# --- Cross-drive influences ---
	_add_connection("drive_hunger", "task_frustration", 0.02)    # extreme hunger is frustrating
	_add_connection("drive_social", "action_observe", 0.02)      # lonely beings watch others

	# Role-specific neural biases are now applied from persona data
	# via neural_biases array in the persona JSON file

func _adjust_weight(src: String, dst: String, delta: float) -> void:
	for conn in connections:
		if conn["src"] == src and conn["dst"] == dst:
			conn["weight"] = clampf(conn["weight"] + delta, -1.0, 1.0)
			return
	# If connection doesn't exist, create it
	_add_connection(src, dst, delta)

# =========================================================================
# CORE API
# =========================================================================

func get_activation(id: String) -> float:
	var n: Dictionary = _neuron_map.get(id, {})
	if n.is_empty():
		return 0.0
	return n["activation"]

func set_activation(id: String, value: float) -> void:
	var n: Dictionary = _neuron_map.get(id, {})
	if n.is_empty():
		return
	n["activation"] = clampf(value, 0.0, 100.0)

# =========================================================================
# PROPAGATION — called every physics frame
# =========================================================================

func propagate(delta: float) -> void:
	# Accumulate connection contributions
	var contributions: Dictionary = {}
	for conn in connections:
		var src_n: Dictionary = _neuron_map.get(conn["src"], {})
		if src_n.is_empty():
			continue
		var contribution: float = src_n["activation"] * conn["weight"] * PROPAGATION_SCALE
		if not contributions.has(conn["dst"]):
			contributions[conn["dst"]] = 0.0
		contributions[conn["dst"]] += contribution

	# Apply contributions to non-protected neurons
	var dt_scale: float = delta * 60.0  # normalize to ~1.0 at 60fps
	for neuron in neurons:
		if neuron["protected"]:
			continue
		var extra: float = contributions.get(neuron["id"], 0.0)
		neuron["activation"] += extra * dt_scale

	# Decay and noise for non-protected neurons
	for neuron in neurons:
		if neuron["protected"]:
			continue
		neuron["activation"] = neuron["activation"] * DECAY_PER_FRAME + randf_range(-NOISE_RANGE, NOISE_RANGE)
		neuron["activation"] = clampf(neuron["activation"], 0.0, 100.0)
		if neuron["age"] < 1000:
			neuron["age"] += 1

	# Enforce action neuron baselines
	for id in ACTION_BASELINES:
		var n: Dictionary = _neuron_map.get(id, {})
		if not n.is_empty() and n["activation"] < ACTION_BASELINES[id]:
			n["activation"] = ACTION_BASELINES[id]

# =========================================================================
# HEBBIAN LEARNING — called every ~0.5s
# =========================================================================

func hebbian_update(learning_rate_mod: float) -> void:
	# Tick down pair cooldowns
	var expired: Array = []
	for key in _recent_pairs:
		_recent_pairs[key] -= 1
		if _recent_pairs[key] <= 0:
			expired.append(key)
	for key in expired:
		_recent_pairs.erase(key)

	# Find co-activated connection pairs
	var candidates: Array = []
	for i in connections.size():
		var conn: Dictionary = connections[i]
		var src_n: Dictionary = _neuron_map.get(conn["src"], {})
		var dst_n: Dictionary = _neuron_map.get(conn["dst"], {})
		if src_n.is_empty() or dst_n.is_empty():
			continue
		if src_n["protected"]:
			continue  # don't learn on pure input connections (src side)
		if src_n["activation"] > HEBBIAN_THRESHOLD and dst_n["activation"] > HEBBIAN_THRESHOLD:
			var score: float = src_n["activation"] + dst_n["activation"] + randf_range(0.0, 10.0)
			var pair_key: String = conn["src"] + ":" + conn["dst"]
			if _recent_pairs.has(pair_key):
				continue
			candidates.append({"index": i, "score": score, "key": pair_key})

	# Sort by score descending
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)

	# Update top K
	var updated: int = 0
	for cand in candidates:
		if updated >= HEBBIAN_TOP_K:
			break
		var conn: Dictionary = connections[cand["index"]]
		var src_act: float = _neuron_map[conn["src"]]["activation"]
		var dst_act: float = _neuron_map[conn["dst"]]["activation"]

		var lr: float = HEBBIAN_LR * learning_rate_mod
		# New neurons learn at 2x rate
		if _neuron_map[conn["src"]]["age"] < 20 or _neuron_map[conn["dst"]]["age"] < 20:
			lr *= 2.0

		var delta_w: float = lr * (src_act / 100.0) * (dst_act / 100.0)
		conn["weight"] = clampf(
			conn["weight"] + delta_w - (conn["weight"] * HEBBIAN_DECAY),
			-1.0, 1.0
		)

		_recent_pairs[cand["key"]] = PAIR_COOLDOWN
		updated += 1

	# Also check for potential NEW connections between highly co-activated neurons
	# that aren't yet connected (spontaneous association)
	if updated < HEBBIAN_TOP_K:
		_check_spontaneous_connections(learning_rate_mod)

func _check_spontaneous_connections(learning_rate_mod: float) -> void:
	# Find pairs of non-protected neurons both above threshold with no existing connection
	var active_neurons: Array = []
	for neuron in neurons:
		if neuron["protected"]:
			continue
		if neuron["activation"] > HEBBIAN_THRESHOLD:
			active_neurons.append(neuron)

	if active_neurons.size() < 2:
		return

	# Check pairs (limit to avoid O(n^2) explosion)
	var checked: int = 0
	for i in active_neurons.size():
		for j in range(i + 1, active_neurons.size()):
			if checked > 10:
				return
			checked += 1
			var a: Dictionary = active_neurons[i]
			var b: Dictionary = active_neurons[j]
			if _connection_exists(a["id"], b["id"]):
				continue
			# Create new connection with small initial weight
			var lr: float = HEBBIAN_LR * learning_rate_mod
			var initial_w: float = lr * (a["activation"] / 100.0) * (b["activation"] / 100.0)
			if absf(initial_w) > 0.001:
				_add_connection(a["id"], b["id"], initial_w)

func _connection_exists(src: String, dst: String) -> bool:
	for conn in connections:
		if (conn["src"] == src and conn["dst"] == dst) or (conn["src"] == dst and conn["dst"] == src):
			return true
	return false

# =========================================================================
# NEUROGENESIS — called every ~2s
# =========================================================================

func check_neurogenesis() -> void:
	if _dynamic_count >= MAX_DYNAMIC:
		return

	# Priority: stress > novelty > reward
	if _check_stress_neurogenesis():
		return
	if _check_novelty_neurogenesis():
		return
	_check_reward_neurogenesis()

func _check_stress_neurogenesis() -> bool:
	if stress_count >= MAX_STRESS:
		# Cap reached — strengthen existing stress neurons instead
		if sustained_stress_timer > 3.0 or get_activation("task_frustration") > 75.0:
			_strengthen_existing("stress")
			sustained_stress_timer = 0.0
		return false

	var frustration: float = get_activation("task_frustration")
	if sustained_stress_timer > 3.0 or frustration > 75.0:
		var context: String = _get_stress_context()
		var neuron_id: String = "dyn_stress_%s_%d" % [context, _next_id]
		_next_id += 1

		_add_neuron(neuron_id, "dynamic", 50.0, false, "stress", "stress(%s)" % context)
		neurons[-1]["age"] = 0  # new neuron

		# Stress neurons inhibit frustration and boost observation
		_add_connection(neuron_id, "task_frustration", -0.1)
		_add_connection("task_frustration", neuron_id, 0.3)  # activated by what they regulate
		_add_connection(neuron_id, "action_observe", 0.05)

		# Context-specific connections
		match context:
			"hunger":
				_add_connection("drive_hunger", neuron_id, 0.2)
				_add_connection(neuron_id, "action_approach", 0.03)
			"safety":
				_add_connection("drive_safety", neuron_id, -0.2)  # low safety activates
				_add_connection(neuron_id, "action_flee", 0.04)
			"social":
				_add_connection("drive_social", neuron_id, 0.2)
				_add_connection(neuron_id, "action_approach", 0.03)
			"blocked":
				_add_connection("sense_is_stalled", neuron_id, 0.3)
				_add_connection(neuron_id, "action_avoid", 0.04)

		stress_count += 1
		_dynamic_count += 1
		sustained_stress_timer = 0.0
		last_neurogenesis_event = {"type": "stress", "context": context, "tick": Time.get_ticks_msec()}
		return true
	return false

func _check_novelty_neurogenesis() -> bool:
	if novelty_count >= MAX_NOVELTY:
		return false

	if novelty_exposure_timer > 5.0 and get_activation("sense_loc_familiarity") < 30.0:
		var neuron_id: String = "dyn_novelty_%d" % _next_id
		_next_id += 1

		_add_neuron(neuron_id, "dynamic", 50.0, false, "novelty", "novelty")
		neurons[-1]["age"] = 0

		# Novelty neurons boost observation and approach
		_add_connection(neuron_id, "action_observe", 0.06)
		_add_connection(neuron_id, "action_approach", 0.04)
		_add_connection("sense_loc_familiarity", neuron_id, -0.15)  # unfamiliar activates
		_add_connection("task_frustration", neuron_id, -0.05)  # frustration suppresses curiosity

		novelty_count += 1
		_dynamic_count += 1
		novelty_exposure_timer = 0.0
		last_neurogenesis_event = {"type": "novelty", "context": "exploration", "tick": Time.get_ticks_msec()}
		return true
	return false

func _check_reward_neurogenesis() -> bool:
	if reward_count >= MAX_REWARD:
		return false

	if recent_reward_signal > 0.0:
		var context: String = _get_reward_context()
		var neuron_id: String = "dyn_reward_%s_%d" % [context, _next_id]
		_next_id += 1

		_add_neuron(neuron_id, "dynamic", 60.0, false, "reward", "reward(%s)" % context)
		neurons[-1]["age"] = 0

		# Reward neurons reinforce the drive-action pathway that led to satisfaction
		_add_connection(neuron_id, "action_approach", 0.05)
		match context:
			"energy":
				_add_connection("drive_energy", neuron_id, 0.15)
				_add_connection(neuron_id, "task_momentum", 0.03)
			"hunger":
				_add_connection("drive_hunger", neuron_id, -0.15)  # satisfied hunger activates
				_add_connection(neuron_id, "action_approach", 0.03)
			"social":
				_add_connection("drive_social", neuron_id, -0.15)
				_add_connection(neuron_id, "action_help", 0.04)
			"safety":
				_add_connection("drive_safety", neuron_id, 0.15)
				_add_connection(neuron_id, "action_observe", 0.03)

		reward_count += 1
		_dynamic_count += 1
		recent_reward_signal = 0.0
		last_neurogenesis_event = {"type": "reward", "context": context, "tick": Time.get_ticks_msec()}
		return true
	return false

func _get_stress_context() -> String:
	# What's causing the most stress right now?
	if get_activation("sense_is_stalled") > 50.0:
		return "blocked"
	var worst: String = "general"
	var worst_val: float = 0.0
	# Check which drive is most extreme
	if get_activation("drive_hunger") > worst_val:
		worst_val = get_activation("drive_hunger")
		worst = "hunger"
	if (100.0 - get_activation("drive_safety")) > worst_val:
		worst_val = 100.0 - get_activation("drive_safety")
		worst = "safety"
	if get_activation("drive_social") > worst_val:
		worst_val = get_activation("drive_social")
		worst = "social"
	if (100.0 - get_activation("drive_energy")) > worst_val:
		worst = "energy"
	return worst

func _get_reward_context() -> String:
	# Which drive is in the best state right now? (just recovered)
	var best: String = "general"
	var best_score: float = -1.0
	# Energy high = good
	if get_activation("drive_energy") > best_score:
		best_score = get_activation("drive_energy")
		best = "energy"
	# Hunger low = good (invert)
	if (100.0 - get_activation("drive_hunger")) > best_score:
		best_score = 100.0 - get_activation("drive_hunger")
		best = "hunger"
	# Social low = good (invert)
	if (100.0 - get_activation("drive_social")) > best_score:
		best_score = 100.0 - get_activation("drive_social")
		best = "social"
	# Safety high = good
	if get_activation("drive_safety") > best_score:
		best = "safety"
	return best

func _strengthen_existing(category: String) -> void:
	# When neurogenesis cap reached, boost existing neurons of this category
	for neuron in neurons:
		if neuron["category"] == category:
			neuron["activation"] = clampf(neuron["activation"] + 10.0, 0.0, 100.0)

# =========================================================================
# NEUROGENESIS TRACKING — called by substrate each tick
# =========================================================================

func update_stress_tracking(frustration_01: float, safety_01: float, delta: float) -> void:
	# frustration_01 and safety_01 are 0-1 scale from substrate interface
	if frustration_01 > 0.5 or safety_01 < 0.3:
		sustained_stress_timer += delta
	else:
		sustained_stress_timer = maxf(sustained_stress_timer - delta * 0.5, 0.0)

func update_novelty_tracking(familiarity_01: float, delta: float) -> void:
	if familiarity_01 < 0.3:
		novelty_exposure_timer += delta
	else:
		novelty_exposure_timer = maxf(novelty_exposure_timer - delta * 0.5, 0.0)

func signal_reward() -> void:
	recent_reward_signal = 1.0

# =========================================================================
# DEBUG
# =========================================================================

func get_neuron_count() -> int:
	return neurons.size()

func get_connection_count() -> int:
	return connections.size()

func get_dynamic_neuron_count() -> int:
	return _dynamic_count

func get_debug_state() -> Dictionary:
	var dynamic_neurons: Array = []
	for neuron in neurons:
		if neuron["category"] != "":
			dynamic_neurons.append({
				"id": neuron["id"],
				"label": neuron["label"],
				"activation": neuron["activation"],
				"category": neuron["category"],
				"age": neuron["age"],
			})
	return {
		"neuron_count": neurons.size(),
		"connection_count": connections.size(),
		"dynamic_count": _dynamic_count,
		"stress_count": stress_count,
		"novelty_count": novelty_count,
		"reward_count": reward_count,
		"last_event": last_neurogenesis_event,
		"dynamic_neurons": dynamic_neurons,
		"stress_timer": sustained_stress_timer,
		"novelty_timer": novelty_exposure_timer,
	}
