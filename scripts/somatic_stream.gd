extends RefCounted
## res://scripts/somatic_stream.gd — Somatic tag emitter
## Reads Hebbian quality neuron activations + emotion vector.
## Applies suppression (threat kills gut tags) and place-emotion conditioning.
## Outputs a tag swarm: ["gut:empty:churning", "chest:tight", "body:aroused"]
## This is what the LLM reads. This is what the vagal gate reads.
## Nothing above L1 ever sees a float.

var _network: RefCounted = null  # HebbianNetwork reference
var _memory: RefCounted = null   # MemorySystem reference (for place conditioning)

# Emotion vector indices (somatic-relevant subset)
const IDX_FEAR: int = 18
const IDX_ANGER: int = 12
const IDX_DISGUST: int = 16
const IDX_NERVOUSNESS: int = 20
const IDX_GRIEF: int = 19
const IDX_EXCITEMENT: int = 5
const IDX_JOY: int = 7
const IDX_SADNESS: int = 22
const IDX_EMBARRASSMENT: int = 17
const IDX_CURIOSITY: int = 24
const IDX_SURPRISE: int = 26
const IDX_RELIEF: int = 11

# Suppression rules: which regions get suppressed under threat
# When threat tags are active, gut/chest-positive tags are suppressed
const THREAT_SUPPRESSED_QUALITIES: Array = ["settled", "warm", "open", "full", "clear", "loose", "light"]

# Last emitted tags (for debug / comparison)
var last_tags: Array = []
var last_raw_tags: Array = []  # before suppression

func setup(network: RefCounted, memory: RefCounted = null) -> void:
	_network = network
	_memory = memory

func emit(emotion_vector: Array = []) -> Array:
	## Main emission: returns Array of somatic tag strings.
	## Call every tick or every few ticks from layer1_substrate.
	if _network == null:
		return []

	# 1. Apply emotion vector feedback to quality neurons
	#    (Emotions with body correlates directly nudge quality activations)
	if emotion_vector.size() >= 27:
		_apply_emotion_to_qualities(emotion_vector)

	# 2. Compute suppression map
	var suppression: Dictionary = _compute_suppression()

	# 3. Apply place-emotion conditioning (phantom tags)
	_apply_conditioning()

	# 4. Emit tags from quality neurons
	var tags: Array = _network.emit_quality_tags(suppression)

	# 5. Check for compound quality neurogenesis
	_network.check_quality_neurogenesis()

	last_tags = tags
	return tags

func _apply_emotion_to_qualities(emo: Array) -> void:
	## Somatic emotions directly nudge quality neuron activations.
	## These are the emotions that HAVE body correlates.
	## Cortical emotions (admiration, approval, pride...) don't touch qualities.
	var rate: float = 2.0  # nudge strength per tick

	# Fear → tight, pounding, prickling, churning, constricted
	var fear: float = emo[IDX_FEAR]
	if fear > 0.2:
		_nudge("q_tight", fear * rate)
		_nudge("q_pounding", fear * rate * 0.8)
		_nudge("q_prickling", fear * rate)
		_nudge("q_churning", fear * rate * 0.7)
		_nudge("q_constricted", fear * rate * 0.6)

	# Anger → tight, coiled, pressure, raw
	var anger: float = emo[IDX_ANGER]
	if anger > 0.2:
		_nudge("q_tight", anger * rate * 0.7)
		_nudge("q_coiled", anger * rate)
		_nudge("q_pressure", anger * rate * 0.6)
		_nudge("q_raw", anger * rate * 0.5)

	# Disgust → churning, crawling
	var disgust: float = emo[IDX_DISGUST]
	if disgust > 0.2:
		_nudge("q_churning", disgust * rate)
		_nudge("q_crawling", disgust * rate * 0.8)

	# Nervousness → churning, fluttering, dry, prickling
	var nervousness: float = emo[IDX_NERVOUSNESS]
	if nervousness > 0.2:
		_nudge("q_churning", nervousness * rate * 0.6)
		_nudge("q_fluttering", nervousness * rate)
		_nudge("q_dry", nervousness * rate * 0.5)
		_nudge("q_prickling", nervousness * rate * 0.5)

	# Grief → hollow, cold, heavy, constricted
	var grief: float = emo[IDX_GRIEF]
	if grief > 0.2:
		_nudge("q_hollow", grief * rate)
		_nudge("q_cold", grief * rate * 0.7)
		_nudge("q_heavy", grief * rate * 0.8)
		_nudge("q_constricted", grief * rate * 0.5)

	# Joy → warm, light, open
	var joy: float = emo[IDX_JOY]
	if joy > 0.2:
		_nudge("q_warm", joy * rate)
		_nudge("q_light", joy * rate * 0.8)
		_nudge("q_open", joy * rate * 0.7)

	# Excitement → fluttering, buzzing, aroused
	var excitement: float = emo[IDX_EXCITEMENT]
	if excitement > 0.2:
		_nudge("q_fluttering", excitement * rate)
		_nudge("q_buzzing", excitement * rate * 0.7)
		_nudge("q_aroused", excitement * rate * 0.8)

	# Sadness → heavy, foggy, cold
	var sadness: float = emo[IDX_SADNESS]
	if sadness > 0.2:
		_nudge("q_heavy", sadness * rate)
		_nudge("q_foggy", sadness * rate * 0.8)
		_nudge("q_cold", sadness * rate * 0.5)

	# Embarrassment → warm (flushed), churning
	var embarrassment: float = emo[IDX_EMBARRASSMENT]
	if embarrassment > 0.2:
		_nudge("q_warm", embarrassment * rate * 0.5)  # flushed, not cozy
		_nudge("q_churning", embarrassment * rate * 0.6)

	# Relief → loose, settled, open
	var relief: float = emo[IDX_RELIEF]
	if relief > 0.2:
		_nudge("q_loose", relief * rate)
		_nudge("q_settled", relief * rate * 0.7)
		_nudge("q_open", relief * rate * 0.6)

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

	# Entity-specific threat conditioning (the short circuit)
	# When a threatening entity is nearby, the body reacts before the mind decides.
	# These phantom activations feed into vagal_sympathetic via quality→vagal connections.
	if _memory.has_method("get_entity_threat_levels"):
		var entity_threats: Dictionary = _memory.get_entity_threat_levels()
		for entity_name in entity_threats:
			var threat_val: float = entity_threats[entity_name]
			if threat_val > 0.15:
				_nudge("q_prickling", threat_val * 4.0)
				_nudge("q_tight", threat_val * 3.0)
				_nudge("q_coiled", threat_val * 2.0)
				_nudge("q_churning", threat_val * 1.5)

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
