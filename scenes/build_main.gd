extends SceneTree
## Scene builder — run: timeout 60 godot --headless --script scenes/build_main.gd

# NPC data loaded from persona JSON files at build time
# Order determines spawn index in the scene
const NPC_NAMES: Array[String] = ["Edith", "Roland", "Ivy", "Felix", "Greta", "Mabel", "Aldric", "Hugo"]

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

	# Spawn NPCs from persona data files
	var npc_scene: PackedScene = load("res://scenes/npc.tscn")
	var LoaderScript: GDScript = load("res://scripts/persona_loader.gd")
	for i in range(NPC_NAMES.size()):
		var persona: Dictionary = LoaderScript.load_persona(NPC_NAMES[i])
		if persona.is_empty():
			push_warning("Skipping NPC %s — persona file not found" % NPC_NAMES[i])
			continue
		var npc = npc_scene.instantiate()
		npc.name = "NPC_" + str(i)
		var sp: Array = persona.get("spawn_position", [2096, 800])
		npc.position = Vector2(float(sp[0]), float(sp[1]))
		npc.set("npc_name", persona["name"])
		npc.set("role", persona["role"])
		npc.set("character_sheet_path", persona.get("sprite_sheet", "res://assets/characters/Character_RM_002.png"))
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
