extends CharacterBody2D
## res://scripts/npc_controller.gd — NPC body controlled by brain action selection

@export var npc_name: String = ""
@export var role: String = ""
@export var speed: float = 80.0
@export var character_sheet_path: String = ""

# Phase 2 / F9 — canonical entity_id (data/entity_id_protocol.md). Stable
# UUID-like identifier independent of display name. Per-entity Hebbian neurons
# (sense_visible_{entity_id}, appr_identity_{entity_id}) key off this, so
# renames (stranger → "Mabel") don't fragment the neuron family.
#
# For now: deterministic SHA256-prefix of npc_name. This gives a stable id
# without needing save-file infrastructure: same npc_name → same id, every
# run, every machine. Real save-persisted UUIDs become the source of truth in
# a future PR; consumers don't change because they always read .entity_id.
var _entity_id_cache: String = ""

func entity_id() -> String:
	if _entity_id_cache != "":
		return _entity_id_cache
	if npc_name == "":
		return ""
	var hashed: PackedByteArray = npc_name.sha256_buffer()
	var hex: String = ""
	for i in range(8):
		hex += "%02x" % hashed[i]
	_entity_id_cache = "ent_" + hex
	return _entity_id_cache

# External-mind firewall: world-object ids (e.g. "bakery_oven_01") embed a
# location name + object identity — static-world naming that must NOT cross the
# measured-only wire (docs/PROTOCOL.md; LCAEC spec §8). Emit an opaque token
# instead, using the exact same SHA256-prefix scheme as entity_id() so both
# vision-id families are indistinguishable on the wire. The body keeps the
# real id in _obj_id_by_hash for reverse-resolution of inbound primitive
# target_ids (see _apply_mind_primitive).
func _opaque_object_id(raw_id: String) -> String:
	if raw_id == "":
		return ""
	var hashed: PackedByteArray = raw_id.sha256_buffer()
	var hex: String = ""
	for i in range(8):
		hex += "%02x" % hashed[i]
	return "obj_" + hex

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var name_label: Label = $NameLabel

var brain: RefCounted = null  # NPCBrain

var _nav_manager: Node = null
var _game_manager: Node = null
var _inference_client: Node = null
var _world_object_registry: Node = null
var _world_labels: Node = null
var _stimulus_registry: Node = null
var _mind: Node = null  # MindLink autoload (external-mind mode; null/dormant when unused)
var _nav_ready: bool = false
var _facing: String = "down"

# --- External-mind mode (see scripts/mind_link.gd, docs/PROTOCOL.md) ---
# Per-NPC monotonically increasing observation sequence. The mind echoes it back
# on the matching act so lockstep can pair obs<->act. Instrumentation only —
# never consumed as a control signal.
var _obs_seq: int = 0
# Last velocity we applied under external control, for the lockstep hold_last
# timeout policy.
var _mind_last_velocity: Vector2 = Vector2.ZERO
# Distance actually moved on the last externally-controlled step (post-collision),
# surfaced in the next obs's proprio.actual_movement — the stall/slip signal.
var _mind_last_actual_movement: float = 0.0
# Re-entrancy guard: because the lockstep branch `await`s inside
# _physics_process, the engine keeps invoking _physics_process on subsequent
# physics frames while a prior coroutine is still suspended. This flag enforces
# the lockstep "one obs in flight per NPC" contract — new frames early-out
# until the in-flight obs/act cycle resolves.
var _mind_awaiting: bool = false
# Reverse map obj_<hash> -> real world-object id, populated as objects are
# emitted in vision. Lets an inbound primitive target_id (which the mind echoes
# back as the opaque token it saw) resolve to the real id body-side. Bounded by
# the number of distinct objects ever seen (world objects are a small fixed set).
var _obj_id_by_hash: Dictionary = {}

# Pathfinding state (used by move_toward, flee_from, wander)
var _current_path: PackedVector2Array = PackedVector2Array()
var _path_index: int = 0
var _path_target: Vector2 = Vector2.ZERO  # what we pathed to, for change detection

# Action execution state
var _action_type: String = ""
var _repath_cooldown: float = 0.0  # avoid re-pathing every frame on sustained contact
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

# Footstep stimulus state
var _footstep_timer: float = 0.0
var _footstep_interval: float = 0.8  # emit footstep every 0.8s while moving

