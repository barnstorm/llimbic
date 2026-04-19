extends RefCounted
## res://scripts/layer1_substrate.gd — Layer 1 behavioral substrate
## Wraps a Hebbian neural network. External API unchanged — drives, tendencies,
## trust, familiarity all accessible as before. Internals are now emergent.

var _network: RefCounted = null  # HebbianNetwork

# Phase 1 reward bookkeeping (drive-crossing detection per spec §2.7).
# Per drive: previous level (for crossing detection) and sustained-safe-band timer.
var _prev_drive_levels: Dictionary = {}        # drive_name -> last sampled value
var _drive_safe_band_seconds: Dictionary = {}  # drive_name -> seconds sustained in safe band
var _drive_thresholds_cache: Dictionary = {}   # lazy from PerceptionConstants
var _reward_magnitudes_cache: Dictionary = {}  # lazy from PerceptionConstants
var _somatic: RefCounted = null  # SomaticStream

# --- Timers ---
var _hebbian_timer: float = 0.0
var _neurogenesis_timer: float = 0.0
var _somatic_timer: float = 0.0
const HEBBIAN_INTERVAL: float = 0.5
const NEUROGENESIS_INTERVAL: float = 2.0
const SOMATIC_INTERVAL: float = 0.25  # emit tags ~4x per second

# --- Somatic output ---
var somatic_tags: Array = []  # last emitted tag swarm

# --- Stall detection (mechanical, not neural) ---
var _stalled_time: float = 0.0
var is_stalled: bool = false
var _stall_spike_fired: bool = false

# Reorientation timer (mechanical timing)
var reorientation_timer: float = 0.0

# Per-entity trust (dictionary, not neural)
var trust: Dictionary = {}

# Per-location familiarity (dictionary, not neural)
var place_familiarity: Dictionary = {}

# Modulation inputs from Layer 2
var learning_rate_mod: float = 1.0
var exploration_bias: float = 0.0
var attention_weight: float = 1.0
var interruption_sensitivity: float = 0.5
var persistence_scale: float = 1.0

# Cached emotion vector (set via apply_emotion_feedback)
var _emotion_vector: Array = []

# Context (set externally via set_context)
var _role: String = ""
var _is_at_home: bool = false
var _is_at_work: bool = false
var _current_location: String = ""
var _nearby_npcs: int = 0
var _hour: float = 6.0

# =========================================================================
# PROPERTY GETTERS/SETTERS — backward compatible interface
# =========================================================================

# Core drives (0-100)
var energy: float:
	get: return _network.get_activation("drive_energy") if _network else 80.0
	set(v):
		if _network:
			_network.set_activation("drive_energy", v)

var hunger: float:
	get: return _network.get_activation("drive_hunger") if _network else 20.0
	set(v):
		if _network:
			_network.set_activation("drive_hunger", v)

var social_need: float:
	get: return _network.get_activation("drive_social") if _network else 30.0
	set(v):
		if _network:
			_network.set_activation("drive_social", v)

var safety: float:
	get: return _network.get_activation("drive_safety") if _network else 80.0
	set(v):
		if _network:
			_network.set_activation("drive_safety", v)

# Task state (0-1 externally, 0-100 internally)
var task_momentum: float:
	get: return _network.get_activation("task_momentum") / 100.0 if _network else 0.0
	set(v):
		if _network:
			_network.set_activation("task_momentum", v * 100.0)

var frustration: float:
	get: return _network.get_activation("task_frustration") / 100.0 if _network else 0.0
	set(v):
		if _network:
			_network.set_activation("task_frustration", v * 100.0)

var interruption_tolerance: float:
	get: return _network.get_activation("task_int_tolerance") / 100.0 if _network else 0.5
	set(v):
		if _network:
			_network.set_activation("task_int_tolerance", v * 100.0)

# Action tendencies (0-1, emergent from network)
var approach: float:
	get: return _network.get_activation("action_approach") / 100.0 if _network else 0.5

