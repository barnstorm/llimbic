extends RefCounted
## res://scripts/sensory_result_types.gd — Factory functions for VisionResult and HearingResult dictionaries

static func make_vision_result() -> Dictionary:
	return {
		"visible": false,
		"distance": 0.0,
		"exposure": 0.0,
		"confidence": 0.0,
		"sample_hits": 0,
		"sample_total": 0,
		"blocked_by": [],
		"last_visible_point": Vector2.ZERO,
	}

static func make_hearing_result() -> Dictionary:
	return {
		"heard": false,
		"perceived_volume": 0.0,
		"clarity": 0.0,
		"distance": 0.0,
		"direction": Vector2.ZERO,
		"occlusion_loss": 0.0,
		"estimated_source_pos": Vector2.ZERO,
	}

static func actor_sample_offsets() -> Array:
	## Body sample offsets for actor targets (center + 4 body points).
	return [
		Vector2.ZERO,       # center
		Vector2(0, -8),     # top
		Vector2(-10, 0),    # left
		Vector2(10, 0),     # right
		Vector2(0, 8),      # bottom (feet)
	]

static func object_sample_offsets() -> Array:
	## Sample offsets for object targets (center only).
	return [
		Vector2.ZERO,
	]
