extends CharacterBody2D
## res://scripts/npc_controller.gd — NPC body controlled by brain action selection

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
var _facing: String = "down"

# Pathfinding state (used by move_toward, flee_from, wander)
var _current_path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _path_target: Vector2 = Vector2.ZERO  # what we pathed to, for change detection

# Action execution state
var _action_type: String = ""
var _observe_timer: float = 0.0  # countdown for observe action
var _wander_timer: float = 0.0
var _wander_subtarget: Vector2 = Vector2.ZERO

# External lock: conversation/interaction systems take over
var _externally_locked: bool = false

# Speech bubble
var _speech_label: Label = null
var _speech_timer: float = 0.0

# Valence indicator
var _valence_indicator: Node2D = null

# Layer 2 update timer
var _l2_timer: float = 0.0

# Nearby NPC tracking
var _nearby_npc_count: int = 0

func _ready() -> void:
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

	# Speech bubble
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

	# Valence indicator
	_valence_indicator = Node2D.new()
	_valence_indicator.name = "ValenceIndicator"
	_valence_indicator.position = Vector2(0, -45)
	_valence_indicator.visible = false
	add_child(_valence_indicator)

	add_to_group("npcs")

	# Stagger startup
	_l2_timer = randf_range(0.0, 2.0)

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
	if not _nav_ready or brain == null:
		return

	# --- Update brain layers (unchanged cadences) ---

	# Perception
	var all_npcs: Array = get_tree().get_nodes_in_group("npcs")
	brain.update_perception(_facing, global_position, all_npcs)
	_nearby_npc_count = brain.get_visible_npc_count()

	# Layer 1: every tick
	brain.update_layer1(delta, global_position, _nearby_npc_count)

	# Layer 2: medium cadence
	_l2_timer += delta
	if _l2_timer >= 2.0:
		_l2_timer = randf_range(0.0, 0.5)
		brain.update_layer2(delta)

	# Layer 3: triggered by game time
	var hour: float = 6.0
	if _game_manager:
		hour = _game_manager.current_hour
	brain.update_layer3(hour)

	# Speech bubble timer
	if _speech_timer > 0.0:
		_speech_timer -= delta
		if _speech_timer <= 0.0 and _speech_label:
			_speech_label.visible = false

	# --- External lock: conversation/interaction takes priority ---
	if _externally_locked:
		velocity = Vector2.ZERO
		_play_idle()
		move_and_slide()
		return

	# --- Brain selects action, controller executes ---
	var action: Dictionary = brain.select_action(delta)
	_execute_action(action, delta)

func _execute_action(action: Dictionary, delta: float) -> void:
	var atype: String = action.get("type", "idle")

	match atype:
		"move_toward":
			var target: Vector2 = action.get("target", Vector2.ZERO)
			# Only re-path if target changed significantly or we have no path
			if _current_path.is_empty() or _action_type != "move_toward" or target.distance_to(_path_target) > 32.0:
				_start_path_to(target)
			if not _current_path.is_empty():
				_follow_path(delta, action.get("speed_mul", 1.0))
			else:
				# Can't path — notify brain
				var should_give_up: bool = brain.on_path_blocked()
				if should_give_up:
					brain.on_chunk_completed()

		"pause":
			velocity = Vector2.ZERO
			_play_idle()
			move_and_slide()

		"observe":
			velocity = Vector2.ZERO
			var target_pos: Vector2 = action.get("target", global_position)
			face_toward(target_pos)
			move_and_slide()

		"flee_from":
			var target: Vector2 = action.get("target", Vector2.ZERO)
			if _current_path.is_empty() or _action_type != "flee_from":
				_start_path_to(target)
			if not _current_path.is_empty():
				_follow_path(delta, action.get("speed_mul", 1.4))
			else:
				# Can't path to flee target — just move directly away
				var flee_dir: Vector2 = (target - global_position).normalized()
				velocity = flee_dir * speed * 1.4
				_update_facing(flee_dir)
				_play_walk()
				move_and_slide()

		"wander":
			_do_wander(delta, action)

		_:  # "idle" or unknown
			velocity = Vector2.ZERO
			_play_idle()
			move_and_slide()

	_action_type = atype

