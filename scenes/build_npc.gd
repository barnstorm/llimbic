extends SceneTree
## Scene builder — run: timeout 60 godot --headless --script scenes/build_npc.gd

func _initialize() -> void:
	var root := CharacterBody2D.new()
	root.name = "NPC"
	root.set_script(load("res://scripts/npc_controller.gd"))

	var sprite := AnimatedSprite2D.new()
	sprite.name = "AnimatedSprite2D"
	root.add_child(sprite)

	var label := Label.new()
	label.name = "NameLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-30, -40)
	label.size = Vector2(60, 20)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	root.add_child(label)

	_set_owners(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, "res://scenes/npc.tscn")
	print("Saved: res://scenes/npc.tscn")
	quit(0)

func _set_owners(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		if c.scene_file_path.is_empty():
			_set_owners(c, owner)
