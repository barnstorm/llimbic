extends RefCounted
## res://scripts/persona_loader.gd — Loads NPC persona data from JSON files
## Single source of truth: data/npcs/{name}.json

const EMOTION_INDICES: Dictionary = {
	"admiration": 0, "amusement": 1, "approval": 2, "caring": 3, "desire": 4,
	"excitement": 5, "gratitude": 6, "joy": 7, "love": 8, "optimism": 9,
	"pride": 10, "relief": 11, "anger": 12, "annoyance": 13, "disappointment": 14,
	"disapproval": 15, "disgust": 16, "embarrassment": 17, "fear": 18, "grief": 19,
	"nervousness": 20, "remorse": 21, "sadness": 22, "confusion": 23, "curiosity": 24,
	"realization": 25, "surprise": 26
}

static func load_persona(npc_name: String) -> Dictionary:
	var path: String = "res://data/npcs/%s.json" % npc_name.to_lower()
	if not FileAccess.file_exists(path):
		push_warning("PersonaLoader: file not found: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("PersonaLoader: cannot open: %s" % path)
		return {}
	var text: String = file.get_as_text()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_warning("PersonaLoader: JSON parse error in %s: %s" % [path, json.get_error_message()])
		return {}
	var data: Dictionary = json.data
	_apply_defaults(data)
	return data

static func load_all_personas() -> Array[Dictionary]:
	var personas: Array[Dictionary] = []
	var dir := DirAccess.open("res://data/npcs")
	if dir == null:
		push_warning("PersonaLoader: cannot open res://data/npcs/")
		return personas
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			var persona: Dictionary = load_persona(fname.get_basename())
			if not persona.is_empty():
				personas.append(persona)
		fname = dir.get_next()
	return personas

static func load_locations() -> Dictionary:
	var path: String = "res://data/locations.json"
	if not FileAccess.file_exists(path):
		push_warning("PersonaLoader: locations file not found")
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	var text: String = file.get_as_text()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_warning("PersonaLoader: locations JSON error: %s" % json.get_error_message())
		return {}
	return json.data

static func _apply_defaults(data: Dictionary) -> void:
	if not data.has("name"):
		data["name"] = "Unknown"
	if not data.has("role"):
		data["role"] = "Villager"
	if not data.has("personality"):
		data["personality"] = {}
	var p: Dictionary = data["personality"]
	if not p.has("traits"):
		p["traits"] = ["quiet"]
	if not p.has("speech_style"):
		p["speech_style"] = "neutral"
	if not p.has("backstory"):
		p["backstory"] = "A resident of the town."
	if not data.has("schedule"):
		data["schedule"] = [{"location": "town_square", "duration": 4.0, "priority": 0.5, "purpose": "Idle"}]
	if not data.has("emotion_baseline"):
		data["emotion_baseline"] = {}
	if not data.has("drive_defaults"):
		data["drive_defaults"] = {"energy": 80.0, "hunger": 20.0, "social": 30.0, "safety": 80.0}
	if not data.has("neural_biases"):
		data["neural_biases"] = []
	if not data.has("night_behavior"):
		data["night_behavior"] = {"go_home_hour": 21.0, "override": null}
	if not data.has("fallback_dialogue"):
		data["fallback_dialogue"] = {"greeting": "Hello.", "complaint": "Things are tough.", "gossip": "Heard anything?", "busy": "I'm busy."}
	if not data.has("relationships"):
		data["relationships"] = {}
	if not data.has("home_location"):
		data["home_location"] = "town_square"
	if not data.has("work_location"):
		data["work_location"] = "town_square"
	if not data.has("spawn_position"):
		data["spawn_position"] = [2096, 800]

static func get_emotion_baseline_vector(persona: Dictionary) -> Array:
	var vec: Array = []
	for i in range(27):
		vec.append(0.1)
	var baseline: Dictionary = persona.get("emotion_baseline", {})
	for dim_name in baseline:
		if EMOTION_INDICES.has(dim_name):
			vec[EMOTION_INDICES[dim_name]] = float(baseline[dim_name])
	return vec
