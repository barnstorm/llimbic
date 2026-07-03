extends Node2D
## res://scripts/world_object_markers.gd — Labeled markers for world objects.
##
## Places a colored dot + name label at each of WorldObjectRegistry's objects
## (ovens, anvils, forge, baskets, beds, ...) so the things NPCs perceive are
## finally visible on the board — the core fix for "everything but NPCs is
## unlabeled." Markers are always shown; location names toggle separately (L).
##
## AI semantics are UNCHANGED: perception still reads positions/state from the
## registry (npc_brain.gd update_perception). This node only draws — it never
## feeds back into cognition.
##
## z_index = -1 → above tile layers, below actors. Each dot joins the
## "world_objects" group with its object id/name in metadata (debug/future).

const DOT_R: float = 7.0
const LABEL_W: int = 118
const LABEL_H: int = 16
const FONT_SIZE: int = 11

# Dot color by object category (object "type" field).
const TYPE_COLORS: Dictionary = {
	"tool": Color(0.96, 0.80, 0.30),
	"container": Color(0.74, 0.52, 0.30),
	"supply": Color(0.46, 0.64, 0.96),
	"resource": Color(0.46, 0.82, 0.56),
	"furniture": Color(0.80, 0.56, 0.84),
	"item": Color(0.92, 0.55, 0.55),
}


func _ready() -> void:
	z_index = -1
	_build_markers()


func _build_markers() -> void:
	var registry: Node = get_node_or_null("/root/WorldObjectRegistry")
	if registry == null:
		push_warning("WorldObjectMarkers: WorldObjectRegistry autoload missing")
		return
	if not registry.has_method("get_all_objects"):
		push_warning("WorldObjectMarkers: registry has no get_all_objects()")
		return
	var objects: Array = registry.get_all_objects()
	var placed: int = 0
	for obj in objects:
		if _add_marker(obj):
			placed += 1
	print("[WorldObjectMarkers] placed %d / %d object markers" % [placed, objects.size()])


func _add_marker(obj: Dictionary) -> bool:
	var pos_v: Variant = obj.get("position", null)
	var pos: Vector2
	if pos_v is Vector2:
		pos = pos_v
	elif pos_v is Array and pos_v.size() >= 2:
		pos = Vector2(float(pos_v[0]), float(pos_v[1]))
	else:
		return false

	var oname: String = String(obj.get("name", obj.get("id", "")))
	if oname == "":
		return false
	var otype: String = String(obj.get("type", ""))
	var color: Color = TYPE_COLORS.get(otype, Color(0.85, 0.85, 0.85))

	# Dark halo behind the dot so it reads against any background.
	var halo: Polygon2D = Polygon2D.new()
	halo.polygon = _diamond(pos, DOT_R + 3.0)
	halo.color = Color(0, 0, 0, 0.65)
	halo.z_index = -1  # relative to this container (-1) → behind the dot
	add_child(halo)

	var dot: Polygon2D = Polygon2D.new()
	dot.polygon = _diamond(pos, DOT_R)
	dot.color = color
	dot.z_index = 0
	dot.add_to_group("world_objects")
	dot.set_meta("object_id", String(obj.get("id", "")))
	dot.set_meta("object_name", oname)
	add_child(dot)

	var lbl: Label = Label.new()
	lbl.text = oname
	lbl.add_theme_font_size_override("font_size", FONT_SIZE)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.size = Vector2(LABEL_W, LABEL_H)
	lbl.position = Vector2(pos.x - LABEL_W * 0.5, pos.y + 8)
	add_child(lbl)
	return true


func _diamond(center: Vector2, r: float) -> PackedVector2Array:
	return PackedVector2Array([
		center + Vector2(0, -r),
		center + Vector2(r, 0),
		center + Vector2(0, r),
		center + Vector2(-r, 0),
	])
