extends RefCounted
## res://scripts/somatic_stream.gd — Somatic tag emitter
## Reads Hebbian quality neuron activations. Emotion→quality path is now entirely
## through learnable Hebbian connections (emotion sensory neurons → quality neurons).
## Applies suppression (threat kills gut tags) and place-emotion conditioning.
## Outputs a tag swarm: ["gut:empty:churning", "chest:tight", "body:aroused"]
## This is what the LLM reads. This is what the vagal gate reads.
## Nothing above L1 ever sees a float.

var _network: RefCounted = null  # HebbianNetwork reference
var _memory: RefCounted = null   # MemorySystem reference (for place conditioning)

# Suppression rules: which regions get suppressed under threat
# When threat tags are active, gut/chest-positive tags are suppressed
const THREAT_SUPPRESSED_QUALITIES: Array = ["settled", "warm", "open", "full", "clear", "loose", "light"]

# Last emitted tags (for debug / comparison)
var last_tags: Array = []
var last_raw_tags: Array = []  # before suppression

func setup(network: RefCounted, memory: RefCounted = null) -> void:
	_network = network
	_memory = memory

func emit() -> Array:
	## Main emission: returns Array of somatic tag strings.
	## Call every tick or every few ticks from layer1_substrate.
	if _network == null:
		return []

	# 1. Compute suppression map
	var suppression: Dictionary = _compute_suppression()

	# 2. Apply place-emotion conditioning (phantom tags)
	_apply_conditioning()

	# 3. Emit tags from quality neurons
	var tags: Array = _network.emit_quality_tags(suppression)

	# 4. Check for compound quality neurogenesis
	_network.check_quality_neurogenesis()

	# 5. Check for appraisal neurogenesis (3+ quality constellation sustained)
	_network.check_appraisal_neurogenesis()

	last_tags = tags
	return tags

func _nudge(neuron_id: String, amount: float) -> void:
	## Small activation nudge on a quality neuron.
	var current: float = _network.get_activation(neuron_id)
	if current >= 0.0:  # neuron exists
		_network.set_activation(neuron_id, clampf(current + amount, 0.0, 100.0))

func _compute_suppression() -> Dictionary:
	## Compute region suppression based on threat state.
	## Active threat suppresses gut comfort tags (you don't feel hungry while fleeing).
	var suppression: Dictionary = {}

	var flee_act: float = _network.get_activation("action_flee")
	var safety: float = _network.get_activation("drive_safety")
	var arousal: float = _network.get_activation("drive_arousal")

	# High threat → suppress comfort signals in gut and chest
	var threat_level: float = clampf((flee_act / 100.0) + ((100.0 - safety) / 200.0), 0.0, 1.0)
	if threat_level > 0.3:
		# Don't suppress the region entirely — suppress comfort qualities
		# by boosting threat qualities (they'll dominate the concatenated tag)
		# The suppression dict is used by emit_quality_tags to probabilistically skip
		suppression["gut"] = threat_level * 0.5  # partial gut suppression
		# Note: chest threat tags (tight, pounding) still fire — only comfort suppressed

	# Very low energy → suppress arousal tags
	var energy: float = _network.get_activation("drive_energy")
	if energy < 20.0:
		suppression["body"] = 0.3  # less whole-body activation when exhausted

	return suppression

func _apply_conditioning() -> void:
	## Place-emotion conditioning: inject phantom quality activations
	## based on what happened at this location in the past.
	if _memory == null:
		return

	# Check if current location has negative associations
	# (tagged events with threat/danger/flee at this location)
	var threat_memory: float = _memory.get_place_threat_level() if _memory.has_method("get_place_threat_level") else 0.0

	if threat_memory > 0.1:
		# Phantom somatic activation — body remembers what happened here
		_nudge("q_prickling", threat_memory * 3.0)
		_nudge("q_tight", threat_memory * 2.0)
		_nudge("q_churning", threat_memory * 1.5)

	# Positive place conditioning
	var comfort_memory: float = _memory.get_place_comfort_level() if _memory.has_method("get_place_comfort_level") else 0.0

	if comfort_memory > 0.3:
		_nudge("q_settled", comfort_memory * 2.0)
		_nudge("q_warm", comfort_memory * 1.5)

	# Phase 7 §7.2 — entity-specific phantom activation now flows from
	# identity-appraisal decoded tokens (Python side) via `nudge_quality`
	# push commands handled in npc_brain.process_server_commands. The old
	# memory-lookup path (`get_entity_threat_levels` over hand-authored
	# threat levels) is retired: emergent appraisal state replaces an
	# authored table, which is the core premise of draft-3 (§7.2).

# =========================================================================
# DEBUG
# =========================================================================

func get_debug_state() -> Dictionary:
	if _network == null:
		return {}
	var active_qualities: Array = []
	for neuron in _network.neurons:
		if neuron["type"] == "quality" and neuron["activation"] > 20.0:
			active_qualities.append({
				"id": neuron["id"],
				"tag": neuron.get("tag_text", ""),
				"activation": neuron["activation"],
				"regions": neuron.get("regions", []),
				"age": neuron["age"],
			})
	active_qualities.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["activation"] > b["activation"]
	)
	return {
		"tags": last_tags,
		"active_qualities": active_qualities.slice(0, 10),
		"compound_count": _network._compound_quality_count,
	}
