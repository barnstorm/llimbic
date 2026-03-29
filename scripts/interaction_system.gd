extends Node
## res://scripts/interaction_system.gd — Player chat dialogue with NPCs

const INTERACT_RANGE: float = 48.0

var _player: Node = null
var _inference_client: Node = null
var _active_npc: Node = null
var _conversation_history: Array = []  # [{speaker: String, text: String}]
var _waiting_for_reply: bool = false

# UI nodes
var _chat_layer: CanvasLayer = null
var _chat_panel: PanelContainer = null
var _message_scroll: ScrollContainer = null
var _message_container: VBoxContainer = null
var _input_field: LineEdit = null
var _npc_name_label: Label = null
var _close_hint: Label = null

func _ready() -> void:
	call_deferred("_setup")

func _setup() -> void:
	var main: Node = get_parent()
	if main:
		_player = main.get_node_or_null("Player")
	for child in get_tree().root.get_children():
		if child.name == "InferenceClient":
			_inference_client = child
			break
	_build_chat_ui()

func _build_chat_ui() -> void:
	# CanvasLayer so it renders on top
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 20
	_chat_layer.visible = false
	add_child(_chat_layer)

	# Dark overlay behind panel
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.4)
	overlay.anchors_preset = Control.PRESET_FULL_RECT
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_chat_layer.add_child(overlay)

	# Chat panel — right side of screen
	_chat_panel = PanelContainer.new()
	_chat_panel.position = Vector2(780, 60)
	_chat_panel.size = Vector2(460, 600)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.14, 0.95)
	style.border_color = Color(0.3, 0.5, 0.7, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	_chat_panel.add_theme_stylebox_override("panel", style)
	_chat_layer.add_child(_chat_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_chat_panel.add_child(vbox)

	# NPC name header
	_npc_name_label = Label.new()
	_npc_name_label.text = "NPC Name"
	_npc_name_label.add_theme_font_size_override("font_size", 18)
	_npc_name_label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	_npc_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_npc_name_label)

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Color(0.3, 0.4, 0.5))
	vbox.add_child(sep)

	# Message scroll area
	_message_scroll = ScrollContainer.new()
	_message_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_message_scroll.custom_minimum_size = Vector2(0, 420)
	vbox.add_child(_message_scroll)

	_message_container = VBoxContainer.new()
	_message_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message_container.add_theme_constant_override("separation", 6)
	_message_scroll.add_child(_message_container)

	# Input area
	var input_hbox := HBoxContainer.new()
	input_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(input_hbox)

	_input_field = LineEdit.new()
	_input_field.placeholder_text = "Type your message..."
	_input_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_field.add_theme_font_size_override("font_size", 13)
	_input_field.text_submitted.connect(_on_text_submitted)
	input_hbox.add_child(_input_field)

	var send_btn := Button.new()
	send_btn.text = "Send"
	send_btn.custom_minimum_size = Vector2(60, 0)
	send_btn.pressed.connect(_on_send_pressed)
	input_hbox.add_child(send_btn)

	# Close hint
	_close_hint = Label.new()
	_close_hint.text = "Press Escape to leave"
	_close_hint.add_theme_font_size_override("font_size", 11)
	_close_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_close_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_close_hint)

func _unhandled_input(event: InputEvent) -> void:
	if _chat_layer == null:
		return
	if _chat_layer.visible:
		# Chat is open — block game movement/interaction inputs
		# Using _unhandled_input so LineEdit gets keys first via _gui_input
		if event.is_action_pressed("ui_cancel"):
			_close_chat()
			get_viewport().set_input_as_handled()
		elif event.is_action("move_up") or event.is_action("move_down") or event.is_action("move_left") or event.is_action("move_right") or event.is_action("interact"):
			get_viewport().set_input_as_handled()
	else:
		if event.is_action_pressed("interact"):
			_try_interact()

