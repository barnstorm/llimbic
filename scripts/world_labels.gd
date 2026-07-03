extends Node2D
## res://scripts/world_labels.gd — On-map location name labels.
##
## Surfaces the 16 town locations (data/locations.json) that WorldLabelSystem
## already parses for NPC cognition but never drew. Each name floats at its
## world position so the player reads "Bakery", "Town Square", etc. directly on
## the board — fixing the "locations are static blobs" problem.
##
## Implementation: static Label nodes (Godot handles rendering + offscreen
## culling; no per-frame _draw needed). z_index = -1 → above every tile layer
## (z -20..-11), below actors (z 0), so an NPC never hides behind a label.
##
## Toggle visibility with the `toggle_labels` input action (default L).

const LOCATIONS_PATH: String = "res://data/locations.json"
const LABEL_W: int = 132
const LABEL_H: int = 18
const FONT_SIZE: int = 13

func _ready() -> void:
	# Above tile layers, below actors. Children inherit relative z.
	z_index = -1
	_build_labels()


func _build_labels() -> void:
	var text: String = FileAccess.get_file_as_string(LOCATIONS_PATH)
	if text == "":
		push_warning("WorldLabels: cannot read %s" % LOCATIONS_PATH)
		return
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or parsed.is_empty():
		push_warning("WorldLabels: %s did not parse" % LOCATIONS_PATH)
		return

	# Group entries by pixel position: Smallville shops are often also homes, so
	# several location keys share one building point. Stack them vertically.
	var by_pos: Dictionary = {}
	var order: Array = []
	for key in parsed:
		var entry: Dictionary = parsed[key]
		var pos_arr: Variant = entry.get("position", [0, 0])
		if not (pos_arr is Array) or pos_arr.size() < 2:
			continue
		var pos: Vector2 = Vector2(float(pos_arr[0]), float(pos_arr[1]))
		var pk: String = "%d,%d" % [int(pos.x), int(pos.y)]
		if not by_pos.has(pk):
			by_pos[pk] = {"pos": pos, "names": []}
			order.append(pk)
		by_pos[pk]["names"].append(_pretty(String(key)))

	for pk in order:
		var g: Dictionary = by_pos[pk]
		var pos: Vector2 = g["pos"]
		var names: Array = g["names"]
		for i in names.size():
			_add_label(pos, String(names[i]), i)


func _add_label(world_pos: Vector2, label_text: String, stack_index: int) -> Label:
	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", FONT_SIZE)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 5)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.size = Vector2(LABEL_W, LABEL_H)
	# Center on the point; stack repeated (co-located) labels above it.
	lbl.position = Vector2(world_pos.x - LABEL_W * 0.5, world_pos.y - 34 - stack_index * (LABEL_H + 2))
	add_child(lbl)
	return lbl


func _pretty(snake: String) -> String:
	# "town_square" -> "Town Square"
	var words: PackedStringArray = snake.split("_")
	var out: String = ""
	for w in words:
		if w.length() > 0:
			out += w[0].to_upper() + w.substr(1) + " "
	return out.strip_edges()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_labels"):
		visible = not visible