var avoid: float:
	get: return _network.get_activation("action_avoid") / 100.0 if _network else 0.1

var observe: float:
	get: return _network.get_activation("action_observe") / 100.0 if _network else 0.3

var help: float:
	get: return _network.get_activation("action_help") / 100.0 if _network else 0.3

var flee: float:
	get: return _network.get_activation("action_flee") / 100.0 if _network else 0.0

var arousal: float:
	get: return _network.get_activation("drive_arousal") / 100.0 if _network else 0.3
	set(v):
		if _network:
			_network.set_activation("drive_arousal", v * 100.0)

# =========================================================================
# SETUP
# =========================================================================

func setup(persona: Dictionary, memory: RefCounted = null) -> void:
	_role = persona.get("role", "Villager")
	var NetScript: GDScript = load("res://scripts/hebbian_network.gd")
	_network = NetScript.new()
	_network.setup_default_network(persona)
	# Somatic stream
	var SomScript: GDScript = load("res://scripts/somatic_stream.gd")
	_somatic = SomScript.new()
	_somatic.setup(_network, memory)

# =========================================================================
# UPDATE — called every physics tick
# =========================================================================

func update(delta: float) -> void:
	if _network == null:
		return

	var rate: float = delta * learning_rate_mod

	# 1. Set sensory neurons from context
	_update_sensory_neurons()

	# 2. Baseline drift (preserves current game feel)
	_baseline_drift(rate)

	# 3. Stall-driven frustration spike (mechanical)
	_update_stall_frustration(rate)

	# 4. Reorientation timer
	if reorientation_timer > 0.0:
		reorientation_timer = maxf(reorientation_timer - delta, 0.0)

	# 4b. Drive-crossing reward detection (Phase 1 — spec §2.7)
	_check_drive_crossings(delta)

	# 5. Day cycle energy boost
	if _hour >= 21.0 or _hour < 6.0:
		if _is_at_home:
			var e: float = _network.get_activation("drive_energy")
			_network.set_activation("drive_energy", clampf(e + 5.0 * rate, 0.0, 100.0))

	# 6. Propagate neural network
	_network.propagate(delta)

	# 7. Apply Layer 2 modulation to action neurons
	_apply_modulation()

	# 8. Hebbian learning (~every 0.5s)
	_hebbian_timer += delta
	if _hebbian_timer >= HEBBIAN_INTERVAL:
		_hebbian_timer -= HEBBIAN_INTERVAL
		_network.hebbian_update(learning_rate_mod)

	# 9. Neurogenesis tracking + check (~every 2s)
	_network.update_stress_tracking(frustration, safety / 100.0, delta)
	_network.update_novelty_tracking(place_familiarity.get(_current_location, 0.3), delta)
	_neurogenesis_timer += delta
	if _neurogenesis_timer >= NEUROGENESIS_INTERVAL:
		_neurogenesis_timer -= NEUROGENESIS_INTERVAL
		_network.check_neurogenesis()

	# 10. Somatic tag emission (~4x per second)
	_somatic_timer += delta
	if _somatic_timer >= SOMATIC_INTERVAL and _somatic != null:
		_somatic_timer -= SOMATIC_INTERVAL
		somatic_tags = _somatic.emit()

