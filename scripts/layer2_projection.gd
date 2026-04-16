extends RefCounted
## res://scripts/layer2_projection.gd — Layer 2 projection via limbic model + local emotion engine
## Fast path: EmotionEngine runs every tick (deterministic, zero latency)
## Slow path: Limbic server corrects every ~2s (trained model, context-aware)

const EMOTION_LABELS: Array[String] = [
	"admiration", "amusement", "approval", "caring", "desire",
	"excitement", "gratitude", "joy", "love", "optimism",
	"pride", "relief", "anger", "annoyance", "disappointment",
	"disapproval", "disgust", "embarrassment", "fear", "grief",
	"nervousness", "remorse", "sadness", "confusion", "curiosity",
	"realization", "surprise"
]

# 27-dim GoEmotions vector (0.0-1.0 each)
var emotion_vector: Array = []

# Top dimensions for display
var top_dimensions: Array = []  # [{name, value}, ...]
var valence_summary: String = "neutral"
var emotion_summary_text: String = ""

# Modulation params (from southbound calls)
var modulation: Dictionary = {
	"learning_rate_mod": 1.0,
	"exploration_bias": 0.0,
	"attention_weight": 1.0,
	"interruption_sensitivity": 0.5,
	"persistence_scale": 1.0
}

# Limbic model outputs (new — from trained model)
var limbic_emotions: Dictionary = {}      # {emotion_name: intensity}
var limbic_attention: Array = []          # ["threat_source", "escape_route", ...]
var limbic_drives: Dictionary = {}        # {drive_name: intensity}
var limbic_last_update: int = 0           # ticks_msec of last limbic response

var _npc_name: String = ""
var _npc_role: String = ""
var _emotion_engine: RefCounted = null
var _persona: Dictionary = {}

# Async limbic call state
var _limbic_pending: bool = false

# Log callback — set by brain to pipe limbic events to per-NPC log
var on_limbic_event: Callable = Callable()

func setup(npc_name: String, role: String, persona: Dictionary = {}) -> void:
	_npc_name = npc_name
	_npc_role = role
	_persona = persona
	# Initialize with persona baseline or neutral vector
	var LoaderScript: GDScript = load("res://scripts/persona_loader.gd")
	emotion_vector = LoaderScript.get_emotion_baseline_vector(persona) if not persona.is_empty() else []
	if emotion_vector.size() != 27:
		emotion_vector.clear()
		for i in range(27):
			emotion_vector.append(0.1)
	# Create deterministic emotion engine
	var EngineScript: GDScript = load("res://scripts/emotion_engine.gd")
	_emotion_engine = EngineScript.new()
	_emotion_engine.setup(emotion_vector.duplicate())
	_update_top_dimensions()

func update_deterministic(layer1_state: Dictionary, recent_events: Array, chunk_priority: float) -> void:
	## Fast path: synchronous emotion + modulation update. Runs every tick.
	## When the server thought loop has recently pushed an emotion vector (limbic_last_update fresh),
	## the deterministic engine interpolates toward it rather than computing from scratch.
	if _emotion_engine == null:
		return

	var server_fresh: bool = is_limbic_fresh(3000)  # server pushed within 3 seconds
	if server_fresh:
		# Gently interpolate toward current vector (server is authoritative)
		# The deterministic engine only provides smooth frame-to-frame continuity
		var det_vec: Array = _emotion_engine.compute_emotions(layer1_state, recent_events, emotion_vector)
		for i in range(mini(emotion_vector.size(), det_vec.size())):
			emotion_vector[i] = emotion_vector[i] * 0.9 + det_vec[i] * 0.1
	else:
		# Server unavailable — deterministic engine runs standalone
		emotion_vector = _emotion_engine.compute_emotions(layer1_state, recent_events, emotion_vector)

	emotion_summary_text = ""
	_update_top_dimensions()
	_compute_valence()
	modulation = _emotion_engine.compute_modulation(emotion_vector, chunk_priority)

