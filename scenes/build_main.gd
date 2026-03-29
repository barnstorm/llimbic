extends SceneTree
## Scene builder — run: timeout 60 godot --headless --script scenes/build_main.gd

func _initialize() -> void:
	var root := Node2D.new()
	root.name = "Main"

	# World map background
	var world_map := Sprite2D.new()
	world_map.name = "WorldMap"
	world_map.set_script(load("res://scripts/world_map.gd"))
	world_map.centered = false
	root.add_child(world_map)

	# Player instance
	var player = load("res://scenes/player.tscn").instantiate()
	player.name = "Player"
	root.add_child(player)

	# NPC container
	var npcs := Node2D.new()
	npcs.name = "NPCs"
	root.add_child(npcs)

	# Camera
	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.zoom = Vector2(2.5, 2.5)
	root.add_child(camera)

	# HUD
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	hud.layer = 1
	root.add_child(hud)

	var hud_container := Control.new()
	hud_container.name = "HUDContainer"
	hud_container.anchors_preset = 15
	hud_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.add_child(hud_container)

	var time_label := Label.new()
	time_label.name = "TimeLabel"
	time_label.text = "6:00 AM"
	time_label.position = Vector2(10, 10)
	hud_container.add_child(time_label)

	# Debug overlay
	var debug := CanvasLayer.new()
	debug.name = "DebugOverlay"
	debug.layer = 2
	debug.set_script(load("res://scripts/debug_overlay.gd"))
	debug.visible = false
	root.add_child(debug)

	# Social propagation system
	var social := Node.new()
	social.name = "SocialPropagation"
	social.set_script(load("res://scripts/social_propagation.gd"))
	root.add_child(social)

	# Interaction system
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