func _update_sensory_neurons() -> void:
	_network.set_activation("sense_at_home", 100.0 if _is_at_home else 0.0)
	_network.set_activation("sense_at_work", 100.0 if _is_at_work else 0.0)
	_network.set_activation("sense_hour", _hour / 24.0 * 100.0)
	_network.set_activation("sense_nearby_npcs", minf(float(_nearby_npcs) * 25.0, 100.0))
	_network.set_activation("sense_is_stalled", 100.0 if is_stalled else 0.0)
	_network.set_activation("sense_loc_familiarity", place_familiarity.get(_current_location, 0.3) * 100.0)
	_network.set_activation("sense_is_night", 100.0 if (_hour >= 21.0 or _hour < 6.0) else 0.0)
	_network.set_activation("sense_at_food", 100.0 if _current_location in ["bakery", "inn", "market", "farm"] else 0.0)

	# Emotion sensory neurons — SET from cached emotion vector
	if _emotion_vector.size() >= 27:
		_network.set_activation("emo_fear", _emotion_vector[18] * 100.0)
		_network.set_activation("emo_anger", _emotion_vector[12] * 100.0)
		_network.set_activation("emo_disgust", _emotion_vector[16] * 100.0)
		_network.set_activation("emo_nervousness", _emotion_vector[20] * 100.0)
		_network.set_activation("emo_grief", _emotion_vector[19] * 100.0)
		_network.set_activation("emo_joy", _emotion_vector[7] * 100.0)
		_network.set_activation("emo_excitement", _emotion_vector[5] * 100.0)
		_network.set_activation("emo_sadness", _emotion_vector[22] * 100.0)
		_network.set_activation("emo_embarrassment", _emotion_vector[17] * 100.0)
		_network.set_activation("emo_relief", _emotion_vector[11] * 100.0)
		_network.set_activation("emo_curiosity", _emotion_vector[24] * 100.0)

func _baseline_drift(rate: float) -> void:
	# Energy depletes during activity, recovers at home
	var e: float = _network.get_activation("drive_energy")
	if _is_at_home:
		e = clampf(e + 3.0 * rate, 0.0, 100.0)
	else:
		e = clampf(e - 0.8 * rate, 0.0, 100.0)
	_network.set_activation("drive_energy", e)

	# Hunger rises over time, satisfied at food locations
	var h: float = _network.get_activation("drive_hunger")
	h = clampf(h + 0.5 * rate, 0.0, 100.0)
	if _current_location in ["bakery", "inn", "market", "farm"]:
		h = clampf(h - 2.0 * rate, 0.0, 100.0)
	_network.set_activation("drive_hunger", h)

	# Social need rises, drops with company
	var s: float = _network.get_activation("drive_social")
	s = clampf(s + 0.3 * rate, 0.0, 100.0)
	if _nearby_npcs > 0:
		s = clampf(s - 1.5 * float(_nearby_npcs) * rate, 0.0, 100.0)
	_network.set_activation("drive_social", s)

	# Safety: recovers in familiar places
	var loc_comfort: float = place_familiarity.get(_current_location, 0.3)
	var sf: float = _network.get_activation("drive_safety")
	sf = clampf(sf + (loc_comfort - 0.5) * 2.0 * rate, 0.0, 100.0)
	if _is_at_home:
		sf = clampf(sf + 2.0 * rate, 0.0, 100.0)
	_network.set_activation("drive_safety", sf)

	# Task momentum builds while pursuing plan
	var m: float = _network.get_activation("task_momentum")
	if m > 0.0:
		m = clampf(m + 2.0 * persistence_scale * rate, 0.0, 100.0)
	_network.set_activation("task_momentum", m)

	# Interruption tolerance tracks momentum (network also influences it)
	var tol: float = 30.0 + _network.get_activation("task_momentum") * 0.5 - interruption_sensitivity * 20.0
	_network.set_activation("task_int_tolerance", clampf(tol, 0.0, 100.0))

func _update_stall_frustration(rate: float) -> void:
	var frust: float = _network.get_activation("task_frustration")
	var mom: float = _network.get_activation("task_momentum")

	if is_stalled:
		if not _stall_spike_fired:
			# Onset spike proportional to commitment
			var spike: float = 15.0 + mom * 0.25  # 15 idle, up to 40 mid-task (0-100 scale)
			frust = clampf(frust + spike, 0.0, 100.0)
			mom = clampf(mom - 15.0, 0.0, 100.0)
			_stall_spike_fired = true
		else:
			# Sustain
			frust = clampf(frust + 2.0 * rate, 0.0, 100.0)
			mom = clampf(mom - 1.0 * rate, 0.0, 100.0)
	else:
		_stall_spike_fired = false
		frust = clampf(frust - 1.0 * rate, 0.0, 100.0)

	_network.set_activation("task_frustration", frust)
	_network.set_activation("task_momentum", mom)

