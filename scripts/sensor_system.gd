extends Node
## res://scripts/sensor_system.gd — Autoload: two-phase vision queries with multi-sample line-of-sight raycasting
## Uses OccluderSystem for analytical (non-physics-engine) segment intersection.
## Also provides hearing queries with sound attenuation through occluders.

var _occluder_system: Node = null
var _stimulus_registry: Node = null

func _ready() -> void:
	# Find OccluderSystem and StimulusRegistry autoloads
	for child in get_tree().root.get_children():
		if child.name == "OccluderSystem":
			_occluder_system = child
		elif child.name == "StimulusRegistry":
			_stimulus_registry = child
	if _occluder_system == null:
		push_error("SensorSystem: OccluderSystem autoload not found")
	if _stimulus_registry == null:
		push_error("SensorSystem: StimulusRegistry autoload not found")

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

# --- Hearing queries ---

func query_hearing(listener_pos: Vector2, profile: Dictionary, stimulus: Dictionary) -> Dictionary:
	## Analog hearing query for a single stimulus.
	## Broad phase: check if stimulus within max effective radius.
	## Narrow phase: 1-3 rays from stimulus to listener, each occluder segment reduces
	## signal by its sound_damping factor (multiplicative).
	## Returns a HearingResult dictionary.

	var hearing_threshold: float = profile.get("hearing_threshold", 0.1)
	var hearing_sensitivity: float = profile.get("hearing_sensitivity", 1.0)
	var ear_offset: Vector2 = profile.get("ear_offset", Vector2.ZERO)
	var ear_pos: Vector2 = listener_pos + ear_offset

	var stim_pos: Vector2 = stimulus.get("position", Vector2.ZERO)
	var stim_radius: float = stimulus.get("radius", 0.0)
	var stim_strength: float = stimulus.get("strength", 0.0)

	var dist: float = ear_pos.distance_to(stim_pos)

	# Build default (not heard) result
	var result: Dictionary = {
		"heard": false,
		"perceived_volume": 0.0,
		"clarity": 0.0,
		"distance": dist,
		"direction": Vector2.ZERO,
		"occlusion_loss": 0.0,
		"estimated_source_pos": Vector2.ZERO,
		"stimulus_id": stimulus.get("id", ""),
		"stimulus_type": stimulus.get("type", ""),
		"emitter_id": stimulus.get("emitter_id", ""),
		"emitter_eid": stimulus.get("emitter_eid", ""),
		"tags": stimulus.get("tags", []),
	}

	# --- Broad phase ---
	# Max effective radius: how far can this stimulus be heard at all?
	var max_effective_radius: float = stim_radius * stim_strength / maxf(hearing_threshold, 0.001)
	if dist > max_effective_radius:
		return result

	# Distance falloff: inverse-linear within stimulus radius, drops to 0 at radius edge
	var distance_falloff: float = 1.0
	if stim_radius > 0.0:
		distance_falloff = clampf(1.0 - dist / stim_radius, 0.0, 1.0)
	else:
		# Zero radius = point stimulus, very fast falloff
		distance_falloff = 1.0 / maxf(dist / 32.0, 1.0)

	# --- Narrow phase: occlusion raycasting ---
	var occlusion_factor: float = 1.0
	if _occluder_system != null:
		occlusion_factor = _compute_sound_occlusion(ear_pos, stim_pos)

	# Final perceived volume
	var perceived_volume: float = stim_strength * distance_falloff * occlusion_factor * hearing_sensitivity

	var heard: bool = perceived_volume >= hearing_threshold
	var clarity: float = clampf(perceived_volume / maxf(stim_strength, 0.001), 0.0, 1.0)
	var occlusion_loss: float = 1.0 - occlusion_factor

	# Direction from listener to stimulus (what direction the sound comes from)
	var direction: Vector2 = Vector2.ZERO
	if dist > 1.0:
		direction = (stim_pos - ear_pos).normalized()

	# Estimated source position: uncertain hearing produces imprecise localization
	# Random offset proportional to (1.0 - clarity)
	var uncertainty: float = (1.0 - clarity) * stim_radius * 0.5
	var estimated_pos: Vector2 = stim_pos
	if uncertainty > 1.0:
		estimated_pos += Vector2(randf_range(-uncertainty, uncertainty), randf_range(-uncertainty, uncertainty))

	result["heard"] = heard
	result["perceived_volume"] = clampf(perceived_volume, 0.0, 1.0)
	result["clarity"] = clarity
	result["occlusion_loss"] = occlusion_loss
	result["direction"] = direction
	result["estimated_source_pos"] = estimated_pos
	return result

func query_hearing_all(listener_pos: Vector2, profile: Dictionary) -> Array:
	## Query all stimuli in range for a listener. Returns only heard results.
	## Uses StimulusRegistry.get_stimuli_in_range() for broad phase.
	if _stimulus_registry == null:
		return []

	var hearing_threshold: float = profile.get("hearing_threshold", 0.1)
	# Max possible hearing range: use a generous radius based on sensitivity
	# We use a large range for the registry query, then filter in query_hearing
	var max_query_radius: float = 512.0  # ~16 tiles, generous upper bound
	var candidates: Array = _stimulus_registry.get_stimuli_in_range(listener_pos, max_query_radius)

	var results: Array = []
	for stimulus in candidates:
		var hr: Dictionary = query_hearing(listener_pos, profile, stimulus)
		if hr["heard"]:
			results.append(hr)
	return results

func _compute_sound_occlusion(ear_pos: Vector2, source_pos: Vector2) -> float:
	## Cast 1-3 rays from source to listener. Each occluder segment along a ray
	## reduces signal by its sound_damping factor (multiplicative).
	## Returns aggregate occlusion factor (1.0 = no occlusion, 0.0 = fully blocked).

	# Build sample rays: center + optional vertical offsets
	var rays: Array = []
	rays.append([source_pos, ear_pos])
	var perp: Vector2 = (ear_pos - source_pos).normalized().rotated(PI * 0.5)
	var offset: float = 12.0  # small offset for multi-ray spread
	rays.append([source_pos + perp * offset, ear_pos + perp * offset])
	rays.append([source_pos - perp * offset, ear_pos - perp * offset])

	# Get candidate segments from spatial grid
	var all_points: Array = [source_pos, ear_pos]
	for ray in rays:
		all_points.append(ray[0])
		all_points.append(ray[1])
	var rect: Rect2 = _bounding_rect(all_points).grow(8.0)
	var candidate_indices: Array = _occluder_system.get_segment_indices_in_rect(rect)

	# For each ray, compute multiplicative damping
	var best_factor: float = 0.0  # we take the best (least occluded) ray
	for ray in rays:
		var ray_start: Vector2 = ray[0]
		var ray_end: Vector2 = ray[1]
		var ray_factor: float = 1.0
		for seg_idx in candidate_indices:
			var seg: Dictionary = _occluder_system.get_segment(seg_idx)
			if _segments_intersect(ray_start, ray_end, seg["start"], seg["end"]):
				var damping: float = seg.get("sound_damping", 0.8)
				ray_factor *= (1.0 - damping)  # damping 0.8 means 80% absorbed, 20% passes through
		if ray_factor > best_factor:
			best_factor = ray_factor

	return best_factor
