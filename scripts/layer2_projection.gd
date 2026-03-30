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

var _npc_name: String = ""
var _npc_role: String = ""
var _emotion_engine: RefCounted = null

var _persona: Dictionary = {}

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
	## Synchronous emotion + modulation update. No LLM, no async. Runs every tick.
	if _emotion_engine == null:
		return
	emotion_vector = _emotion_engine.compute_emotions(layer1_state, recent_events, emotion_vector)
	emotion_summary_text = ""  # clear cached text, recomputed on demand
	_update_top_dimensions()
	_compute_valence()
	modulation = _emotion_engine.compute_modulation(emotion_vector, chunk_priority)

func update(delta: float, layer1_state: Dictionary, recent_events: Array, inference_client: Node) -> void:
	## Legacy async path — still functional but no longer the primary path.
	## Called if deterministic engine is not available.
	update_deterministic(layer1_state, recent_events, 0.5)

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