func _apply_modulation() -> void:
	# Exploration bias influences approach
	if absf(exploration_bias) > 0.01:
		var a: float = _network.get_activation("action_approach")
		a = clampf(a + exploration_bias * 30.0, 0.0, 100.0)
		_network.set_activation("action_approach", a)

	# Attention weight influences observe
	if absf(attention_weight - 1.0) > 0.01:
		var o: float = _network.get_activation("action_observe")
		o = clampf(o + (attention_weight - 1.0) * 30.0, 0.0, 100.0)
		_network.set_activation("action_observe", o)

	# Trust average influences help
	var avg_trust: float = 0.5
	if trust.size() > 0:
		var sum_t: float = 0.0
		for t in trust.values():
			sum_t += t
		avg_trust = sum_t / float(trust.size())
	var help_act: float = _network.get_activation("action_help")
	help_act = clampf(help_act + (avg_trust - 0.5) * 20.0, 0.0, 100.0)
	_network.set_activation("action_help", help_act)

# =========================================================================
# CONTEXT & METHODS — unchanged interface
# =========================================================================

func set_context(hour: float, at_home: bool, at_work: bool, location: String, nearby_count: int) -> void:
	_hour = hour
	_is_at_home = at_home
	_is_at_work = at_work
	_current_location = location
	_nearby_npcs = nearby_count

func apply_interruption() -> void:
	var frust: float = _network.get_activation("task_frustration") if _network else 0.0
	frust = clampf(frust + 10.0, 0.0, 100.0)
	var mom: float = _network.get_activation("task_momentum") if _network else 0.0
	mom = clampf(mom - 30.0, 0.0, 100.0)
	if _network:
		_network.set_activation("task_frustration", frust)
		_network.set_activation("task_momentum", mom)
	reorientation_timer = 0.5 + (frust / 100.0) * 1.5

func start_task() -> void:
	if _network:
		_network.set_activation("task_momentum", 10.0)  # 0.1 in 0-1 scale = 10 in 0-100

func get_vagal_state() -> Dictionary:
	if _network:
		return _network.get_vagal_state()
	return {"ventral": 50.0, "sympathetic": 20.0, "dorsal": 5.0}

func get_state_dict() -> Dictionary:
	return {
		"energy": energy,
		"hunger": hunger,
		"social_need": social_need,
		"safety": safety,
		"arousal": arousal,
		"task_momentum": task_momentum,
		"interruption_tolerance": interruption_tolerance,
		"frustration": frustration,
		"approach": approach,
		"avoid": avoid,
		"observe": observe,
		"help": help,
		"flee": flee,
		"vagal_state": get_vagal_state(),
		"salience": _network.get_activation("salience") if _network else 0.0,
	}

func get_somatic_tags() -> Array:
	## Get the last emitted somatic tag swarm.
	return somatic_tags

func get_somatic_debug() -> Dictionary:
	if _somatic:
		return _somatic.get_debug_state()
	return {}

func update_progress(delta: float, intended_speed: float, actual_movement: float) -> void:
	if intended_speed < 1.0:
		if is_stalled:
			_stall_spike_fired = false
		_stalled_time = 0.0
		is_stalled = false
		return
	var expected: float = intended_speed * delta
	if expected > 0.0 and actual_movement < expected * 0.3:
		_stalled_time += delta
		is_stalled = _stalled_time > 0.4
	else:
		_stalled_time = 0.0
		if is_stalled:
			_stall_spike_fired = false
		is_stalled = false

