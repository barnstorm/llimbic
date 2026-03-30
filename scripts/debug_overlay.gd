extends CanvasLayer
## res://scripts/debug_overlay.gd — Debug inspection overlay (Tab key toggle)

var _active: bool = false
var _selected_npc: Node = null
var _panel: Control = null
var _name_label: Label = null
var _role_label: Label = null
var _action_label: Label = null
var _l1_container: Control = null
var _l2_heatmap: Control = null
var _l2_top_label: Label = null
var _l3_plan_container: Control = null
var _memory_label: Label = null
var _modulation_label: Label = null
var _l1_bars: Array = []  # [{label: Label, bar: ColorRect, bg: ColorRect}]
var _l2_cells: Array = []  # ColorRect[27]
var _objects_label: Label = null
var _network_label: Label = null
var _fov_draw_node: Node2D = null  # Draws FOV cones in world space

# Emotion labels for heatmap tooltips
const EMOTION_LABELS: Array[String] = [
	"admiration", "amusement", "approval", "caring", "desire",
	"excitement", "gratitude", "joy", "love", "optimism",
	"pride", "relief", "anger", "annoyance", "disappointment",
	"disapproval", "disgust", "embarrassment", "fear", "grief",
	"nervousness", "remorse", "sadness", "confusion", "curiosity",
	"realization", "surprise"
]

func _ready() -> void:
	layer = 10
	_build_ui()
	visible = false
	# Create a Node2D in the main scene for drawing FOV cones in world space
	call_deferred("_setup_fov_drawing")

func _setup_fov_drawing() -> void:
	var main: Node = null
	for child in get_tree().root.get_children():
		if child.name == "Main":
			main = child
			break
	if main:
		_fov_draw_node = Node2D.new()
		_fov_draw_node.name = "FOVDraw"
		_fov_draw_node.z_index = 10
		_fov_draw_node.visible = false
		_fov_draw_node.draw.connect(_draw_fov_cones)
		main.add_child(_fov_draw_node)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		_active = not _active
		visible = _active
		_update_npc_indicators()
		if not _active:
			_selected_npc = null

	if _active and event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_try_select_npc(event.position)

func _process(_delta: float) -> void:
	if not _active:
		return
	_update_panel()
	_update_npc_indicators()

