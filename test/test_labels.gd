extends SceneTree

func _initialize() -> void:
	pass

func _process(_delta: float) -> bool:
	var wls: Node = null
	for child in root.get_children():
		if child.name == "WorldLabelSystem":
			wls = child
			break
	if wls == null:
		print("WorldLabelSystem not found yet")
		return false

	# Test some known positions
	# Hobbs Cafe sector center should be around tiles (71-84, 17-26) = world (2272-2688, 544-832)
	var cafe_pos: Vector2 = Vector2(2480, 700)
	print("Position %s -> %s" % [cafe_pos, wls.describe_location(cafe_pos)])

	# Johnson Park area around tiles (20-35, 41-51) = world (640-1120, 1312-1632)
	var park_pos: Vector2 = Vector2(880, 1472)
	print("Position %s -> %s" % [park_pos, wls.describe_location(park_pos)])

	# Test visible labels
	print("\nVisible from cafe facing east:")
	print(wls.describe_visible(cafe_pos, Vector2(1, 0), 128.0))

	# Test objects near cafe
	var objs: Array = wls.get_objects_near(cafe_pos, 160.0)
	print("\nObjects near cafe (%d):" % objs.size())
	for obj in objs.slice(0, 8):
		print("  %s (%.0fpx away, in %s)" % [obj["name"], obj["distance"], obj["arena"]])

	# All sectors
	print("\nAll sectors:")
	for s in wls.get_all_sectors():
		var center: Vector2 = wls.get_sector_center(s)
		print("  %s -> center %s" % [s, center])

	quit()
	return true
