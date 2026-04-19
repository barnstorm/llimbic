extends Node
## res://scripts/stimulus_registry.gd — Autoload: manages active world stimuli
## Stimuli are world-emitted events (speech, footsteps, presence, impact) with position,
## radius, strength, and duration. Uses spatial grid for fast range queries.

const GRID_CELL_PX: float = 320.0  # 10 tiles at 32px

var _stimuli: Dictionary = {}  # id -> stimulus dict
var _next_id: int = 0
var _grid: Dictionary = {}  # Vector2i -> Array of stimulus ids

func emit(type: String, position: Vector2, radius: float, strength: float, duration: float, tags: Array = [], emitter_id: String = "", emitter_eid: String = "") -> String:
	## Create a new stimulus in the world.
	## type: visual_presence / speech / footstep / impact
	## duration: seconds, -1 for persistent (must be removed manually or refreshed each tick)
	## emitter_id: display name (Hugo/Mabel) — kept for speech attribution.
	## emitter_eid: canonical entity_id (F9). Phase 9 cross-modal binding keys
	##   `sense_heard_{eid}` on this field — leaving it empty means the stimulus
	##   is not per-entity-attributable (e.g. wind, generic impact), and it
	##   won't participate in cross-modal binding. Name must never substitute
	##   for eid here: rename-on-bind (F9) would fragment the heard-neuron family.
	## Returns the stimulus id.
	var id: String = "stim_%d" % _next_id
	_next_id += 1
	var stimulus: Dictionary = {
		"id": id,
		"type": type,
		"position": position,
		"radius": radius,
		"strength": strength,
		"duration": duration,
		"tags": tags,
		"emitter_id": emitter_id,
		"emitter_eid": emitter_eid,
		"created_at": Time.get_ticks_msec(),
		"_elapsed": 0.0,
	}
	_stimuli[id] = stimulus
	_grid_insert(id, position, radius)
	return id

func remove(id: String) -> void:
	## Remove a stimulus by id.
	if _stimuli.has(id):
		var stim: Dictionary = _stimuli[id]
		_grid_remove(id, stim["position"], stim["radius"])
		_stimuli.erase(id)

func get_stimulus(id: String) -> Dictionary:
	return _stimuli.get(id, {})

func get_stimuli_in_range(pos: Vector2, radius: float) -> Array:
	## Return all stimuli whose area overlaps the query circle.
	## Broad phase: spatial grid. Narrow phase: distance check.
	var result: Array = []
	var query_rect: Rect2 = Rect2(pos.x - radius, pos.y - radius, radius * 2.0, radius * 2.0)
	var candidate_ids: Dictionary = {}  # dedup

	var min_cx: int = int(query_rect.position.x / GRID_CELL_PX)
	var max_cx: int = int(query_rect.end.x / GRID_CELL_PX)
	var min_cy: int = int(query_rect.position.y / GRID_CELL_PX)
	var max_cy: int = int(query_rect.end.y / GRID_CELL_PX)

	for cy in range(min_cy, max_cy + 1):
		for cx in range(min_cx, max_cx + 1):
			var key: Vector2i = Vector2i(cx, cy)
			if _grid.has(key):
				for sid in _grid[key]:
					if not candidate_ids.has(sid):
						candidate_ids[sid] = true

	for sid in candidate_ids:
		if not _stimuli.has(sid):
			continue
		var stim: Dictionary = _stimuli[sid]
		var dist: float = pos.distance_to(stim["position"])
		# Check if the query circle overlaps the stimulus circle
		if dist <= radius + stim["radius"]:
			result.append(stim)
	return result

func tick(delta: float) -> void:
	## Called every frame. Removes expired transient stimuli.
	var to_remove: Array = []
	for id in _stimuli:
		var stim: Dictionary = _stimuli[id]
		var dur: float = stim["duration"]
		if dur < 0.0:
			continue  # persistent — never auto-expires
		stim["_elapsed"] += delta
		if stim["_elapsed"] >= dur:
			to_remove.append(id)
	for id in to_remove:
		remove(id)

func get_active_count() -> int:
	return _stimuli.size()

func get_active_by_type(type: String) -> Array:
	var result: Array = []
	for id in _stimuli:
		if _stimuli[id]["type"] == type:
			result.append(_stimuli[id])
	return result

func _process(delta: float) -> void:
	tick(delta)

# --- Spatial grid helpers ---

func _grid_insert(id: String, pos: Vector2, radius: float) -> void:
	var cells: Array = _get_cells(pos, radius)
	for cell in cells:
		if not _grid.has(cell):
			_grid[cell] = []
		_grid[cell].append(id)

func _grid_remove(id: String, pos: Vector2, radius: float) -> void:
	var cells: Array = _get_cells(pos, radius)
	for cell in cells:
		if _grid.has(cell):
			_grid[cell].erase(id)
			if _grid[cell].is_empty():
				_grid.erase(cell)

func _get_cells(pos: Vector2, radius: float) -> Array:
	var min_cx: int = int((pos.x - radius) / GRID_CELL_PX)
	var max_cx: int = int((pos.x + radius) / GRID_CELL_PX)
	var min_cy: int = int((pos.y - radius) / GRID_CELL_PX)
	var max_cy: int = int((pos.y + radius) / GRID_CELL_PX)
	var cells: Array = []
	for cy in range(min_cy, max_cy + 1):
		for cx in range(min_cx, max_cx + 1):
			cells.append(Vector2i(cx, cy))
	return cells