func _build_ui() -> void:
	# Main panel background
	_panel = Panel.new()
	_panel.name = "DebugPanel"
	_panel.position = Vector2(10, 50)
	_panel.size = Vector2(320, 580)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.1, 0.92)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.3, 0.5, 0.8, 0.8)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var y_offset: float = 10.0
	var margin: float = 12.0
	var inner_w: float = 296.0

	# Header: Name + Role
	_name_label = _make_label("Select an NPC", margin, y_offset, inner_w, 16, Color(0.9, 0.8, 0.3))
	_panel.add_child(_name_label)
	y_offset += 22.0

	_role_label = _make_label("Click on an NPC...", margin, y_offset, inner_w, 12, Color(0.7, 0.7, 0.8))
	_panel.add_child(_role_label)
	y_offset += 18.0

	_action_label = _make_label("", margin, y_offset, inner_w, 11, Color(0.5, 0.9, 0.5))
	_panel.add_child(_action_label)
	y_offset += 20.0

	# Section: Layer 1
	var l1_header: Label = _make_label("-- Layer 1: Behavioral Substrate --", margin, y_offset, inner_w, 11, Color(0.4, 0.7, 1.0))
	_panel.add_child(l1_header)
	y_offset += 16.0

	_l1_container = Control.new()
	_l1_container.position = Vector2(margin, y_offset)
	_l1_container.size = Vector2(inner_w, 120)
	_panel.add_child(_l1_container)

	var bar_names: Array[String] = ["Energy", "Hunger", "Social", "Safety", "Momentum", "IntTol", "Frustration"]
	var bar_colors: Array[Color] = [
		Color(0.2, 0.8, 0.2), Color(0.9, 0.6, 0.1), Color(0.3, 0.6, 0.9),
		Color(0.1, 0.7, 0.5), Color(0.8, 0.8, 0.2), Color(0.6, 0.4, 0.8),
		Color(0.9, 0.2, 0.2)
	]
	for i in range(bar_names.size()):
		var by: float = float(i) * 16.0
		var lbl: Label = _make_label(bar_names[i], 0, by, 70, 10, Color(0.8, 0.8, 0.8))
		_l1_container.add_child(lbl)

		var bg := ColorRect.new()
		bg.position = Vector2(72, by + 2)
		bg.size = Vector2(inner_w - 72, 11)
		bg.color = Color(0.15, 0.15, 0.2)
		_l1_container.add_child(bg)

		var bar := ColorRect.new()
		bar.position = Vector2(72, by + 2)
		bar.size = Vector2(0, 11)
		bar.color = bar_colors[i]
		_l1_container.add_child(bar)

		_l1_bars.append({"label": lbl, "bar": bar, "bg": bg, "max_w": inner_w - 72})
	y_offset += float(bar_names.size()) * 16.0 + 8.0

	# Section: Layer 2
	var l2_header: Label = _make_label("-- Layer 2: GoEmotions (27-dim) --", margin, y_offset, inner_w, 11, Color(0.4, 0.7, 1.0))
	_panel.add_child(l2_header)
	y_offset += 16.0

	_l2_heatmap = Control.new()
	_l2_heatmap.position = Vector2(margin, y_offset)
	_l2_heatmap.size = Vector2(inner_w, 18)
	_panel.add_child(_l2_heatmap)

	var cell_w: float = inner_w / 27.0
	for i in range(27):
		var cell := ColorRect.new()
		cell.position = Vector2(float(i) * cell_w, 0)
		cell.size = Vector2(cell_w - 1.0, 16)
		cell.color = Color(0.1, 0.1, 0.1)
		_l2_heatmap.add_child(cell)
		_l2_cells.append(cell)
	y_offset += 22.0

	_l2_top_label = _make_label("Top: --", margin, y_offset, inner_w, 10, Color(0.8, 0.8, 0.6))
	_panel.add_child(_l2_top_label)
	y_offset += 16.0

	# Modulation params
	_modulation_label = _make_label("Mod: --", margin, y_offset, inner_w, 9, Color(0.6, 0.6, 0.7))
	_panel.add_child(_modulation_label)
	y_offset += 16.0

	# Section: Layer 3
	var l3_header: Label = _make_label("-- Layer 3: Executive Plan --", margin, y_offset, inner_w, 11, Color(0.4, 0.7, 1.0))
	_panel.add_child(l3_header)
	y_offset += 16.0

	_l3_plan_container = Control.new()
	_l3_plan_container.position = Vector2(margin, y_offset)
	_l3_plan_container.size = Vector2(inner_w, 120)
	_panel.add_child(_l3_plan_container)
	y_offset += 125.0

	# Memory section
	var mem_header: Label = _make_label("-- Recent Memory --", margin, y_offset, inner_w, 11, Color(0.4, 0.7, 1.0))
	_panel.add_child(mem_header)
	y_offset += 16.0

	_memory_label = _make_label("No memories.", margin, y_offset, inner_w, 9, Color(0.7, 0.7, 0.7))
	_memory_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_memory_label.size = Vector2(inner_w, 60)
	_panel.add_child(_memory_label)
	y_offset += 65.0

	# Section: Neural Network
	var net_header: Label = _make_label("-- Neural Network --", margin, y_offset, inner_w, 11, Color(0.9, 0.5, 0.9))
	_panel.add_child(net_header)
	y_offset += 16.0

	_network_label = _make_label("No network.", margin, y_offset, inner_w, 9, Color(0.8, 0.7, 0.9))
	_network_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_network_label.size = Vector2(inner_w, 50)
	_panel.add_child(_network_label)
	y_offset += 55.0

	# Section: Known Objects
	var obj_header: Label = _make_label("-- Known Objects --", margin, y_offset, inner_w, 11, Color(0.4, 0.7, 1.0))
	_panel.add_child(obj_header)
	y_offset += 16.0

	_objects_label = _make_label("No objects discovered.", margin, y_offset, inner_w, 9, Color(0.7, 0.8, 0.7))
	_objects_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_objects_label.size = Vector2(inner_w, 80)
	_panel.add_child(_objects_label)
	y_offset += 85.0

	_panel.size.y = y_offset + 10.0

