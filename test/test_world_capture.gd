extends SceneTree
## test/test_world_capture.gd — Visual-QA capture harness for the rebuilt world.
##
## Instantiates the main scene and PINS the camera (overriding the follow
## controller) to a configurable world point + zoom, so --write-movie captures a
## stable shot for verifying the tilemap / labels / object markers.
##
## Usage:
##   godot --path . --write-movie screenshots/world/<name>.png \
##         --fixed-fps 5 --quit-after 12 --script res://test/test_world_capture.gd
##
## Env (optional): BURG_SHOT_X / BURG_SHOT_Y / BURG_SHOT_Z (zoom). Default =
## whole-map wide shot centered on the town.

var _main: Node = null
var _cam: Camera2D = null


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_main = packed.instantiate()
	root.add_child(_main)
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _cam == null:
		_cam = _find(_main, "Camera2D") as Camera2D
	if _cam == null:
		return
	# Defaults: map-center wide shot (4480x3200 town in 1280x720).
	var cx: float = 2240.0
	var cy: float = 1600.0
	var cz: float = 0.34
	var sx: String = OS.get_environment("BURG_SHOT_X")
	var sy: String = OS.get_environment("BURG_SHOT_Y")
	var sz: String = OS.get_environment("BURG_SHOT_Z")
	if sx != "":
		cx = float(sx)
	if sy != "":
		cy = float(sy)
	if sz != "":
		cz = float(sz)
	# Pin: runs after camera_controller._process each frame, so we win.
	_cam.global_position = Vector2(cx, cy)
	_cam.zoom = Vector2(cz, cz)
	_cam.position_smoothing_enabled = false


func _find(node: Node, nm: String) -> Node:
	if node.name == nm:
		return node
	for c in node.get_children():
		var r: Node = _find(c, nm)
		if r != null:
			return r
	return null