# Nearby NPC tracking
var _nearby_npc_count: int = 0

# State snapshot for thought loop
var _snapshot_timer: float = 0.0
var _snapshot_interval: float = 2.0  # send state to server every 2 real seconds

func _ready() -> void:
	for child in get_tree().root.get_children():
		if child.name == "NavigationManager":
			_nav_manager = child
		elif child.name == "GameManager":
			_game_manager = child
		elif child.name == "InferenceClient":
			_inference_client = child
		elif child.name == "WorldObjectRegistry":
			_world_object_registry = child
		elif child.name == "WorldLabelSystem":
			_world_labels = child
		elif child.name == "StimulusRegistry":
			_stimulus_registry = child
		elif child.name == "MindLink":
			_mind = child

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
	brain.set_autoloads(_inference_client, _game_manager, _world_object_registry)
	# Pass SensorSystem for hearing pipeline
	var _sensor_system_node: Node = null
	for child in get_tree().root.get_children():
		if child.name == "SensorSystem":
			_sensor_system_node = child
			break
	if _sensor_system_node:
		brain.set_sensor_autoloads(_sensor_system_node)

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
	_snapshot_timer = randf_range(0.0, 2.0)  # stagger snapshots across NPCs

	# Connect to server push signal for thought loop commands
	if _inference_client and _inference_client.has_signal("server_push_received"):
		_inference_client.server_push_received.connect(_on_server_push)

	# Register this NPC with the server thought loop
	_register_with_server.call_deferred()

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

	# --- External-mind mode (structural firewall — see docs/PROTOCOL.md) ---
	# For NPCs the mind controls, Godot is a pure I/O boundary: keep perception
	# (a sensor, not cognition), emit a MEASURED observation, apply the MOTOR
	# action the mind returns, and BYPASS the in-Godot cognitive stack
	# (update_layer1/2/3 + select_action). Uncontrolled NPCs fall through to the
	# normal brain path below unchanged.
	if _mind and _mind.is_active() and _mind.is_controlled(npc_name):
		# Lockstep: skip frames while a prior obs/act cycle is still awaiting, so
		# we never have two observations in flight for this NPC at once.
		if _mind_awaiting:
			return
		var ext_all_npcs: Array = get_tree().get_nodes_in_group("npcs")
		var ext_player: Node = get_tree().get_first_node_in_group("player")
		brain.update_perception(_facing, global_position, ext_all_npcs, ext_player)  # keep — sensor, not cognition
		var obs: Dictionary = _build_clean_observation(delta)
		_mind.send_obs(npc_name, obs)
		var act: Dictionary
		if _mind.sync_mode() == "lockstep":
			_mind_awaiting = true
			act = await _mind.await_act(npc_name, obs["seq"], _mind.deadline_ms())
			_mind_awaiting = false
		else:
			act = _mind.latest_act(npc_name)
		_apply_mind_action(act, delta)
		return  # bypass brain.update_layer1/2/3 + select_action for controlled NPCs

	# --- Update brain layers (unchanged cadences) ---

	# Perception — NPCs see everything in their FOV: other NPCs and the player
	var all_npcs: Array = get_tree().get_nodes_in_group("npcs")
	var player: Node = get_tree().get_first_node_in_group("player")
	brain.update_perception(_facing, global_position, all_npcs, player)
	_nearby_npc_count = brain.get_visible_npc_count()

	# Layer 1 + L2 emotions + modulation: every tick (closed loop)
	brain.update_layer1(delta, global_position, _nearby_npc_count)

	# Layer 2 limbic: async call every ~5 real seconds (only when thought loop is NOT active)
	# When the thought loop runs, it handles L2 coloring server-side and pushes emotions
	if not brain.is_thought_loop_active():
		_l2_timer += delta
		if _l2_timer >= 5.0:
			_l2_timer = 0.0
			brain.update_layer2(delta)

	# Layer 3: triggered by game time (+ urgency replans from L1)
	var hour: float = 6.0
	if _game_manager:
		hour = _game_manager.current_hour
	brain.update_layer3(hour)

	# Speech bubble timer
	if _speech_timer > 0.0:
		_speech_timer -= delta
		if _speech_timer <= 0.0 and _speech_label:
			_speech_label.visible = false

	# Send state snapshot to server thought loop
	_snapshot_timer += delta
	if _snapshot_timer >= _snapshot_interval:
		_snapshot_timer = 0.0
		_send_state_snapshot()

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

		"observe", "examine":
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

		"speak":
			# Adventure-command SAY: emit speech then idle
			var speech_text: String = action.get("text", "")
			if speech_text and _action_type != "speak":
				speak(speech_text)
			velocity = Vector2.ZERO
			_play_idle()
			move_and_slide()

		"give":
			# OFFER / SHOW / GIVE — display the gesture and emit a social
			# stimulus so the recipient (and bystanders) can perceive it.
			var item_name: String = action.get("item_name", action.get("item_id", "something"))
			var social_target: String = action.get("target", "")
			var social_act: String = action.get("social_act", "give")
			var verb: String = "gives"
			match social_act:
				"offer": verb = "offers"
				"show": verb = "shows"
				_: verb = "gives"
			var gesture: String = "%s %s %s to %s" % [npc_name, verb, item_name, social_target]
			if _action_type != "give":
				show_speech("*" + gesture + "*")
				if _stimulus_registry:
					var my_eid_soc: String = entity_id() if has_method("entity_id") else ""
					_stimulus_registry.emit(
						"speech", global_position, 160.0, 0.7, 3.0,
						["social", social_act, item_name.to_lower(), social_target, gesture],
						npc_name, my_eid_soc,
					)
			velocity = Vector2.ZERO
			_play_idle()
			move_and_slide()

		"wander":
			_do_wander(delta, action)

		_:  # "idle" or unknown
			velocity = Vector2.ZERO
			_play_idle()
			move_and_slide()

	_action_type = atype