func _try_interact() -> void:
	if _player == null:
		return

	var closest_npc: Node = null
	var closest_dist: float = INTERACT_RANGE

	for npc in get_tree().get_nodes_in_group("npcs"):
		var dist: float = _player.global_position.distance_to(npc.global_position)
		if dist < closest_dist:
			closest_dist = dist
			closest_npc = npc

	if closest_npc and closest_npc.has_method("interact_with_player"):
		_open_chat(closest_npc)

func _open_chat(npc: Node) -> void:
	_active_npc = npc
	_conversation_history.clear()
	_chat_layer.visible = true

	# Pause player movement
	get_tree().paused = false  # Don't pause the tree, just block inputs

	# NPC faces player
	if npc.has_method("face_toward") and _player:
		npc.face_toward(_player.global_position)

	# Set header
	_npc_name_label.text = "%s (%s)" % [npc.npc_name, npc.role]

	# Clear old messages
	for child in _message_container.get_children():
		child.queue_free()

	# NPC opening line — request via Layer 3
	_waiting_for_reply = true
	_request_npc_greeting()

	# Focus the input field
	_input_field.call_deferred("grab_focus")

func _close_chat() -> void:
	_chat_layer.visible = false

	# Let NPC resume
	if _active_npc and is_instance_valid(_active_npc):
		if _active_npc.has_method("end_conversation"):
			_active_npc.end_conversation()
		# Record conversation in NPC memory
		if _active_npc.brain and _conversation_history.size() > 0:
			var summary: String = "Had a conversation with the player"
			if _conversation_history.size() >= 2:
				var last_player_msg: String = ""
				for msg in _conversation_history:
					if msg["speaker"] == "Player":
						last_player_msg = msg["text"]
				if last_player_msg != "":
					summary = "Player said: \"%s\"" % last_player_msg.substr(0, 50)
			_active_npc.brain.memory.add_tagged_event(summary, 0.7, ["conversation", "player"])

	_active_npc = null
	_conversation_history.clear()
	_waiting_for_reply = false

func _on_text_submitted(text: String) -> void:
	_send_player_message(text)

func _on_send_pressed() -> void:
	_send_player_message(_input_field.text)

