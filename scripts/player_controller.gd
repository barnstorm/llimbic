extends CharacterBody2D
## res://scripts/player_controller.gd — Player movement with animated sprite

@export var speed: float = 120.0

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

var _nav_manager: Node = null
var _facing: String = "down"

func _ready() -> void:
	# Find NavigationManager autoload
	for child in get_tree().root.get_children():
		if child.name == "NavigationManager":
			_nav_manager = child
			break

	_setup_sprite_frames("res://assets/characters/Character_RM_001.png")

	add_to_group("player")

	# Place player at a good starting position (near center of town)
	position = Vector2(2240, 1600)

func _setup_sprite_frames(sheet_path: String) -> void:
	var sheet: Texture2D = load(sheet_path)
	if sheet == null:
		push_error("Failed to load character sheet: " + sheet_path)
		return

	var frames := SpriteFrames.new()
	# Remove default animation
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")

	# RPG Maker VX Ace: 576x384 sheet, 12 cols x 8 rows, 48x48 frames
	# First character is top-left 3x4 block (cols 0-2, rows 0-3)
	# Row 0 = down, Row 1 = left, Row 2 = right, Row 3 = up
	var directions: Array[String] = ["down", "left", "right", "up"]
	var frame_w: int = 48
	var frame_h: int = 48

	for dir_idx in range(4):
		var dir_name: String = directions[dir_idx]
		# Walk animation
		var walk_name: String = "walk_" + dir_name
		frames.add_animation(StringName(walk_name))
		frames.set_animation_speed(StringName(walk_name), 6.0)
		frames.set_animation_loop(StringName(walk_name), true)
		for col in range(3):
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(col * frame_w, dir_idx * frame_h, frame_w, frame_h)
			frames.add_frame(StringName(walk_name), atlas)

		# Idle animation (just frame 1 — the middle/standing frame)
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

func _physics_process(_delta: float) -> void:
	var input_dir: Vector2 = Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down")

	if input_dir.length() > 0.1:
		# Determine facing direction
		if abs(input_dir.x) > abs(input_dir.y):
			_facing = "right" if input_dir.x > 0 else "left"
		else:
			_facing = "down" if input_dir.y > 0 else "up"

		# Check if target tile is walkable
		var target_pos: Vector2 = global_position + input_dir.normalized() * speed * _delta
		if _nav_manager and _nav_manager.has_method("is_walkable"):
			var target_tile: Vector2i = _nav_manager.world_to_tile(target_pos)
			if not _nav_manager.is_walkable(target_tile):
				# Try sliding along axes
				var slide_x: Vector2 = global_position + Vector2(input_dir.x, 0).normalized() * speed * _delta
				var slide_y: Vector2 = global_position + Vector2(0, input_dir.y).normalized() * speed * _delta
				var tile_x: Vector2i = _nav_manager.world_to_tile(slide_x)
				var tile_y: Vector2i = _nav_manager.world_to_tile(slide_y)
				if abs(input_dir.x) > 0.1 and _nav_manager.is_walkable(tile_x):
					input_dir = Vector2(input_dir.x, 0).normalized()
				elif abs(input_dir.y) > 0.1 and _nav_manager.is_walkable(tile_y):
					input_dir = Vector2(0, input_dir.y).normalized()
				else:
					input_dir = Vector2.ZERO

		velocity = input_dir.normalized() * speed
		var anim_name: String = "walk_" + _facing
		if sprite.animation != StringName(anim_name):
			sprite.play(StringName(anim_name))
	else:
		velocity = Vector2.ZERO
		var idle_name: String = "idle_" + _facing
		if sprite.animation != StringName(idle_name):
			sprite.play(StringName(idle_name))

	move_and_slide()