# --- External-mind mode: clean observation builder + motor-only applier ------
#
# These are the body's half of the frozen wire contract (docs/PROTOCOL.md). They
# are used ONLY for NPCs the mind controls; uncontrolled NPCs never touch them.
# The existing _send_state_snapshot() (the CURRENT, cognition-polluted snapshot)
# is left intact for a later phase — controlled NPCs simply don't call it.

# v2: a speech transcript crosses only when heard clearly enough (body-side
# measurement gate; below this the utterance crosses as "").
const TRANSCRIPT_CLARITY_MIN: float = 0.5

func _build_clean_observation(delta: float) -> Dictionary:
	## Whitelisting sibling of _send_state_snapshot(). Emits ONLY measured
	## channels — no cognition-derived fields ever cross. This is the structural
	## firewall: we build the dict key-by-key rather than spreading any brain
	## state dict, so an emotion/appraisal/somatic field cannot leak in even by
	## accident. The Python side rejects unknown keys, so a leak would fail loud.
	_obs_seq += 1

	# --- Kinematics (from the CharacterBody2D substrate) ---
	var heading_vec: Vector2 = _facing_to_vector(_facing)
	var kinematics: Dictionary = {
		"pos": [global_position.x, global_position.y],
		"vel": [velocity.x, velocity.y],
		"heading": [heading_vec.x, heading_vec.y],
	}

	# --- Vision (raw numeric fields + v2 perceptual class token; DROP names) ---
	# `kind` is a classifier output ("what class of thing"), never an identity:
	# entities -> npc|player, world objects -> object:<category>. Objects were
	# omitted in v1 as a simplification, not a firewall rule — merged here.
	var vision: Array = []
	if brain.perception:
		for entity in brain.perception.visible_entities:
			var epos: Vector2 = entity.get("position", global_position)
			var to_ent: Vector2 = epos - global_position
			var dir: Vector2 = to_ent.normalized() if to_ent.length() > 0.0001 else Vector2.ZERO
			vision.append({
				"id": entity.get("id", ""),
				"dist": entity.get("distance", 0.0),
				"dir": [dir.x, dir.y],
				"exposure": entity.get("exposure", 1.0),
				"confidence": entity.get("confidence", 1.0),
				"kind": "player" if entity.get("id", "") == "ent_player" else "npc",
			})
		for obj in brain.perception.visible_objects:
			var opos: Vector2 = obj.get("position", global_position)
			var to_obj: Vector2 = opos - global_position
			var odir: Vector2 = to_obj.normalized() if to_obj.length() > 0.0001 else Vector2.ZERO
			var otype: String = str(obj.get("type", ""))
			# Firewall: cross an opaque token, not the plaintext semantic id.
			var oraw: String = str(obj.get("id", ""))
			var ohash: String = _opaque_object_id(oraw)
			if ohash != "":
				_obj_id_by_hash[ohash] = oraw
			vision.append({
				"id": ohash,
				"dist": obj.get("distance", 0.0),
				"dir": [odir.x, odir.y],
				"exposure": obj.get("exposure", 1.0),
				"confidence": obj.get("confidence", 1.0),
				"kind": "object:" + (otype if otype != "" else "unknown"),
			})

	# --- Hearing (read the raw HearingResults for this tick, which carry the
	# numeric channels the persistent heard buffer lacks). v2 adds `transcript`:
	# what a microphone+ASR measures of a speech stimulus — the text rides the
	# stimulus tags ([type, "dialogue", text]) and is gated by clarity, so a
	# barely-heard utterance crosses as "" (degraded measurement, like real ears).
	var hearing: Array = []
	if brain.perception:
		for hr in brain.perception.last_hearing_results:
			var hdir: Vector2 = hr.get("direction", Vector2.ZERO)
			var est: Vector2 = hr.get("estimated_source_pos", Vector2.ZERO)
			var est_src: Variant = null
			if est != Vector2.ZERO:
				est_src = [est.x, est.y]
			var transcript: String = ""
			if hr.get("stimulus_type", "") == "speech" and float(hr.get("clarity", 0.0)) >= TRANSCRIPT_CLARITY_MIN:
				var tags: Array = hr.get("tags", [])
				if tags.size() >= 3:
					transcript = str(tags[2])
			hearing.append({
				"emitter_eid": hr.get("emitter_eid", ""),
				"dir": [hdir.x, hdir.y],
				"perceived_volume": hr.get("perceived_volume", 1.0),
				"clarity": hr.get("clarity", 1.0),
				"est_src": est_src,
				"transcript": transcript,
			})

	# --- Drives: EXACTLY the four measured homeostatic channels. get_state_dict()
	# also returns arousal/task_momentum/frustration/vagal_state/salience etc.,
	# which are cognition-derived — we whitelist the four and remap social_need
	# -> social. NEVER spread get_state_dict() wholesale. ---
	var drives: Dictionary = {"energy": 0.0, "hunger": 0.0, "social": 0.0, "safety": 0.0}
	if brain.layer1:
		var l1: Dictionary = brain.layer1.get_state_dict()
		drives = {
			"energy": l1.get("energy", 0.0),
			"hunger": l1.get("hunger", 0.0),
			"social": l1.get("social_need", 0.0),  # key is social_need body-side
			"safety": l1.get("safety", 0.0),
		}

	# --- Proprio / stall channel (from update_progress) ---
	var proprio: Dictionary = {
		"intended_speed": 0.0,
		"actual_movement": 0.0,
		"is_stalled": false,
	}
	if brain.layer1:
		proprio["is_stalled"] = brain.layer1.is_stalled
		proprio["intended_speed"] = _mind_last_velocity.length()
		proprio["actual_movement"] = _mind_last_actual_movement

	# --- Abort scaffold (readout only; not wired to a real bound yet) ---
	var abort: Dictionary = {"active": false, "kind": ""}

	# --- Clock (v2): game-world time — sun position / a wall clock is a sensor ---
	var clock: Variant = null
	if _game_manager:
		clock = {
			"hour": float(_game_manager.current_hour),
			"day": int(_game_manager.current_day),
		}

	return {
		"t": "obs",
		"npc": npc_name,
		"seq": _obs_seq,
		"t_emit": Time.get_unix_time_from_system(),
		"tick": Engine.get_physics_frames(),
		"dt": delta,
		"kinematics": kinematics,
		"vision": vision,
		"hearing": hearing,
		"drives": drives,
		"proprio": proprio,
		"abort": abort,
		"clock": clock,
	}