func should_interrupt_for(urgency: String) -> bool:
	match urgency:
		"critical":
			return true
		"high":
			return frustration < 0.7 and task_momentum < 0.6
		"medium":
			return task_momentum < interruption_tolerance
		_:
			return task_momentum < 0.2

# =========================================================================
# EMOTION → L1 FEEDBACK (closes the L2→L1 loop)
# =========================================================================

func apply_emotion_feedback(emotion_vector: Array) -> void:
	## Cache emotion vector for sensory neuron writes in _update_sensory_neurons().
	## Emotion→action/task nudges are now learnable Hebbian connections
	## (emo_anger→task_frustration, emo_fear→action_flee, etc.).
	## Only fear→safety remains hardcoded: drive_safety is protected, propagation can't reach it.
	if _network == null or emotion_vector.size() < 27:
		return
	_emotion_vector = emotion_vector

	var fear: float = emotion_vector[18]
	if fear > 0.2:
		var s: float = _network.get_activation("drive_safety")
		_network.set_activation("drive_safety", clampf(s - fear * 0.02 * 30.0, 0.0, 100.0))

# =========================================================================
# NETWORK DEBUG ACCESS
# =========================================================================

func get_network_debug() -> Dictionary:
	if _network == null:
		return {}
	return _network.get_debug_state()

# =========================================================================
# APPRAISAL HANDSHAKE — feeds Python AppraisalEmbeddingManager
# =========================================================================

# =========================================================================
# REWARD WIRING (Phase 1 — spec §2.7)
# =========================================================================

func signal_reward(source_tag: String, magnitude: float = -1.0) -> void:
	## Wrapper so engine-side callers don't need a direct _network handle.
	## If magnitude < 0, look up the default for source_tag from
	## perception_constants.json:reward_magnitudes.
	if _network == null:
		return
	var m: float = magnitude
	if m < 0.0:
		m = float(_load_reward_magnitudes().get(source_tag, 0.5))
	_network.signal_reward(source_tag, m)

func signal_action_success(verb: String, target_eid: String = "") -> void:
	## Phase 4 wrapper. Pass through to the Hebbian network's action-success
	## hook so callers don't need a direct _network handle.
	if _network == null:
		return
	_network.signal_action_success(verb, target_eid)

func _load_reward_magnitudes() -> Dictionary:
	if not _reward_magnitudes_cache.is_empty():
		return _reward_magnitudes_cache
	var pc: Node = null
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	if pc != null:
		var v: Variant = pc.call("get_value", "reward_magnitudes", {})
		if typeof(v) == TYPE_DICTIONARY:
			_reward_magnitudes_cache = v
	if _reward_magnitudes_cache.is_empty():
		# Spec defaults — keeps headless tests working without the autoload.
		_reward_magnitudes_cache = {
			"reward_drive_satisfaction": 0.7,
			"reward_drive_stabilization": 0.3,
			"reward_social_accepted": 0.6,
			"reward_rest_recovered": 0.4,
			"reward_explore_discovered": 0.5,
			"reward_threat_avoided": 0.8,
			"reward_action_succeeded": 0.2,
		}
	return _reward_magnitudes_cache

func _load_drive_thresholds() -> Dictionary:
	if not _drive_thresholds_cache.is_empty():
		return _drive_thresholds_cache
	var pc: Node = null
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	if pc != null:
		var v: Variant = pc.call("get_value", "drive_thresholds", {})
		if typeof(v) == TYPE_DICTIONARY:
			_drive_thresholds_cache = v
	if _drive_thresholds_cache.is_empty():
		# Spec defaults — keeps headless tests working without the autoload.
		_drive_thresholds_cache = {
			"energy":      {"urgency": 30.0, "safe_band": 60.0, "inverted": true},
			"hunger":      {"urgency": 70.0, "safe_band": 40.0, "inverted": false},
			"social_need": {"urgency": 70.0, "safe_band": 40.0, "inverted": false},
			"safety":      {"urgency": 40.0, "safe_band": 70.0, "inverted": true},
			"stabilization_sustained_seconds": 5.0,
		}
	return _drive_thresholds_cache

