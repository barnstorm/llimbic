extends CharacterBody2D
## res://scripts/npc_controller.gd — NPC with three-layer AI, plan-driven movement

@export var npc_name: String = ""
@export var role: String = ""
@export var speed: float = 80.0
@export var character_sheet_path: String = ""

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var name_label: Label = $NameLabel

var brain: RefCounted = null  # NPCBrain

var _nav_manager: Node = null
var _game_manager: Node = null
var _inference_client: Node = null
var _nav_ready: bool = false
var _current_path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _facing: String = "down"

enum State { IDLE, WALKING, ARRIVED, TALKING, CONVERSING }
var _state: int = State.IDLE

var _arrived_timer: float = 0.0
var _arrived_duration: float = 0.0
var _chunk_start_time: float = 0.0

# Speech bubble
var _speech_label: Label = null
var _speech_timer: float = 0.0

# Valence indicator (colored circle above head)
var _valence_indicator: Node2D = null

# Layer 2 update timer
var _l2_timer: float = 0.0

# Nearby NPC tracking
var _nearby_npc_count: int = 0

func _ready() -> void:
	# Find autoloads
	for child in get_tree().root.get_children():
		if child.name == "NavigationManager":
			_nav_manager = child
		elif child.name == "GameManager":
			_game_manager = child
		elif child.name == "InferenceClient":
			_inference_client = child

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

	# Initialize brain
	var BrainScript: GDScript = load("res://scripts/npc_brain.gd")
	brain = BrainScript.new()
	brain.setup(npc_name, role)
	brain.set_autoloads(_inference_client, _game_manager)

	# Create speech bubble label
	_speech_label = Label.new()
	_speech_label.name = "SpeechBubble"
	_speech_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speech_label.position = Vector2(-60, -55)
	_speech_label.size = Vector2(120, 40)
	_speech_label.add_theme_font_size_override("font_size", 10)
	_speech_label.add_theme_color_override("font_color", Color.WHITE)
	_speech_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_speech_label.add_theme_constant_override("shadow_offset_x", 1)
	_speech_label.add_theme_constant_override("shadow_offset_y", 1)
	_speech_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_speech_label.visible = false
	add_child(_speech_label)

	# Create valence indicator (a small circle drawn as a ColorRect)
	_valence_indicator = Node2D.new()
	_valence_indicator.name = "ValenceIndicator"
	_valence_indicator.position = Vector2(0, -45)
	_valence_indicator.visible = false
	add_child(_valence_indicator)

	# Add to npcs group for easy lookup
	add_to_group("npcs")

	# Start first plan chunk
	_state = State.IDLE
	_pick_plan_destination()

func _on_nav_ready() -> void:
	_nav_ready = true
	_pick_plan_destination()

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
	if brain == null:
		return

	# Perception: FOV vision + hearing (replaces simple proximity)
	var all_npcs: Array = get_tree().get_nodes_in_group("npcs")
	brain.update_perception(_facing, global_position, all_npcs)
	_nearby_npc_count = brain.get_visible_npc_count()

	# Layer 1: every tick
	brain.update_layer1(delta, global_position, _nearby_npc_count)

	# Layer 2: medium cadence (staggered per NPC to avoid request spikes)
	_l2_timer += delta
	if _l2_timer >= 2.0:
		_l2_timer = randf_range(0.0, 0.5)  # stagger next update
		brain.update_layer2(delta)

	# Layer 3: triggered by game time (handled via plan checks)
	var hour: float = 6.0
	if _game_manager:
		hour = _game_manager.current_hour
	brain.update_layer3(hour)

	# Speech bubble timer
	if _speech_timer > 0.0:
		_speech_timer -= delta
		if _speech_timer <= 0.0 and _speech_label:
			_speech_label.visible = false
			if _state == State.TALKING:
				_state = State.IDLE
				_pick_plan_destination()
			# CONVERSING state is ended by social_propagation, not speech timer

	match _state:
		State.IDLE:
			_pick_plan_destination()
		State.WALKING:
			_follow_path(delta)
		State.ARRIVED:
			_arrived_timer -= delta
			if _arrived_timer <= 0.0:
				brain.on_chunk_completed()
				_state = State.IDLE
		State.TALKING:
			velocity = Vector2.ZERO
			if sprite and sprite.sprite_frames:
				var idle_name: String = "idle_" + _facing
				if sprite.animation != StringName(idle_name):
					sprite.play(StringName(idle_name))
		State.CONVERSING:
			velocity = Vector2.ZERO
			if sprite and sprite.sprite_frames:
				var idle_name: String = "idle_" + _facing
				if sprite.animation != StringName(idle_name):
					sprite.play(StringName(idle_name))