func _apply_mind_action(act: Dictionary, delta: float) -> void:
	## Motor-only applier for controlled NPCs (replaces _execute_action). Applies
	## a desired velocity and/or a body-side interaction primitive. Drive changes
	## happen body-side as world side-effects of primitives — never via a wire
	## value (there is no such wire field).
	##
	## On an empty/timeout act, apply the on_timeout policy (hold_last or
	## zero_vel). The determinism contract is defined over (seq, applied-state),
	## so an act-less frame still resolves to a well-defined applied velocity.
	if act.is_empty():
		var mode: String = _mind.on_timeout() if _mind else "hold_last"
		if mode == "zero_vel":
			velocity = Vector2.ZERO
		else:  # hold_last
			velocity = _mind_last_velocity
		_apply_velocity_and_progress(delta)
		return

	# Velocity command (clamped to the NPC's own max speed as v_max). `vel` takes
	# precedence; when it is absent, apply the first step of a receding horizon
	# (the body applies horizon[0] and re-requests each step — docs/PROTOCOL.md).
	if act.get("vel", null) != null:
		var v: Array = act["vel"]
		velocity = Vector2(v[0], v[1]).limit_length(speed)
		_apply_velocity_and_progress(delta)
	elif act.get("horizon", null) != null and act["horizon"] is Array and act["horizon"].size() > 0:
		var h0: Variant = act["horizon"][0]
		if h0 is Array and h0.size() == 2:
			velocity = Vector2(h0[0], h0[1]).limit_length(speed)
			_apply_velocity_and_progress(delta)

	# Body-side interaction primitive (optional; may accompany a vel command).
	var prim: Variant = act.get("primitive", null)
	if prim != null and prim is Dictionary:
		_apply_mind_primitive(prim)

	# v3 actuation echo: this act (by seq) just actuated the body, so report
	# t_apply on the body clock — the mind server pairs it with obs.t_emit for
	# the true sensing->actuation delay (§10). MindLink dedupes re-applications;
	# timeout/empty acts returned early above and correctly echo nothing.
	if _mind and act.has("seq"):
		_mind.report_applied(npc_name, int(act["seq"]))

