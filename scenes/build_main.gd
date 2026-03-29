extends SceneTree
## Scene builder — run: timeout 60 godot --headless --script scenes/build_main.gd

# NPC spawn positions from TMX Spawning Blocks layer (first 8 spawns)
const SPAWN_POSITIONS: Array[Vector2] = [
	Vector2(1712, 464),   # Spawn 0
	Vector2(2320, 464),   # Spawn 1
	Vector2(528, 592),    # Spawn 2
	Vector2(816, 592),    # Spawn 3
	Vector2(1168, 592),   # Spawn 4
	Vector2(2768, 592),   # Spawn 5
	Vector2(2992, 592),   # Spawn 6
	Vector2(2096, 624),   # Spawn 7
]

const NPC_DATA: Array[Dictionary] = [
	{"name": "Edith", "role": "Baker", "sheet": "res://assets/characters/Character_RM_002.png"},
	{"name": "Roland", "role": "Guard", "sheet": "res://assets/characters/Character_RM_003.png"},
	{"name": "Ivy", "role": "Herbalist", "sheet": "res://assets/characters/Character_RM_004.png"},
	{"name": "Felix", "role": "Courier", "sheet": "res://assets/characters/Character_RM_005.png"},
	{"name": "Greta", "role": "Blacksmith", "sheet": "res://assets/characters/Character_RM_006.png"},
	{"name": "Mabel", "role": "Gossip", "sheet": "res://assets/characters/Character_RM_007.png"},
	{"name": "Aldric", "role": "Farmer", "sheet": "res://assets/characters/Character_RM_008.png"},
	{"name": "Hugo", "role": "Innkeeper", "sheet": "res://assets/characters/Character_RM_009.png"},
]

func _initialize() -> void:
	print("Generating: main.tscn")

	var root := Node2D.new()
	root.name = "Main"

	# World map background
	var world_map := Sprite2D.new()
	world_map.name = "WorldMap"
	world_map.set_script(load("res://scripts/world_map.gd"))
	world_map.centered = false
	root.add_child(world_map)

	# Player instance
	var player_scene: PackedScene = load("res://scenes/player.tscn")
	var player = player_scene.instantiate()
	player.name = "Player"
	root.add_child(player)

	# NPC container
	var npcs := Node2D.new()
	npcs.name = "NPCs"
	root.add_child(npcs)

	# Spawn 8 NPCs
	var npc_scene: PackedScene = load("res://scenes/npc.tscn")
	for i in range(8):
		var npc = npc_scene.instantiate()
		var data: Dictionary = NPC_DATA[i]
		npc.name = "NPC_" + str(i)
		npc.position = SPAWN_POSITIONS[i]
		npc.set("npc_name", data["name"])
		npc.set("role", data["role"])
		npc.set("character_sheet_path", data["sheet"])
		npcs.add_child(npc)

	# Camera with controller script
	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.zoom = Vector2(2.5, 2.5)
	camera.set_script(load("res://scripts/camera_controller.gd"))
	root.add_child(camera)

	# HUD
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	hud.layer = 1
	root.add_child(hud)

	var hud_container := Control.new()
	hud_container.name = "HUDContainer"
	hud_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.add_child(hud_container)

	var time_label := Label.new()
	time_label.name = "TimeLabel"
	time_label.text = "6:00 AM"
	time_label.position = Vector2(10, 10)
	time_label.add_theme_font_size_override("font_size", 20)
	time_label.add_theme_color_override("font_color", Color.WHITE)
	time_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	time_label.add_theme_constant_override("shadow_offset_x", 1)
	time_label.add_theme_constant_override("shadow_offset_y", 1)
	time_label.set_script(load("res://scripts/hud_time.gd"))
	hud_container.add_child(time_label)

	# Debug overlay (for task 2)
	var debug := CanvasLayer.new()
	debug.name = "DebugOverlay"
	debug.layer = 2
	debug.set_script(load("res://scripts/debug_overlay.gd"))
	debug.visible = false
	root.add_child(debug)

	# Social propagation system (stub for task 2)
	var social := Node.new()
	social.name = "SocialPropagation"
	social.set_script(load("res://scripts/social_propagation.gd"))
	root.add_child(social)

	# Interaction system (stub for task 2)
	var interaction := Node.new()
	interaction.name = "InteractionSystem"
	interaction.set_script(load("res://scripts/interaction_system.gd"))
	root.add_child(interaction)

	_set_owners(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, "res://scenes/main.tscn")
	print("Saved: res://scenes/main.tscn")
	quit(0)

func _set_owners(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		if c.scene_file_path.is_empty():
			_set_owners(c, owner)
