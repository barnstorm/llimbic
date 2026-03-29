extends Camera2D
## res://scripts/camera_controller.gd — Smooth follow with map bounds clamping

var _target: Node2D = null
var _initialized: bool = false
var _map_width: float = 4480.0
var _map_height: float = 3200.0

func _ready() -> void:
	# Find the player node
	var player = get_parent().get_node_or_null("Player")
	if player:
		_target = player

	# Set camera limits to map bounds
	limit_left = 0
	limit_top = 0
	limit_right = int(_map_width)
	limit_bottom = int(_map_height)
	limit_smoothed = true

	position_smoothing_enabled = true
	position_smoothing_speed = 8.0

func _physics_process(_delta: float) -> void:
	if _target == null:
		return
	if not _initialized:
		global_position = _target.global_position
		_initialized = true
		reset_smoothing()
	else:
		global_position = _target.global_position