func _apply_velocity_and_progress(delta: float) -> void:
	## Shared motor path: face + animate, move, then feed the proprioceptive/stall
	## channel (reuses brain.layer1.update_progress, the same channel the normal
	## _follow_path uses). Bypasses AStar and path jitter entirely.
	if velocity.length() > 0.01:
		_update_facing(velocity.normalized())
		_play_walk()
	else:
		_play_idle()
	var pos_before: Vector2 = global_position
	# Capture the COMMANDED motion before the walkable-space revert can zero
	# it: the stall channel is intended-vs-actual, so a reverted step must
	# report intended > 0 with actual ~ 0 — that is what makes is_stalled
	# assert (update_progress treats intended < 1.0 as a voluntary idle and
	# RESETS the stall tracker) and what crosses the wire in proprio. Reading
	# velocity after the revert silenced the stall channel exactly when it
	# should fire: the mind saw a voluntary idle instead of a wall.
	var commanded_velocity: Vector2 = velocity
	move_and_slide()
	# §5/§10 body-side safety bound, ENTRY-DENIAL semantics: externally-
	# commanded motion may never do what native motion wouldn't. Natives only
	# ever TARGET walkable tiles (AStar discipline) but can legitimately stand
	# on / escape blocked ground (spawns sit inside blocked regions, e.g. the
	# town-square plaza — the navgrid is a routing layer, not a physical one).
	# So: deny entering a blocked tile FROM walkable ground (revert + stall,
	# with intended speed reported so is_stalled asserts), but allow motion
	# while already on blocked ground, exactly as natives escape their spawns.
	# (Landed-tile check; per-step movement is << one tile because velocity is
	# limit_length(speed)-capped, so this catches the wall-passing mode.)
	if _nav_manager and _nav_manager.astar != null:
		var was_walkable: bool = _nav_manager.is_walkable(_nav_manager.world_to_tile(pos_before))
		var now_walkable: bool = _nav_manager.is_walkable(_nav_manager.world_to_tile(global_position))
		if was_walkable and not now_walkable:
			global_position = pos_before
			velocity = Vector2.ZERO
	var actual: float = global_position.distance_to(pos_before)
	if brain and brain.layer1:
		brain.layer1.update_progress(delta, commanded_velocity.length(), actual)
	_mind_last_velocity = commanded_velocity
	_mind_last_actual_movement = actual