func _start_path_to(target: Vector2) -> void:
	if _nav_manager == null:
		return
	# Small random offset to avoid NPCs converging on exact same pixel
	var jittered: Vector2 = target + Vector2(randf_range(-8, 8), randf_range(-8, 8))
	_current_path = _nav_manager.get_nav_path(global_position, jittered)
	_path_target = target
	_path_index = 1 if _current_path.size() > 1 else 0

func _follow_path(delta: float, speed_mul: float) -> void:
	if _path_index >= _current_path.size():
		_current_path = PackedVector2Array()
		velocity = Vector2.ZERO
		_play_idle()
		move_and_slide()
		return

	var target: Vector2 = _current_path[_path_index]
	var direction: Vector2 = target - global_position
	var dist: float = direction.length()

	if dist < 4.0:
		_path_index += 1
		if _path_index >= _current_path.size():
			_current_path = PackedVector2Array()
			velocity = Vector2.ZERO
			_play_idle()
			move_and_slide()
			return
		target = _current_path[_path_index]
		direction = target - global_position

	direction = direction.normalized()
	_update_facing(direction)

	velocity = direction * speed * speed_mul
	_play_walk()
	move_and_slide()

func _do_wander(delta: float, action: Dictionary) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0 or _current_path.is_empty():
		var center: Vector2 = action.get("target", global_position)
		_wander_subtarget = center + Vector2(randf_range(-48, 48), randf_range(-48, 48))
		_start_path_to(_wander_subtarget)
		_wander_timer = randf_range(2.0, 5.0)
	if not _current_path.is_empty():
		_follow_path(delta, action.get("speed_mul", 0.4))
	else:
		# Can't wander there, just idle briefly
		velocity = Vector2.ZERO
		_play_idle()
		move_and_slide()
		_wander_timer = 0.5  # try a new spot soon

func _update_facing(direction: Vector2) -> void:
	if abs(direction.x) > abs(direction.y):
		_facing = "right" if direction.x > 0 else "left"
	else:
		_facing = "down" if direction.y > 0 else "up"

func _play_idle() -> void:
	if sprite and sprite.sprite_frames:
		var idle_name: String = "idle_" + _facing
		if sprite.animation != StringName(idle_name):
			sprite.play(StringName(idle_name))

func _play_walk() -> void:
	if sprite and sprite.sprite_frames:
		var anim_name: String = "walk_" + _facing
		if sprite.animation != StringName(anim_name):
			sprite.play(StringName(anim_name))

# --- External interface (conversation, interaction, speech) ---

func interact_with_player() -> void:
	## Called by InteractionSystem when player opens chat near this NPC
	if _externally_locked:
		return
	_externally_locked = true
	velocity = Vector2.ZERO

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
	return Color(0.9, 0.9, 0.2)

func set_valence_visible(vis: bool) -> void:
	if _valence_indicator:
		_valence_indicator.visible = vis

func face_toward(target_pos: Vector2) -> void:
	var dir: Vector2 = target_pos - global_position
	if dir.length() < 1.0:
		return
	_update_facing(dir)
	_play_idle()

func start_conversation(other_npc: Node) -> void:
	## Called by social propagation to initiate a face-to-face conversation.
	if _externally_locked:
		return
	_externally_locked = true
	velocity = Vector2.ZERO
	face_toward(other_npc.global_position)

func end_conversation() -> void:
	## Called when conversation finishes.
	_externally_locked = false
	_current_path = PackedVector2Array()  # force re-path on next action

func speak(text: String) -> void:
	## Say something out loud. Shows bubble and broadcasts to nearby NPCs for hearing.
	show_speech(text)
	for npc in get_tree().get_nodes_in_group("npcs"):
		if npc == self:
			continue
		if npc.brain:
			npc.brain.hear_speech(npc_name, text, global_position, npc.global_position)