func _make_label(text: String, x: float, y: float, w: float, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = Vector2(x, y)
	lbl.size = Vector2(w, 20)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl

func _try_select_npc(screen_pos: Vector2) -> void:
	# Convert screen position to world position using the game camera
	var camera: Camera2D = null
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		# Try finding via root children
		for child in get_tree().root.get_children():
			if child.name == "Main":
				main = child
				break
	if main:
		camera = main.get_node_or_null("Camera2D") as Camera2D

	if camera == null:
		return

	# Screen to world conversion
	var viewport: Viewport = get_viewport()
	var canvas_transform: Transform2D = viewport.get_canvas_transform()
	var world_pos: Vector2 = canvas_transform.affine_inverse() * screen_pos

	# Find closest NPC to click position
	var best_npc: Node = null
	var best_dist: float = 32.0  # click tolerance in world pixels

	for npc in get_tree().get_nodes_in_group("npcs"):
		var dist: float = world_pos.distance_to(npc.global_position)
		if dist < best_dist:
			best_dist = dist
			best_npc = npc

	_selected_npc = best_npc

func _update_panel() -> void:
	if _selected_npc == null or _selected_npc.brain == null:
		_name_label.text = "Select an NPC"
		_role_label.text = "Click on an NPC..."
		_action_label.text = ""
		return

	var brain: RefCounted = _selected_npc.brain

	# Header
	_name_label.text = _selected_npc.npc_name
	_role_label.text = "Role: " + _selected_npc.role
	var action: Dictionary = brain.current_action
	var atype: String = action.get("type", "idle").to_upper()
	var reason: String = action.get("reason", "")
	if not brain._drive_override.is_empty():
		_action_label.text = "%s — OVERRIDE: %s" % [atype, brain._drive_override.get("reason", "?")]
		_action_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.2))
	elif atype == "FLEE_FROM":
		_action_label.text = "%s — %s" % [atype, reason]
		_action_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	elif atype == "PAUSE":
		_action_label.text = "%s — %s" % [atype, reason]
		_action_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.3))
	elif atype == "EXAMINE":
		_action_label.text = "%s — %s" % [atype, reason]
		_action_label.add_theme_color_override("font_color", Color(0.8, 0.5, 1.0))
	elif atype == "OBSERVE":
		_action_label.text = "%s — %s" % [atype, reason]
		_action_label.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	elif atype == "WANDER":
		_action_label.text = "%s — %s" % [atype, reason]
		_action_label.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	else:
		_action_label.text = "%s — %s" % [atype, reason]
		_action_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))

	# Layer 1 bars
	if brain.layer1:
		var l1 = brain.layer1
		var values: Array[float] = [
			l1.energy, l1.hunger, l1.social_need, l1.safety,
			l1.task_momentum * 100.0, l1.interruption_tolerance * 100.0,
			l1.frustration * 100.0
		]
		for i in range(mini(values.size(), _l1_bars.size())):
			var bar_info: Dictionary = _l1_bars[i]
			var pct: float = clampf(values[i] / 100.0, 0.0, 1.0)
			bar_info["bar"].size.x = pct * bar_info["max_w"]

	# Layer 2 heatmap
	if brain.layer2:
		var vec: Array = brain.layer2.emotion_vector
		for i in range(mini(27, vec.size())):
			var val: float = clampf(vec[i], 0.0, 1.0)
			# Heatmap: blue (low) -> green (mid) -> red (high)
			var c: Color
			if val < 0.5:
				c = Color(0.0, val * 2.0, 1.0 - val * 2.0)
			else:
				c = Color((val - 0.5) * 2.0, 1.0 - (val - 0.5) * 2.0, 0.0)
			if i < _l2_cells.size():
				_l2_cells[i].color = c

		# Top dimensions text
		var top: Array = brain.layer2.top_dimensions
		var top_parts: Array = []
		for dim in top:
			top_parts.append("%s: %.2f" % [dim.get("name", "?"), dim.get("value", 0.0)])
		_l2_top_label.text = "Top: " + ", ".join(top_parts) if top_parts.size() > 0 else "Top: --"

		# Modulation
		var mod: Dictionary = brain.layer2.modulation
		_modulation_label.text = "Mod: lr=%.1f exp=%.1f attn=%.1f int=%.1f per=%.1f" % [
			mod.get("learning_rate_mod", 1.0),
			mod.get("exploration_bias", 0.0),
			mod.get("attention_weight", 1.0),
			mod.get("interruption_sensitivity", 0.5),
			mod.get("persistence_scale", 1.0),
		]

	# Layer 3 plan chunks
	_update_plan_display()

	# Memory
	if brain.memory:
		var events: Array = brain.memory.get_recent_events_text(3)
		if events.size() > 0:
			_memory_label.text = "\n".join(events)
		else:
			_memory_label.text = "No notable events."

	# Neural Network
	if brain.layer1 and _network_label:
		var net_debug: Dictionary = brain.layer1.get_network_debug()
		if not net_debug.is_empty():
			var fixed: int = net_debug.get("neuron_count", 0) - net_debug.get("dynamic_count", 0)
			var dyn: int = net_debug.get("dynamic_count", 0)
			var conns: int = net_debug.get("connection_count", 0)
			var line1: String = "Neurons: %d+%d  Conns: %d" % [fixed, dyn, conns]
			var line2: String = "S:%d N:%d R:%d" % [net_debug.get("stress_count", 0), net_debug.get("novelty_count", 0), net_debug.get("reward_count", 0)]
			var evt: Dictionary = net_debug.get("last_event", {})
			var line3: String = ""
			if not evt.is_empty():
				var ago: float = (Time.get_ticks_msec() - evt.get("tick", 0)) / 1000.0
				line3 = "Last: %s(%s) %.0fs ago" % [evt.get("type", "?"), evt.get("context", ""), ago]
			else:
				line3 = "No neurogenesis yet"
			_network_label.text = "%s  %s\n%s" % [line1, line2, line3]
		else:
			_network_label.text = "No network."

	# Known Objects
	if brain.memory and _objects_label:
		var known: Dictionary = brain.memory.known_objects
		if known.size() > 0:
			var obj_lines: Array = []
			var count: int = 0
			for obj_id in known:
				if count >= 6:
					obj_lines.append("...and %d more" % (known.size() - 6))
					break
				var obj: Dictionary = known[obj_id]
				var src: String = ""
				if obj.get("learned_from", "direct") != "direct":
					src = " (via %s)" % obj["learned_from"]
				obj_lines.append("%s @ %s: %s%s" % [obj["name"], obj["location"], obj["last_seen_state"], src])
				count += 1
			_objects_label.text = "\n".join(obj_lines)
		else:
			_objects_label.text = "No objects discovered."

