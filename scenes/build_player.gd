extends SceneTree
## Scene builder — run: timeout 60 godot --headless --script scenes/build_player.gd

func _initialize() -> void:
	var root := CharacterBody2D.new()
	root.name = "Player"
	root.set_script(load("res://scripts/player_controller.gd"))

	var sprite := AnimatedSprite2D.new()
	sprite.name = "AnimatedSprite2D"
	root.add_child(sprite)

	_set_owners(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, "res://scenes/player.tscn")
	print("Saved: res://scenes/player.tscn")
	quit(0)

func _set_owners(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		if c.scene_file_path.is_empty():
			_set_owners(c, owner)