func _apply_mind_primitive(prim: Dictionary) -> void:
	## Dispatch a motor-interaction primitive to the existing body-side effect
	## functions. These mutate drives body-side (world side-effect), which is the
	## permitted channel; the mind cannot write drive values directly.
	var kind: String = prim.get("kind", "")
	match kind:
		"face_toward":
			var d: Variant = prim.get("dir", null)
			if d != null and d is Array and d.size() == 2:
				var dir: Vector2 = Vector2(d[0], d[1])
				if dir.length() > 0.0001:
					face_toward(global_position + dir.normalized() * 32.0)
		"consume":
			# Body-side consume effects by item category, mirroring the brain's
			# own path. target_id is the item token; map to a category if we can.
			if brain and brain.has_method("_apply_consume_effects_by_category"):
				# Reverse-resolve the opaque token the mind echoed back to the
				# real world-object id (pass-through if it's already a real id
				# the mind holds from its offline persona schedule).
				var wire_id: String = str(prim.get("target_id", ""))
				var target_id: String = str(_obj_id_by_hash.get(wire_id, wire_id))
				var cat: String = ""
				if brain.has_method("_get_item_category"):
					cat = brain._get_item_category(target_id)
				if cat == "":
					cat = "food"  # default when the token isn't a known item
				brain._apply_consume_effects_by_category(cat)
		"rest":
			if brain and brain.has_method("_handle_rest"):
				brain._handle_rest()
		"speak":
			# v2 motor speech — refused unless this run's hello_ack enabled it
			# (the mind server gates independently; both sides must agree).
			if _mind and _mind.allow_speak():
				var text: String = str(prim.get("text", ""))
				if text != "":
					speak(text.substr(0, 280))
			else:
				push_warning("npc_controller: 'speak' primitive refused (allow_speak=false this run)")
		"interact":
			# Generic interact: no dedicated body-side effect fn exists; the world
			# side-effect (if any) is a future phase. Treated as a no-op motor
			# gesture for now.
			pass
		_:
			pass

func _facing_to_vector(facing: String) -> Vector2:
	match facing:
		"up":
			return Vector2.UP
		"down":
			return Vector2.DOWN
		"left":
			return Vector2.LEFT
		"right":
			return Vector2.RIGHT
		_:
			return Vector2.DOWN

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
	var pos_before: Vector2 = global_position
	move_and_slide()

	# If we collided with a body, re-path around it (once, not every frame)
	_repath_cooldown = maxf(_repath_cooldown - delta, 0.0)
	if get_slide_collision_count() > 0 and _repath_cooldown <= 0.0:
		var collision: KinematicCollision2D = get_slide_collision(0)
		var collider: Object = collision.get_collider()
		if collider is CharacterBody2D and collider != self:
			# Disable the obstacle's tile + immediate neighbors to force a real detour
			var cpos: Vector2 = collider.global_position
			var avoid: Array = [cpos, cpos + Vector2(32, 0), cpos + Vector2(-32, 0), cpos + Vector2(0, 32), cpos + Vector2(0, -32)]
			_current_path = _nav_manager.get_nav_path(global_position, _path_target, avoid) if _nav_manager else PackedVector2Array()
			_path_index = 1 if _current_path.size() > 1 else 0
			_repath_cooldown = 1.0

	# Tell Layer 1 how much progress we actually made
	if brain and brain.layer1:
		var actual_dist: float = global_position.distance_to(pos_before)
		brain.layer1.update_progress(delta, speed * speed_mul, actual_dist)

	# Emit footstep stimuli while moving
	_footstep_timer += delta
	if _footstep_timer >= _footstep_interval:
		_footstep_timer = 0.0
		emit_footstep()

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
	# Face the player so they're in our FOV for perception
	var player: Node = get_tree().get_first_node_in_group("player")
	if player:
		face_toward(player.global_position)

	if brain:
		brain.memory.add_tagged_event("Player initiated conversation", 0.5, ["interaction", "player"], "direct", "player_interaction")
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
	## Say something out loud. Shows bubble and emits a speech stimulus.
	## Nearby NPCs hear via StimulusRegistry + SensorSystem hearing pipeline.
	## Phase 9: emitter_eid carries the canonical F9 entity_id so cross-modal
	## binding can key `sense_heard_{eid}` without fragmenting on display-name
	## changes (stranger→named rebinding).
	show_speech(text)
	var my_eid: String = entity_id() if has_method("entity_id") else ""
	if _stimulus_registry:
		_stimulus_registry.emit(
			"speech", global_position, 160.0, 0.8, 4.0,
			["speech", "dialogue", text.substr(0, 60)], npc_name, my_eid
		)
	else:
		# Fallback: direct hearing broadcast (no stimulus system)
		for npc in get_tree().get_nodes_in_group("npcs"):
			if npc == self:
				continue
			if npc.brain:
				npc.brain.hear_speech(npc_name, text, global_position, npc.global_position)