func _check_drive_crossings(delta: float) -> void:
	## Detect drive transitions per spec §2.7:
	##   - Crossing FROM urgent INTO safe → reward_drive_satisfaction
	##   - Sustained in safe band for stabilization_sustained_seconds
	##                                  → reward_drive_stabilization (one-shot)
	##
	## "Inverted" drives (energy, safety) treat HIGH as good. The check
	## inverts comparisons accordingly so the same logic handles both kinds.
	if _network == null:
		return
	var thresholds: Dictionary = _load_drive_thresholds()
	if thresholds.is_empty():
		return
	var sustained_required: float = float(thresholds.get("stabilization_sustained_seconds", 5.0))

	# Map JSON drive names to the actual neuron IDs. drive_social_need would
	# look up "drive_social_need" but the neuron is named "drive_social".
	const NEURON_ID_MAP: Dictionary = {
		"energy": "drive_energy",
		"hunger": "drive_hunger",
		"social_need": "drive_social",
		"safety": "drive_safety",
	}
	for drive_name in thresholds.keys():
		if drive_name.begins_with("_") or drive_name == "stabilization_sustained_seconds":
			continue
		var spec: Dictionary = thresholds[drive_name]
		var inverted: bool = bool(spec.get("inverted", false))
		var urgency: float = float(spec.get("urgency", 50.0))
		var safe_band: float = float(spec.get("safe_band", 60.0))
		var neuron_id: String = NEURON_ID_MAP.get(drive_name, "drive_" + drive_name)
		var current: float = _network.get_activation(neuron_id)
		if current < 0.0:
			continue
		var prev: float = float(_prev_drive_levels.get(drive_name, current))

		# Crossing detection.
		var was_urgent: bool
		var is_urgent: bool
		if inverted:
			# Inverted drives (energy, safety): low value = urgent.
			was_urgent = prev <= urgency
			is_urgent = current <= urgency
		else:
			# Normal drives (hunger, social): high value = urgent.
			was_urgent = prev >= urgency
			is_urgent = current >= urgency

		if was_urgent and not is_urgent:
			signal_reward("reward_drive_satisfaction")

		# Sustained-safe-band detection.
		var in_safe: bool
		if inverted:
			in_safe = current >= safe_band
		else:
			in_safe = current <= safe_band
		var sec: float = float(_drive_safe_band_seconds.get(drive_name, 0.0))
		if in_safe:
			sec += delta
			if sec >= sustained_required:
				signal_reward("reward_drive_stabilization")
				sec = -1e9  # latch — won't re-fire until drive leaves safe band
		else:
			sec = 0.0
		_drive_safe_band_seconds[drive_name] = sec

		_prev_drive_levels[drive_name] = current

func drain_recent_reward_events() -> Array:
	## Forwarded to network; keeps callers single-rooted on layer1.
	if _network == null:
		return []
	return _network.drain_recent_reward_events()

func get_per_entity_channels() -> Dictionary:
	## Phase 3 — surface continuous distance/rate/dwell channels for snapshot
	## and trace recording. Empty dict if the network isn't available.
	if _network == null:
		return {}
	return _network.get_per_entity_channels()

func get_perception_salience(entity_ids: Array) -> Dictionary:
	## Phase 6 — {eid: summed outgoing propagation weight of sense_visible_{eid}}.
	## The Hebbian graph's own weights drive the ranking; there is no separate
	## salience function. Empty dict if the network isn't available.
	if _network == null:
		return {}
	return _network.get_perception_salience(entity_ids)

func get_compound_state() -> Dictionary:
	## Phase 7 — snapshot-ready compound-neuron state:
	##   {"active": {compound_id: activation}, "count": int}
	## Active compounds gate affordance verbs (§7.3); count drives the F4
	## fallback-decay coefficient.
	if _network == null:
		return {"active": {}, "count": 0}
	return {
		"active": _network.get_active_compounds(),
		"count": _network.get_compound_count(),
	}

