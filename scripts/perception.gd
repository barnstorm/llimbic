extends RefCounted
## res://scripts/perception.gd — Local result cache for perception data
## Updated by NPCBrain from SensorSystem query results.
## No longer computes FOV cone math directly — that's in SensorSystem.

const VISION_RANGE: float = 96.0   # ~3 tiles (kept for backward compat / reference)
const VISION_HALF_ANGLE: float = 0.785  # ~45 degrees (kept for reference)
const HEARING_RANGE: float = 80.0  # ~2.5 tiles (kept for reference)

# Facing direction as a unit vector (used by SensorSystem for arc checks)
var facing_vector: Vector2 = Vector2.DOWN

# Cached results — updated by brain from SensorSystem queries
var visible_entities: Array[Dictionary] = []  # [{name, position, distance, doing, exposure, confidence, vision_result}]
var visible_objects: Array[Dictionary] = []   # [{id, name, type, position, distance, state, owner, exposure, confidence}]
var heard_events: Array[Dictionary] = []      # [{source, text, distance, time}]

# Per-entity VisionResult cache (entity_name -> last VisionResult dict)
var _vision_cache: Dictionary = {}
# Per-stimulus HearingResult cache (stimulus_id -> last HearingResult dict)
var _hearing_cache: Dictionary = {}

# Persistent heard buffer (cleared each tick, consumed by brain)
var _heard_this_tick: Array[Dictionary] = []

# Debug: last query results for visualization
var last_vision_queries: Array[Dictionary] = []  # [{observer_pos, target_pos, target_name, result: VisionResult}]
var last_hearing_results: Array[Dictionary] = []  # [HearingResult dicts]

func set_facing(facing: String) -> void:
	match facing:
		"up":
			facing_vector = Vector2.UP
		"down":
			facing_vector = Vector2.DOWN
		"left":
			facing_vector = Vector2.LEFT
		"right":
			facing_vector = Vector2.RIGHT

func cache_vision_result(entity_name: String, result: Dictionary) -> void:
	"""Store a VisionResult from SensorSystem for an entity."""
	_vision_cache[entity_name] = result

func get_vision_result(entity_name: String) -> Dictionary:
	"""Get the last cached VisionResult for an entity."""
	return _vision_cache.get(entity_name, {})

func cache_hearing_result(stimulus_id: String, result: Dictionary) -> void:
	"""Store a HearingResult from SensorSystem."""
	_hearing_cache[stimulus_id] = result

func clear_vision_queries() -> void:
	"""Clear debug query data for new tick."""
	last_vision_queries.clear()
	last_hearing_results.clear()

func record_vision_query(observer_pos: Vector2, target_pos: Vector2, target_name: String, result: Dictionary) -> void:
	"""Record a vision query result for debug visualization."""
	last_vision_queries.append({
		"observer_pos": observer_pos,
		"target_pos": target_pos,
		"target_name": target_name,
		"result": result,
	})

func record_hearing_result(result: Dictionary) -> void:
	"""Record a hearing result for debug visualization."""
	last_hearing_results.append(result)

# --- Legacy methods kept for backward compatibility ---

func update_vision(my_pos: Vector2, entities: Array) -> void:
	"""Legacy: replaced by SensorSystem queries in NPCBrain.
	Kept as no-op for any code that still calls it."""
	pass

func update_object_vision(my_pos: Vector2, world_objects: Array) -> void:
	"""Legacy: replaced by SensorSystem queries in NPCBrain.
	Kept as no-op for any code that still calls it."""
	pass

func can_see(my_pos: Vector2, target_pos: Vector2) -> bool:
	"""Legacy compatibility: check if any cached entity at target_pos is visible.
	For new code, use SensorSystem.query_vision() directly."""
	# Check if we have a cached result for something near target_pos
	for entity_name in _vision_cache:
		var result: Dictionary = _vision_cache[entity_name]
		if result.get("visible", false):
			# Check if the queried target was near this position
			# This is approximate — callers should use SensorSystem directly
			return true
	return false

func hear(source_name: String, text: String, source_pos: Vector2, my_pos: Vector2) -> bool:
	"""Process an audible event. Returns true if heard.
	Fallback for when StimulusRegistry is not available."""
	var dist: float = source_pos.distance_to(my_pos)
	if dist > HEARING_RANGE:
		return false
	var evt: Dictionary = {
		"source": source_name,
		"text": text,
		"distance": dist,
		"time": Time.get_ticks_msec()
	}
	heard_events.append(evt)
	_heard_this_tick.append(evt)
	# Keep heard_events bounded
	if heard_events.size() > 20:
		heard_events.pop_front()
	return true

func consume_heard() -> Array[Dictionary]:
	"""Get and clear events heard this tick."""
	var result: Array[Dictionary] = _heard_this_tick.duplicate()
	_heard_this_tick.clear()
	return result

func get_fov_cone_points(my_pos: Vector2) -> PackedVector2Array:
	"""Return points for drawing the FOV cone (for debug overlay)."""
	var points := PackedVector2Array()
	points.append(my_pos)

	var base_angle: float = facing_vector.angle()
	var steps: int = 12
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var angle: float = base_angle - VISION_HALF_ANGLE + t * VISION_HALF_ANGLE * 2.0
		var point: Vector2 = my_pos + Vector2(cos(angle), sin(angle)) * VISION_RANGE
		points.append(point)

	points.append(my_pos)
	return points
