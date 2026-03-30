extends Node
## res://scripts/sensor_system.gd — Autoload: two-phase vision queries with multi-sample line-of-sight raycasting
## Uses OccluderSystem for analytical (non-physics-engine) segment intersection.

var _occluder_system: Node = null

func _ready() -> void:
	# Find OccluderSystem autoload
	for child in get_tree().root.get_children():
		if child.name == "OccluderSystem":
			_occluder_system = child
			break
	if _occluder_system == null:
		push_error("SensorSystem: OccluderSystem autoload not found")

func query_vision(observer_pos: Vector2, observer_facing: Vector2, profile: Dictionary, target_pos: Vector2, target_sample_points: Array) -> Dictionary:
	## Two-phase vision pipeline:
	## Phase 1 (broad): range + arc reject.
	## Phase 2 (narrow): analytical raycast per sample point against occluder segments.
	## Returns a VisionResult dictionary.

	var vision_range: float = profile.get("vision_range", 96.0)
	var vision_arc_deg: float = profile.get("vision_arc_deg", 90.0)
	var eye_offset: Vector2 = profile.get("eye_offset", Vector2.ZERO)
	var half_arc_rad: float = deg_to_rad(vision_arc_deg * 0.5)

	var eye_pos: Vector2 = observer_pos + eye_offset

	# --- Phase 1: Broad-phase ---
	var to_target: Vector2 = target_pos - eye_pos
	var dist: float = to_target.length()

	# Build default result
	var result: Dictionary = {
		"visible": false,
		"distance": dist,
		"exposure": 0.0,
		"confidence": 0.0,
		"sample_hits": 0,
		"sample_total": target_sample_points.size(),
		"blocked_by": [],
		"last_visible_point": Vector2.ZERO,
	}

	# Range check
	if dist > vision_range or dist < 0.5:
		return result

	# Arc check against target center
	if observer_facing.length_squared() > 0.01:
		var dir_norm: Vector2 = to_target.normalized()
		var dot: float = observer_facing.dot(dir_norm)
		var angle: float = acos(clampf(dot, -1.0, 1.0))
		if angle > half_arc_rad:
			return result

	# --- Phase 2: Narrow-phase raycasting ---
	if _occluder_system == null:
		# No occluder system — treat as fully visible
		result["visible"] = true
		result["exposure"] = 1.0
		result["confidence"] = 1.0
		result["sample_hits"] = result["sample_total"]
		result["last_visible_point"] = target_pos
		return result

	# Build bounding rect for the ray bundle to query spatial grid
	var all_points: Array = []
	all_points.append(eye_pos)
	for sp in target_sample_points:
		all_points.append(target_pos + sp)

	var rect: Rect2 = _bounding_rect(all_points).grow(4.0)
	var candidate_indices: Array = _occluder_system.get_segment_indices_in_rect(rect)

	var hits: int = 0
	var last_hit_point: Vector2 = Vector2.ZERO
	var blocked_tags: Dictionary = {}  # deduplicated

	for sample_offset in target_sample_points:
		var sample_pos: Vector2 = target_pos + sample_offset
		var blocked: bool = false
		for seg_idx in candidate_indices:
			var seg: Dictionary = _occluder_system.get_segment(seg_idx)
			if not seg.get("blocks_vision", true):
				continue
			if _segments_intersect(eye_pos, sample_pos, seg["start"], seg["end"]):
				blocked = true
				for tag in seg.get("tags", []):
					blocked_tags[tag] = true
				break  # one blocking segment is enough for this sample
		if not blocked:
			hits += 1
			last_hit_point = sample_pos

	var total: int = target_sample_points.size()
	var exposure: float = float(hits) / maxf(float(total), 1.0)
	var confidence: float = exposure * (1.0 - dist / vision_range)

	result["visible"] = hits > 0
	result["exposure"] = exposure
	result["confidence"] = clampf(confidence, 0.0, 1.0)
	result["sample_hits"] = hits
	result["sample_total"] = total
	result["blocked_by"] = blocked_tags.keys()
	result["last_visible_point"] = last_hit_point
	return result

# --- Analytical line-segment intersection ---

static func _segments_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	## Returns true if segment (p1->p2) intersects segment (p3->p4).
	## Uses the parametric cross-product method.
	var d1: Vector2 = p2 - p1
	var d2: Vector2 = p4 - p3
	var cross: float = d1.x * d2.y - d1.y * d2.x

	if absf(cross) < 0.0001:
		return false  # parallel or collinear — treat as non-intersecting

	var d3: Vector2 = p3 - p1
	var t: float = (d3.x * d2.y - d3.y * d2.x) / cross
	var u: float = (d3.x * d1.y - d3.y * d1.x) / cross

	# Intersection occurs when both parameters are in (0, 1)
	# Using small epsilon to avoid edge-touching false positives
	return t > 0.001 and t < 0.999 and u > 0.001 and u < 0.999

static func _bounding_rect(points: Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_x: float = points[0].x
	var min_y: float = points[0].y
	var max_x: float = min_x
	var max_y: float = min_y
	for i in range(1, points.size()):
		var p: Vector2 = points[i]
		if p.x < min_x:
			min_x = p.x
		if p.y < min_y:
			min_y = p.y
		if p.x > max_x:
			max_x = p.x
		if p.y > max_y:
			max_y = p.y
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)