func _update_plan_display() -> void:
	# Clear existing plan labels
	for child in _l3_plan_container.get_children():
		child.queue_free()

	if _selected_npc == null or _selected_npc.brain == null or _selected_npc.brain.layer3 == null:
		return

	var l3 = _selected_npc.brain.layer3
	var agenda: Array = l3.agenda
	var current_idx: int = l3.current_chunk_index

	# Show suspended chunk indicator
	var y: float = 0.0
	if l3.suspended_chunk_index >= 0:
		var s_chunk: Dictionary = l3.suspended_chunk
		var s_text: String = "S: %s - %s" % [s_chunk.get("location", "?"), s_chunk.get("purpose", "?")]
		var s_lbl: Label = _make_label(s_text, 0, y, 296, 9, Color(0.3, 0.8, 0.8, 0.7))
		_l3_plan_container.add_child(s_lbl)
		y += 14.0

	for i in range(mini(agenda.size(), 7)):  # Show max 7 chunks (1 slot for suspended)
		var chunk: Dictionary = agenda[i]
		var loc: String = chunk.get("location", "?")
		var purpose: String = chunk.get("purpose", "?")
		var dur: float = chunk.get("duration", 0.0)
		var obj_id: String = chunk.get("object_id", "")
		var text: String = "%s (%.0fh) - %s" % [loc, dur, purpose]
		if obj_id != "":
			text += " [%s]" % obj_id.get_file()  # Show short object ID

		var color: Color = Color(0.6, 0.6, 0.6)
		if i == current_idx:
			color = Color(1.0, 1.0, 0.2)  # Active chunk in yellow
			text = "> " + text

		var lbl: Label = _make_label(text, 0, y, 296, 9, color)
		_l3_plan_container.add_child(lbl)
		y += 14.0

func _update_npc_indicators() -> void:
	for npc in get_tree().get_nodes_in_group("npcs"):
		if npc.has_method("set_valence_visible"):
			npc.set_valence_visible(_active)
	# Toggle FOV drawing
	if _fov_draw_node:
		_fov_draw_node.visible = _active
		_fov_draw_node.queue_redraw()

func _draw_fov_cones() -> void:
	"""Draw FOV cones for all NPCs (or just selected) in world space."""
	if not _active or _fov_draw_node == null:
		return
	for npc in get_tree().get_nodes_in_group("npcs"):
		if npc.brain == null or npc.brain.perception == null:
			continue
		var points: PackedVector2Array = npc.brain.perception.get_fov_cone_points(npc.global_position)
		if points.size() < 3:
			continue
		# Draw filled cone with transparency
		var color: Color = npc.get_valence_color() if npc.has_method("get_valence_color") else Color.YELLOW
		color.a = 0.12
		_fov_draw_node.draw_colored_polygon(points, color)
		# Draw cone outline
		color.a = 0.35
		for i in range(points.size() - 1):
			_fov_draw_node.draw_line(points[i], points[i + 1], color, 1.0)
