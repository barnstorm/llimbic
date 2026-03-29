extends RefCounted
## res://scripts/perception.gd — FOV cone vision + omnidirectional hearing

const VISION_RANGE: float = 96.0   # ~3 tiles
const VISION_HALF_ANGLE: float = 0.785  # ~45 degrees = 90 degree cone
const HEARING_RANGE: float = 80.0  # ~2.5 tiles, omnidirectional

# Facing direction as a unit vector
var facing_vector: Vector2 = Vector2.DOWN

# What this NPC currently sees and hears
var visible_entities: Array[Dictionary] = []  # [{name, position, distance, doing}]
var heard_events: Array[Dictionary] = []      # [{source, text, distance, time}]

# Persistent heard buffer (cleared each tick, consumed by brain)
var _heard_this_tick: Array[Dictionary] = []

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

func update_vision(my_pos: Vector2, entities: Array) -> void:
	"""Check which entities are within the FOV cone."""
	visible_entities.clear()
	for entity in entities:
		var other_pos: Vector2 = entity["position"]
		var to_other: Vector2 = other_pos - my_pos
		var dist: float = to_other.length()

		if dist > VISION_RANGE or dist < 1.0:
			continue

		# Angle check: is the entity within our FOV cone?
		var dir_normalized: Vector2 = to_other.normalized()
		var dot: float = facing_vector.dot(dir_normalized)
		var angle: float = acos(clampf(dot, -1.0, 1.0))

		if angle <= VISION_HALF_ANGLE:
			visible_entities.append({
				"name": entity["name"],
				"position": other_pos,
				"distance": dist,
				"doing": entity.get("doing", ""),
				"facing": entity.get("facing", ""),
			})

func can_see(my_pos: Vector2, target_pos: Vector2) -> bool:
	"""Check if a specific position is within FOV."""
	var to_target: Vector2 = target_pos - my_pos
	var dist: float = to_target.length()
	if dist > VISION_RANGE or dist < 1.0:
		return false
	var dir_normalized: Vector2 = to_target.normalized()
	var dot: float = facing_vector.dot(dir_normalized)
	var angle: float = acos(clampf(dot, -1.0, 1.0))
	return angle <= VISION_HALF_ANGLE

func hear(source_name: String, text: String, source_pos: Vector2, my_pos: Vector2) -> bool:
	"""Process an audible event. Returns true if heard."""
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
