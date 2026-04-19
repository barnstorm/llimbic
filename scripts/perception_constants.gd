extends Node
## res://scripts/perception_constants.gd — Tier-2 seed values (autoload).
##
## Loads data/perception_constants.json once at startup. All perception/Hebbian/
## training code that needs a tunable constant reads from here. Never hard-code
## a value that lives in the JSON; the F10 parity test (tests/test_constants_parity.py)
## enforces dual-language access.
##
## Usage:
##   var drift_rate: float = PerceptionConstants.get_value("embedding_bridge.drift_rate")
##   var concepts: Array = PerceptionConstants.get_value("embedding_bridge.bootstrap_concepts")
##
## See docs/perception_implementation_plan.md for the full key list and rationale.

const CONSTANTS_PATH: String = "res://data/perception_constants.json"

var _data: Dictionary = {}
var _loaded: bool = false

func _ready() -> void:
	_load()

func _load() -> void:
	var f := FileAccess.open(CONSTANTS_PATH, FileAccess.READ)
	if f == null:
		push_error("[PerceptionConstants] Failed to open %s" % CONSTANTS_PATH)
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[PerceptionConstants] %s is not a JSON object" % CONSTANTS_PATH)
		return
	_data = parsed
	_loaded = true
	print("[PerceptionConstants] Loaded %d top-level keys from %s" % [_data.size(), CONSTANTS_PATH])

func get_value(dotted_key: String, default_value: Variant = null) -> Variant:
	## Look up a value by dotted path, e.g. "embedding_bridge.drift_rate".
	## Returns default_value if the key is missing.
	if not _loaded:
		return default_value
	var parts: PackedStringArray = dotted_key.split(".")
	var cursor: Variant = _data
	for p in parts:
		if typeof(cursor) != TYPE_DICTIONARY:
			return default_value
		if not (cursor as Dictionary).has(p):
			return default_value
		cursor = (cursor as Dictionary)[p]
	return cursor

func raw() -> Dictionary:
	## Return the full constants dict. Used by the parity-test dumper. Avoid
	## using this in runtime code — prefer get_value() with a dotted key.
	return _data.duplicate(true)

func is_loaded() -> bool:
	return _loaded
