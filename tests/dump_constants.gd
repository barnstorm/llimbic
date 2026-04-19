extends SceneTree
## res://tests/dump_constants.gd — Headless dumper for the F10 parity test.
##
## Usage:
##   godot --headless --quit --script res://tests/dump_constants.gd
##
## Reads data/perception_constants.json directly (does NOT rely on the
## PerceptionConstants autoload — autoloads are not loaded for SceneTree
## scripts). Prints the parsed dict as a single-line JSON to stdout, prefixed
## with the marker "PARITY_DUMP:" so the Python test can fish it out cleanly
## even if Godot prints other diagnostic noise to stdout.

const CONSTANTS_PATH: String = "res://data/perception_constants.json"
const MARKER: String = "PARITY_DUMP:"

func _init() -> void:
	var f := FileAccess.open(CONSTANTS_PATH, FileAccess.READ)
	if f == null:
		push_error("[dump_constants] Failed to open %s" % CONSTANTS_PATH)
		quit(1)
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[dump_constants] %s is not a JSON object" % CONSTANTS_PATH)
		quit(1)
		return
	var out: String = JSON.stringify(parsed)
	print("%s%s" % [MARKER, out])
	quit(0)
