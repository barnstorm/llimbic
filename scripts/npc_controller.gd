extends CharacterBody2D
## res://scripts/npc_controller.gd — NPC wandering with AStar2D pathfinding

@export var npc_name: String = ""
@export var role: String = ""
@export var speed: float = 80.0
@export var character_sheet_path: String = ""

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var name_label: Label = $NameLabel

var _nav_manager: Node = null
var _nav_ready: bool = false
var _current_path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _idle_timer: float = 0.0
var _facing: String = "down"

enum State { IDLE, WALKING }
var _state: int = State.IDLE

func _ready() -> void:
	# Find NavigationManager autoload
	for child in get_tree().root.get_children():
		if child.name == "NavigationManager":
			_nav_manager = child
			break

	if _nav_manager:
		if _nav_manager.has_signal("navigation_ready"):
			if _nav_manager.astar != null:
				_nav_ready = true
			else:
				_nav_manager.navigation_ready.connect(_on_nav_ready)

	if name_label:
		name_label.text = npc_name

	if character_sheet_path != "":
		_setup_sprite_frames(character_sheet_path)

	# Start with a random idle delay
	_idle_timer = randf_range(0.5, 2.0)
	_state = State.IDLE

func _on_nav_ready() -> void:
	_nav_ready = true

func _setup_sprite_frames(sheet_path: String) -> void:
	var sheet: Texture2D = load(sheet_path)
	if sheet == null:
		push_error("NPC: Failed to load sheet: " + sheet_path)
		return

	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")

	var directions: Array[String] = ["down", "left", "right", "up"]
	var frame_w: int = 48
	var frame_h: int = 48

	for dir_idx in range(4):
		var dir_name: String = directions[dir_idx]
		var walk_name: String = "walk_" + dir_name
		frames.add_animation(StringName(walk_name))
		frames.set_animation_speed(StringName(walk_name), 6.0)
		frames.set_animation_loop(StringName(walk_name), true)
		for col in range(3):
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(col * frame_w, dir_idx * frame_h, frame_w, frame_h)
			frames.add_frame(StringName(walk_name), atlas)

		var idle_name: String = "idle_" + dir_name
		frames.add_animation(StringName(idle_name))
		frames.set_animation_speed(StringName(idle_name), 1.0)
		frames.set_animation_loop(StringName(idle_name), false)
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(1 * frame_w, dir_idx * frame_h, frame_w, frame_h)
		frames.add_frame(StringName(idle_name), atlas)

	sprite.sprite_frames = frames
	sprite.play(&"idle_down")

func _physics_process(delta: float) -> void:
	if not _nav_ready:
		return

	match _state:
		State.IDLE:
			_idle_timer -= delta
			if _idle_timer <= 0.0:
				_pick_new_destination()
		State.WALKING:
			_follow_path(delta)

func _pick_new_destination() -> void:
	if _nav_manager == null:
		_idle_timer = 2.0
		return

	var target_tile: Vector2i = _nav_manager.get_random_walkable_tile()
	var target_world: Vector2 = _nav_manager.tile_to_world(target_tile)
	_current_path = _nav_manager.get_nav_path(global_position, target_world)

	if _current_path.size() < 2:
		_idle_timer = randf_range(1.0, 3.0)
		return

	_path_index = 1  # Skip first point (current position)
	_state = State.WALKING

func _follow_path(delta: float) -> void:
	if _path_index >= _current_path.size():
		_arrive()
		return

	var target: Vector2 = _current_path[_path_index]
	var direction: Vector2 = (target - global_position)
	var dist: float = direction.length()

	if dist < 4.0:
		_path_index += 1
		if _path_index >= _current_path.size():
			_arrive()
			return
		target = _current_path[_path_index]
		direction = (target - global_position)

	direction = direction.normalized()

	# Update facing
	if abs(direction.x) > abs(direction.y):
		_facing = "right" if direction.x > 0 else "left"
	else:
		_facing = "down" if direction.y > 0 else "up"

	velocity = direction * speed
	var anim_name: String = "walk_" + _facing
	if sprite and sprite.sprite_frames and sprite.animation != StringName(anim_name):
		sprite.play(StringName(anim_name))

	move_and_slide()

func _arrive() -> void:
	velocity = Vector2.ZERO
	_state = State.IDLE
	_idle_timer = randf_range(2.0, 5.0)
	_current_path = PackedVector2Array()
	_path_index = 0
	if sprite and sprite.sprite_frames:
		var idle_name: String = "idle_" + _facing
		sprite.play(StringName(idle_name))
