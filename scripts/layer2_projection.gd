extends RefCounted
## res://scripts/layer2_projection.gd — Layer 2 projection/modulation via HTTP
## Medium cadence: ~every 0.5 game-seconds

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

var _projection_timer: float = 0.0
var _projection_interval: float = 0.5
var _pending_projection: bool = false
var _npc_name: String = ""
var _npc_role: String = ""

func setup(npc_name: String, role: String) -> void:
	_npc_name = npc_name
	_npc_role = role
	# Initialize with neutral vector
	emotion_vector.clear()
	for i in range(27):
		emotion_vector.append(0.1)
	# Slight role-based bias
	match role:
		"Baker":
			emotion_vector[7] = 0.4  # joy
			emotion_vector[3] = 0.3  # caring
		"Guard":
			emotion_vector[10] = 0.3  # pride
			emotion_vector[18] = 0.2  # fear (vigilance)
		"Herbalist":
			emotion_vector[3] = 0.4  # caring
			emotion_vector[24] = 0.3  # curiosity
		"Courier":
			emotion_vector[5] = 0.3  # excitement
			emotion_vector[9] = 0.3  # optimism
		"Blacksmith":
			emotion_vector[10] = 0.4  # pride
			emotion_vector[0] = 0.2  # admiration
		"Gossip":
			emotion_vector[24] = 0.5  # curiosity
			emotion_vector[26] = 0.3  # surprise
		"Farmer":
			emotion_vector[11] = 0.3  # relief
			emotion_vector[9] = 0.3  # optimism
		"Innkeeper":
			emotion_vector[1] = 0.3  # amusement
			emotion_vector[7] = 0.3  # joy
	_update_top_dimensions()

func update(delta: float, layer1_state: Dictionary, recent_events: Array, inference_client: Node) -> void:
	_projection_timer += delta
	if _projection_timer >= _projection_interval and not _pending_projection:
		_projection_timer = 0.0
		_request_projection(layer1_state, recent_events, inference_client)

func _request_projection(layer1_state: Dictionary, recent_events: Array, inference_client: Node) -> void:
	if inference_client == null or not inference_client.is_server_available():
		return
	_pending_projection = true
	inference_client.layer2_project(layer1_state, recent_events, emotion_vector, _on_projection_result)

func _on_projection_result(success: bool, data: Dictionary) -> void:
	_pending_projection = false
	if not success:
		return
	if data.has("vector") and data["vector"] is Array:
		var new_vec: Array = data["vector"]
		if new_vec.size() == 27:
			emotion_vector = new_vec
	if data.has("summary"):
		emotion_summary_text = str(data["summary"])
	if data.has("top_dimensions"):
		top_dimensions = data["top_dimensions"]
	else:
		_update_top_dimensions()
	if data.has("valence"):
		var val: Dictionary = data["valence"]
		if val.has("label"):
			valence_summary = str(val["label"])
		else:
			_compute_valence()
	else:
		_compute_valence()

func request_modulation(directives: String, inference_client: Node) -> void:
	if inference_client == null or not inference_client.is_server_available():
		return
	inference_client.layer2_modulate(directives, emotion_vector, _on_modulation_result)

func _on_modulation_result(success: bool, data: Dictionary) -> void:
	if not success:
		return
	for key in ["learning_rate_mod", "exploration_bias", "attention_weight", "interruption_sensitivity", "persistence_scale"]:
		if data.has(key):
			modulation[key] = clampf(float(data[key]), 0.0, 3.0)

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
