extends RefCounted
## res://scripts/sensor_profile.gd — Per-actor sensor configuration loaded from persona JSON

static func make_default() -> Dictionary:
	return {
		"vision_range": 192.0,      # ~6 tiles
		"vision_arc_deg": 90.0,     # full cone angle
		"eye_offset": Vector2.ZERO,
		"hearing_threshold": 0.1,
		"hearing_sensitivity": 1.0,
		"ear_offset": Vector2.ZERO,
	}

static func from_persona(persona: Dictionary) -> Dictionary:
	var profile: Dictionary = make_default()
	var sp: Dictionary = persona.get("sensor_profile", {})
	if sp.is_empty():
		return profile
	if sp.has("vision_range"):
		profile["vision_range"] = float(sp["vision_range"])
	if sp.has("vision_arc_deg"):
		profile["vision_arc_deg"] = float(sp["vision_arc_deg"])
	if sp.has("eye_offset"):
		var eo = sp["eye_offset"]
		if eo is Array and eo.size() >= 2:
			profile["eye_offset"] = Vector2(float(eo[0]), float(eo[1]))
	if sp.has("hearing_threshold"):
		profile["hearing_threshold"] = float(sp["hearing_threshold"])
	if sp.has("hearing_sensitivity"):
		profile["hearing_sensitivity"] = float(sp["hearing_sensitivity"])
	if sp.has("ear_offset"):
		var earr = sp["ear_offset"]
		if earr is Array and earr.size() >= 2:
			profile["ear_offset"] = Vector2(float(earr[0]), float(earr[1]))
	return profile