func _pick_plan_destination() -> void:
	if not _nav_ready or _nav_manager == null or brain == null:
		return

	var target_world: Vector2 = brain.get_target_position()
	# Add some randomness to avoid all NPCs going to exact same pixel
	target_world += Vector2(randf_range(-16, 16), randf_range(-16, 16))

	_current_path = _nav_manager.get_nav_path(global_position, target_world)

	if _current_path.size() < 2:
		# Can't path there — try again soon
		_state = State.IDLE
		brain.on_path_blocked()
		# Fall back: advance to next chunk
		brain.on_chunk_completed()
		return

	_path_index = 1
	_state = State.WALKING
	brain.layer1.start_task()

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
	_state = State.ARRIVED
	_current_path = PackedVector2Array()
	_path_index = 0

	if sprite and sprite.sprite_frames:
		var idle_name: String = "idle_" + _facing
		sprite.play(StringName(idle_name))

	# Determine how long to stay based on plan chunk
	var chunk: Dictionary = brain.layer3.get_current_chunk()
	var duration_hours: float = chunk.get("duration", 2.0)
	# Convert game hours to real seconds: 1 game-minute = 1 real-second (at time_scale=1)
	# duration is in game-hours, so duration * 60 game-minutes = duration * 60 real-seconds
	# That's way too long for gameplay. Scale it down: each plan chunk lasts 10-30 real seconds
	_arrived_duration = clampf(duration_hours * 5.0, 8.0, 30.0)
	_arrived_timer = _arrived_duration

	brain.on_arrived_at_destination()

func interact_with_player() -> void:
	## Called by InteractionSystem when player opens chat near this NPC
	if _state == State.TALKING or _state == State.CONVERSING:
		return
	_state = State.CONVERSING
	velocity = Vector2.ZERO

	# Record the interaction in memory
	if brain:
		brain.memory.add_tagged_event("Player initiated conversation", 0.5, ["interaction", "player"])
		if brain.layer1.task_momentum > 0.3:
			brain.layer1.apply_interruption()
			brain.memory.update_relationship("Player", -0.02, "Interrupted my work")

func show_speech(text: String) -> void:
	if _speech_label:
		_speech_label.text = text
		_speech_label.visible = true
		_speech_timer = 4.0

func get_valence_color() -> Color:
	if brain and brain.layer2:
		return brain.layer2.get_valence_color()
	return Color(0.9, 0.9, 0.2)  # yellow default

func set_valence_visible(vis: bool) -> void:
	if _valence_indicator:
		_valence_indicator.visible = vis

func face_toward(target_pos: Vector2) -> void:
	"""Turn to face a position."""
	var dir: Vector2 = target_pos - global_position
	if abs(dir.x) > abs(dir.y):
		_facing = "right" if dir.x > 0 else "left"
	else:
		_facing = "down" if dir.y > 0 else "up"
	if sprite and sprite.sprite_frames:
		sprite.play(StringName("idle_" + _facing))

func start_conversation(other_npc: Node) -> void:
	"""Called by social propagation to initiate a face-to-face conversation."""
	if _state == State.TALKING or _state == State.CONVERSING:
		return
	_state = State.CONVERSING
	velocity = Vector2.ZERO
	face_toward(other_npc.global_position)

func end_conversation() -> void:
	"""Called when conversation finishes."""
	if _state == State.CONVERSING:
		_state = State.IDLE
		_pick_plan_destination()

func speak(text: String) -> void:
	"""Say something out loud. Shows bubble and broadcasts to nearby NPCs for hearing."""
	show_speech(text)
	# Broadcast to all NPCs in hearing range
	for npc in get_tree().get_nodes_in_group("npcs"):
		if npc == self:
			continue
		if npc.brain:
			npc.brain.hear_speech(npc_name, text, global_position, npc.global_position)