func get_cross_modal_state() -> Dictionary:
	## Phase 9 — snapshot-ready cross-modal state:
	##   {"heard": {eid: activation},
	##    "bind_active": {eid: activation},
	##    "new_bind_neurons": [ ... ]}
	## Heard activations drive Phase 6's ranking (unified with visible).
	## Bind activations surface for trace diagnostics + §9.4 probes.
	## new_bind_neurons is drained — one-shot per spawn for the trace.
	if _network == null:
		return {"heard": {}, "bind_active": {}, "new_bind_neurons": []}
	return {
		"heard": _network.get_active_heard_activations(),
		"bind_active": _network.get_active_bind_activations(),
		"new_bind_neurons": _network.drain_new_bind_neurons(),
	}

func get_temporal_state() -> Dictionary:
	## Phase 10 — snapshot-ready temporal-texture state:
	##   {"active": {eid: {kind: activation}},
	##    "new_neurons": [ ... ]}
	## `active` feeds the Phase 7 renderer's inline-tokens slot so "lingering"
	## / "approaching_fast" appear on the prompt line for the matching entity.
	## `new_neurons` is drained per tick for trace v2.
	if _network == null:
		return {"active": {}, "new_neurons": []}
	return {
		"active": _network.get_active_temporal_textures(),
		"new_neurons": _network.drain_new_temporal_textures(),
	}

func pulse_intention_context(neuron_ids: Array) -> void:
	## Phase 11 — forward the pulse call to the Hebbian network.
	if _network == null:
		return
	_network.pulse_intention_context(neuron_ids)

func get_intention_state() -> Dictionary:
	## Phase 11 — snapshot-ready intention-attention state:
	##   {"context_neurons": {id: activation},
	##    "amplification":  {sense_id: multiplier},
	##    "bootstrap_variance": {intention_id: cv}}
	if _network == null:
		return {"context_neurons": {}, "amplification": {}, "bootstrap_variance": {}}
	return _network.get_intention_state()

func dump_graph_summary() -> Dictionary:
	## Phase 13 — learned-weight structure snapshot for capstone metrics.
	## Empty dict if the Hebbian network isn't available.
	if _network == null:
		return {}
	return _network.dump_graph_summary()

func get_perception_salience_all(entity_ids: Array) -> Dictionary:
	## Phase 9 — per-eid salience combining visible + heard outgoing-weight
	## sums. Phase 6 covered visible only; Phase 9 brings heard into the
	## unified rank by summing the outgoing weights of both sense-neuron
	## families for each eid. Missing-sense-neuron entries contribute 0,
	## preserving Phase 6's cold-start behaviour.
	if _network == null:
		return {}
	var visible_map: Dictionary = _network.get_perception_salience(entity_ids)
	var out: Dictionary = {}
	for eid in entity_ids:
		var s: String = String(eid)
		if s == "":
			continue
		var v: float = float(visible_map.get(s, 0.0))
		var h: float = _network.get_outgoing_weight_sum("sense_heard_" + s)
		out[s] = v + h
	return out

func get_appraisal_payload() -> Dictionary:
	## Per-snapshot payload for the cortical feedback bridge.
	##
	## - "new_neurons": appraisal neurons that spawned since the last drain.
	##   Each carries id + embedding_seed (concept→activation) for Python-side
	##   AppraisalEmbeddingManager.initialize().
	## - "active":   {appraisal_id: activation} for currently-firing appraisals.
	##   Cortical feedback drifts each of these toward the generated thought.
	if _network == null:
		return {"new_neurons": [], "active": {}}
	return {
		"new_neurons": _network.drain_new_appraisal_neurons(),
		"active": _network.get_active_appraisal_activations(),
	}