func emit_footstep() -> void:
	## Emit a low-strength footstep stimulus while moving.
	## Phase 9: emitter_eid forwarded so sense_heard_{eid} keys on footsteps too.
	var my_eid: String = entity_id() if has_method("entity_id") else ""
	if _stimulus_registry:
		_stimulus_registry.emit(
			"footstep", global_position, 48.0, 0.15, 0.5,
			["footstep"], npc_name, my_eid
		)

# --- Thought loop: server push + state snapshots ---

func _on_server_push(push_npc_name: String, commands: Array) -> void:
	## Receive push commands from server thought loop, filtered by NPC name.
	if push_npc_name == npc_name and brain:
		brain.process_server_commands(commands)

func _register_with_server() -> void:
	## Register this NPC with the server thought loop on startup.
	if _inference_client == null or brain == null:
		return
	if not _inference_client.is_layer3_available():
		# Retry after a delay (server may not be up yet)
		get_tree().create_timer(5.0).timeout.connect(_register_with_server)
		return
	_inference_client.register_npc(npc_name, brain._persona)

func _send_state_snapshot() -> void:
	## Send current state to server for thought loop processing.
	## Includes rich perception data — what the NPC actually sees and hears.
	if _inference_client == null or brain == null:
		return
	if not _inference_client.is_layer3_available():
		return

	var hour: float = _game_manager.current_hour if _game_manager else 6.0

	# Perception: only real visible things — other characters (NPCs + player).
	# World is a pre-rendered bitmap with no labeled scenery or objects.
	var visible: Array = []
	if brain.perception:
		for entity in brain.perception.visible_entities:
			var dir: Vector2 = entity.get("position", global_position) - global_position
			var cardinal: String = _direction_name(dir)
			visible.append({
				"id": entity.get("id", ""),
				"name": entity.get("name", "someone"),
				"distance": snapped(entity.get("distance", 0.0) / 32.0, 0.1),
				"direction": cardinal,
				"exposure": entity.get("exposure", 1.0),
			})

	# Recent hearing
	var heard: Array = []
	if brain.perception:
		for h in brain.perception.heard_events:
			heard.append({
				"source": h.get("source", "unknown"),
				# Phase 9 — forward emitter_eid so the server can rank/trace
				# heard percepts per-entity alongside visible. Missing fields
				# fall back to "", which Python treats as "non-entity sound".
				"emitter_eid": h.get("emitter_eid", ""),
				"text": h.get("text", "").substr(0, 80),
				"distance": snapped(h.get("distance", 0.0) / 32.0, 0.1),
			})

	# Visible objects (for adventure-command noun grounding)
	# v2 trace schema preserves state/position/distance/exposure (was lossy in v1).
	var visible_objects: Array = []
	if brain.perception:
		for obj in brain.perception.visible_objects:
			var obj_pos: Vector2 = obj.get("position", Vector2.ZERO)
			visible_objects.append({
				"name": obj.get("name", ""),
				"id": obj.get("id", ""),
				"state": obj.get("state", ""),
				"distance": snapped(obj.get("distance", 0.0) / 32.0, 0.1),
				"position": [obj_pos.x, obj_pos.y],
				"exposure": obj.get("exposure", 1.0),
			})

	# Phase 6/9 — per-entity perception salience. Keyed on eid for every
	# visible entity, visible object, AND heard emitter (Phase 9 brings
	# heard into the unified rank). Missing eids (no sense neuron yet)
	# map to 0.0; Python treats those as tiebreak-fallback via stable
	# ordering.
	var salience_eids: Array = []
	for v in visible:
		var eid: String = String(v.get("id", ""))
		if eid != "":
			salience_eids.append(eid)
	for v in visible_objects:
		var eid2: String = String(v.get("id", ""))
		if eid2 != "":
			salience_eids.append(eid2)
	for h in heard:
		var heid: String = String(h.get("emitter_eid", ""))
		if heid != "" and not salience_eids.has(heid):
			salience_eids.append(heid)
	var perception_salience: Dictionary = {}
	if brain.layer1:
		perception_salience = brain.layer1.get_perception_salience_all(salience_eids)

	var snapshot: Dictionary = {
		"npc_name": npc_name,
		"position": [global_position.x, global_position.y],
		"hour": hour,
		"drives": brain.layer1.get_state_dict() if brain.layer1 else {},
		"somatic_tags": brain.layer1.get_somatic_tags() if brain.layer1 else [],
		"vagal_state": brain.layer1.get_vagal_state() if brain.layer1 else {},
		"emotion_vector": brain.layer2.emotion_vector if brain.layer2 else [],
		"location": brain.layer3.location_name_from_position(global_position) if brain.layer3 else "",
		"scene": _world_labels.describe_location(global_position) if _world_labels else "",
		"current_action": brain.get_current_action(),
		"visible": visible,
		"visible_objects": visible_objects,
		"heard": heard,
		"recent_events": brain.memory.get_recent_events_text(3) if brain.memory else [],
		"active_intentions": brain.active_intentions,
		"carried_items": brain.inventory.get_display_list() if brain.inventory else [],
		"available_items": _get_location_items(),
		"known_locations": brain.memory.get_known_location_names() if brain.memory else [],
		"glimpsed_buildings": _get_glimpsed_buildings(),
		"appraisal": brain.layer1.get_appraisal_payload() if brain.layer1 else {"new_neurons": [], "active": {}},
		"reward_events": brain.layer1.drain_recent_reward_events() if brain.layer1 else [],
		"per_entity_channels": brain.layer1.get_per_entity_channels() if brain.layer1 else {},
		"perception_salience": perception_salience,
		"compounds": brain.layer1.get_compound_state() if brain.layer1 else {"active": {}, "count": 0},
		"cross_modal": brain.layer1.get_cross_modal_state() if brain.layer1 else {"heard": {}, "bind_active": {}},
		"temporal": brain.layer1.get_temporal_state() if brain.layer1 else {"active": {}, "new_neurons": []},
		"intention": brain.layer1.get_intention_state() if brain.layer1 else {"context_neurons": {}, "amplification": {}, "bootstrap_variance": {}},
	}
	_inference_client.send_state_snapshot(snapshot)