func request_limbic_update(layer1_state: Dictionary, recent_events: Array, inference_client: Node) -> void:
	## Slow path: async call to limbic server. Called every ~2s by controller.
	## On response, overrides emotion_vector with trained model output.
	if _limbic_pending:
		return
	if inference_client == null or not inference_client.is_layer2_available():
		return
	_limbic_pending = true
	inference_client.layer2_project(layer1_state, recent_events, emotion_vector, _on_limbic_response)

func _on_limbic_response(success: bool, data: Dictionary) -> void:
	_limbic_pending = false
	if not success or data.is_empty():
		if on_limbic_event.is_valid():
			on_limbic_event.call("LIMBIC FAIL: %s" % [str(data).left(80)])
		return
	# Override emotion vector with limbic model output (already blended server-side)
	var new_vec: Array = data.get("vector", [])
	if new_vec.size() == 27:
		emotion_vector = new_vec
		_update_top_dimensions()
		_compute_valence()
		emotion_summary_text = data.get("summary", "")

	# Store limbic-specific outputs
	limbic_emotions = data.get("emotions", {})
	limbic_attention = data.get("attention", [])
	limbic_drives = data.get("drives", {})
	limbic_last_update = Time.get_ticks_msec()

	# Log
	if on_limbic_event.is_valid():
		var emo_str: String = ""
		for k in limbic_emotions:
			emo_str += "%s=%.2f " % [k, limbic_emotions[k]]
		var attn_str: String = ", ".join(limbic_attention.slice(0, 3))
		var drv_str: String = ""
		for k in limbic_drives:
			drv_str += "%s=%.2f " % [k, limbic_drives[k]]
		on_limbic_event.call("LIMBIC: %s| attn=[%s] | drv=[%s]" % [emo_str, attn_str, drv_str])

func update(delta: float, layer1_state: Dictionary, recent_events: Array, inference_client: Node) -> void:
	## Legacy async path — still functional but no longer the primary path.
	## Called if deterministic engine is not available.
	update_deterministic(layer1_state, recent_events, 0.5)

func is_limbic_fresh(max_age_ms: int = 5000) -> bool:
	## Returns true if limbic data was updated within max_age_ms.
	if limbic_last_update == 0:
		return false
	return (Time.get_ticks_msec() - limbic_last_update) < max_age_ms

func _update_top_dimensions() -> void:
	top_dimensions.clear()
	var indexed: Array = []
	for i in range(emotion_vector.size()):
		indexed.append({"idx": i, "val": emotion_vector[i]})
	indexed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["val"] > b["val"])
	for i in range(mini(3, indexed.size())):
		var entry: Dictionary = indexed[i]
		var idx: int = entry["idx"]
		top_dimensions.append({"name": EMOTION_LABELS[idx], "value": entry["val"]})

func _compute_valence() -> void:
	# Positive emotions: indices 0-11, negative: 12-22, neutral/cognitive: 23-26
	var positive: float = 0.0
	var negative: float = 0.0
	for i in range(12):
		positive += emotion_vector[i]
	for i in range(12, 23):
		negative += emotion_vector[i]
	if positive > negative * 1.5:
		valence_summary = "positive"
	elif negative > positive * 1.5:
		if negative > 3.0:
			valence_summary = "distressed"
		else:
			valence_summary = "negative"
	else:
		valence_summary = "neutral"

func get_emotion_summary() -> String:
	if emotion_summary_text != "":
		return emotion_summary_text
	var parts: Array = []
	for dim in top_dimensions:
		parts.append(str(dim["name"]) + "=" + "%.2f" % dim["value"])
	return ", ".join(parts) if parts.size() > 0 else "neutral"

func get_valence_color() -> Color:
	match valence_summary:
		"positive":
			return Color(0.2, 0.8, 0.2)  # green
		"neutral":
			return Color(0.9, 0.9, 0.2)  # yellow
		"negative":
			return Color(0.9, 0.6, 0.1)  # orange
		"distressed":
			return Color(0.9, 0.2, 0.2)  # red
		_:
			return Color(0.9, 0.9, 0.2)
