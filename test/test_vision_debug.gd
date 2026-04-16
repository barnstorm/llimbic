extends SceneTree
## Debug: why entity-to-entity vision fails from Hugo's position

var _frame: int = 0
var _done: bool = false

func _initialize() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 5:
		return false
	if _done:
		return true
	_done = true

	var ss: Node = null
	var os: Node = null
	for c in get_root().get_children():
		if c.name == "SensorSystem":
			ss = c
		elif c.name == "OccluderSystem":
			os = c

	var SP: GDScript = load("res://scripts/sensor_profile.gd")
	var SRT: GDScript = load("res://scripts/sensory_result_types.gd")
	var profile: Dictionary = SP.make_default()
	var offsets: Array = SRT.actor_sample_offsets()

	var hugo: Vector2 = Vector2(2096, 624)

	# Targets at various distances and directions
	var targets: Array = [
		{"label": "44px north", "pos": Vector2(2096, 580)},
		{"label": "46px west", "pos": Vector2(2050, 624)},
		{"label": "30px south", "pos": Vector2(2096, 654)},
		{"label": "20px east", "pos": Vector2(2116, 624)},
		{"label": "60px NW (open area)", "pos": Vector2(2050, 570)},
	]

	print("\n===== ENTITY VISION DEBUG =====")
	print("Hugo at %s, profile: range=%.0f arc=%.0f" % [str(hugo), profile["vision_range"], profile["vision_arc_deg"]])

	for t in targets:
		var target: Vector2 = t["pos"]
		var facing: Vector2 = (target - hugo).normalized()
		var vr: Dictionary = ss.query_vision(hugo, facing, profile, target, offsets)
		print("\n%s (pos=%s dist=%.0f):" % [t["label"], str(target), vr.get("distance", 0)])
		print("  visible=%s exposure=%.2f confidence=%.2f hits=%d/%d" % [
			str(vr.get("visible")), vr.get("exposure", 0), vr.get("confidence", 0),
			vr.get("sample_hits", 0), vr.get("sample_total", 0)])
		print("  blocked_by=%s" % str(vr.get("blocked_by", [])))

		# If hidden, check each sample
		if not vr.get("visible", false):
			for i in range(offsets.size()):
				var sp: Vector2 = target + offsets[i]
				# Manual ray check
				var rect: Rect2 = Rect2(
					min(hugo.x, sp.x) - 2, min(hugo.y, sp.y) - 2,
					abs(sp.x - hugo.x) + 4, abs(sp.y - hugo.y) + 4
				)
				var indices: Array = os.get_segment_indices_in_rect(rect)
				var block_count: int = 0
				var first_blocker: String = ""
				for idx in indices:
					var seg: Dictionary = os.get_segment(idx)
					if not seg.get("blocks_vision", true):
						continue
					if _intersect(hugo, sp, seg["start"], seg["end"]):
						block_count += 1
						if first_blocker == "":
							first_blocker = "tags=%s start=%s end=%s" % [
								str(seg.get("tags", [])),
								str(seg["start"]),
								str(seg["end"]),
							]
				print("  sample[%d] %s: %d blockers %s" % [
					i, str(sp),
					block_count,
					("first: " + first_blocker) if block_count > 0 else "CLEAR (arc reject?)"
				])

	# Test in a known open area (town_square center)
	print("\n--- Control: open area test (town_square) ---")
	var open_a: Vector2 = Vector2(1200, 800)
	var open_b: Vector2 = Vector2(1250, 800)
	var facing_right: Vector2 = Vector2(1, 0)
	var vr2: Dictionary = ss.query_vision(open_a, facing_right, profile, open_b, offsets)
	print("A=%s B=%s: visible=%s exposure=%.2f hits=%d/%d" % [
		str(open_a), str(open_b), str(vr2.get("visible")),
		vr2.get("exposure", 0), vr2.get("sample_hits", 0), vr2.get("sample_total", 0)])

	print("\n===== END =====\n")
	return true

static func _intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1: Vector2 = p2 - p1
	var d2: Vector2 = p4 - p3
	var cross: float = d1.x * d2.y - d1.y * d2.x
	if absf(cross) < 0.0001:
		return false
	var d3: Vector2 = p3 - p1
	var t: float = (d3.x * d2.y - d3.y * d2.x) / cross
	var u: float = (d3.x * d1.y - d3.y * d1.x) / cross
	return t > 0.001 and t < 0.999 and u > 0.001 and u < 0.999