func _get_location_items() -> Array:
	## Get display names of takeable items at current location (from world objects).
	var loc: String = brain.layer3.location_name_from_position(global_position) if brain and brain.layer3 else ""
	if loc == "":
		return []
	if _world_object_registry and _world_object_registry.has_method("get_items_at_location"):
		var items: Array = _world_object_registry.get_items_at_location(loc)
		var names: Array = []
		for item in items:
			names.append(item.get("name", ""))
		return names
	return []

func _get_glimpsed_buildings() -> Array:
	## Returns directional info for glimpsed-but-unvisited locations.
	if not brain or not brain.memory:
		return []
	var glimpsed_names: Array = brain.memory.get_glimpsed_location_names()
	if glimpsed_names.is_empty():
		return []
	var L3Script: GDScript = load("res://scripts/layer3_executive.gd")
	L3Script._ensure_locations_loaded()
	var result: Array = []
	for loc_name in glimpsed_names:
		if L3Script.LOCATIONS.has(loc_name):
			var loc_pos: Vector2 = L3Script.LOCATIONS[loc_name]
			var dir: Vector2 = loc_pos - global_position
			var dist_tiles: float = snapped(dir.length() / 32.0, 0.1)
			result.append({
				"direction": _direction_name(dir),
				"distance_tiles": dist_tiles,
			})
	return result

static func _direction_name(dir: Vector2) -> String:
	if dir.length() < 1.0:
		return "here"
	var angle: float = rad_to_deg(atan2(dir.y, dir.x))
	if angle < -157.5 or angle >= 157.5:
		return "west"
	elif angle < -112.5:
		return "northwest"
	elif angle < -67.5:
		return "north"
	elif angle < -22.5:
		return "northeast"
	elif angle < 22.5:
		return "east"
	elif angle < 67.5:
		return "southeast"
	elif angle < 112.5:
		return "south"
	else:
		return "southwest"