func _send_player_message(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty() or _waiting_for_reply:
		return
	if _active_npc == null or not is_instance_valid(_active_npc):
		_close_chat()
		return

	# Add player message to history
	_conversation_history.append({"speaker": "Player", "text": text})
	_add_message_bubble("Player", text, true)
	_input_field.text = ""

	# Broadcast player speech to nearby NPCs for hearing
	if _player:
		for npc in get_tree().get_nodes_in_group("npcs"):
			if npc == _active_npc:
				continue
			if npc.brain:
				npc.brain.hear_speech("Player", text, _player.global_position, npc.global_position)

	# Request NPC reply
	_waiting_for_reply = true
	_add_typing_indicator()
	_request_npc_reply(text)

func _request_npc_greeting() -> void:
	if _active_npc == null or _active_npc.brain == null:
		_on_chat_response(false, {"utterance": "...", "mood_shift": "neutral"})
		return

	# Use the existing dialogue endpoint for the opening line
	var brain = _active_npc.brain
	var emo_summary: String = ""
	if brain.layer2:
		emo_summary = brain.layer2.get_emotion_summary()
	var trust_val: float = brain.memory.get_trust("Player")
	var rel_context: String = "Trust: %.2f" % trust_val
	var recent: Array = brain.memory.get_recent_events_text(3)

	if _inference_client:
		_inference_client.layer3_dialogue(
			_active_npc.role, emo_summary, rel_context, recent,
			func(success: bool, data: Dictionary) -> void:
				_waiting_for_reply = false
				var utterance: String = data.get("utterance", "Hello there.")
				_conversation_history.append({"speaker": _active_npc.npc_name, "text": utterance})
				_remove_typing_indicator()
				_add_message_bubble(_active_npc.npc_name, utterance, false)
				# Speak out loud so nearby NPCs hear
				if is_instance_valid(_active_npc):
					_active_npc.speak(utterance)
		)
	else:
		_waiting_for_reply = false
		var fallback: String = "Hello there, traveler."
		_conversation_history.append({"speaker": _active_npc.npc_name, "text": fallback})
		_add_message_bubble(_active_npc.npc_name, fallback, false)

func _request_npc_reply(player_text: String) -> void:
	if _active_npc == null or _active_npc.brain == null:
		_on_chat_response(false, {"utterance": "...", "mood_shift": "neutral"})
		return

	var brain = _active_npc.brain
	var emo_summary: String = ""
	if brain.layer2:
		emo_summary = brain.layer2.get_emotion_summary()
	var trust_val: float = brain.memory.get_trust("Player")
	var rel_context: String = "Trust: %.2f" % trust_val
	var recent: Array = brain.memory.get_recent_events_text(3)

	if _inference_client:
		_inference_client.layer3_chat(
			_active_npc.role, _active_npc.npc_name, emo_summary,
			rel_context, recent, _conversation_history, player_text,
			_on_chat_response
		)
	else:
		push_warning("InteractionSystem: No inference client found")
		_on_chat_response(false, {"utterance": "...", "mood_shift": "neutral"})

func _on_chat_response(success: bool, data: Dictionary) -> void:
	_waiting_for_reply = false
	_remove_typing_indicator()

	if _active_npc == null or not is_instance_valid(_active_npc):
		return

	var utterance: String = data.get("utterance", "Hmm...")
	var mood_shift: String = data.get("mood_shift", "neutral")

	_conversation_history.append({"speaker": _active_npc.npc_name, "text": utterance})
	_add_message_bubble(_active_npc.npc_name, utterance, false)

	# Speak out loud so nearby NPCs hear
	_active_npc.speak(utterance)

	# Apply mood shift to trust
	var trust_delta: float = 0.0
	match mood_shift:
		"pleased", "amused":
			trust_delta = 0.03
		"curious":
			trust_delta = 0.01
		"annoyed", "suspicious":
			trust_delta = -0.02
		"nervous":
			trust_delta = -0.01
	if trust_delta != 0.0 and _active_npc.brain:
		_active_npc.brain.memory.update_relationship("Player", trust_delta, "Conversation mood: " + mood_shift)

	# Focus input for next message
	_input_field.call_deferred("grab_focus")

func _add_message_bubble(speaker: String, text: String, is_player: bool) -> void:
	var bubble := PanelContainer.new()
	var bubble_style := StyleBoxFlat.new()
	if is_player:
		bubble_style.bg_color = Color(0.15, 0.3, 0.5, 0.9)
		bubble.size_flags_horizontal = Control.SIZE_SHRINK_END
	else:
		bubble_style.bg_color = Color(0.2, 0.2, 0.25, 0.9)
		bubble.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bubble_style.set_corner_radius_all(8)
	bubble_style.set_content_margin_all(8)
	bubble.add_theme_stylebox_override("panel", bubble_style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	bubble.add_child(vbox)

	# Speaker name
	var name_label := Label.new()
	name_label.text = speaker
	name_label.add_theme_font_size_override("font_size", 10)
	name_label.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0) if is_player else Color(0.9, 0.7, 0.3))
	vbox.add_child(name_label)

	# Message text
	var msg_label := Label.new()
	msg_label.text = text
	msg_label.add_theme_font_size_override("font_size", 13)
	msg_label.add_theme_color_override("font_color", Color.WHITE)
	msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	msg_label.custom_minimum_size = Vector2(350, 0)
	vbox.add_child(msg_label)

	_message_container.add_child(bubble)

	# Auto-scroll to bottom
	await get_tree().process_frame
	_message_scroll.scroll_vertical = int(_message_scroll.get_v_scroll_bar().max_value)

func _add_typing_indicator() -> void:
	var label := Label.new()
	label.name = "TypingIndicator"
	label.text = "..."
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_message_container.add_child(label)

func _remove_typing_indicator() -> void:
	var indicator := _message_container.get_node_or_null("TypingIndicator")
	if indicator:
		indicator.queue_free()
