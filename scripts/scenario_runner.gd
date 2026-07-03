extends Node
## res://scripts/scenario_runner.gd — Body-side deterministic disturbance injector.
##
## Armed by the BURG_SCENARIO env var: when set to a path that exists, loads a
## scenario JSON and fires its events at exact physics-frame ticks
## (Engine.get_physics_frames() — the SAME counter burg emits as obs.tick, so
## offline tools can join disturbance->observation row-by-row).
##
## DORMANT when BURG_SCENARIO is unset or points at a missing file: no logs,
## no processing, no scenario_meta — burg runs exactly as today. Mirrors the
## MindLink env-arming pattern (scripts/mind_link.gd:133).
##
## Contract consumed by mind_link.gd:226-230: this node MUST live at
## /root/ScenarioRunner (autoload name = ScenarioRunner) and expose
##   func scenario_meta() -> Dictionary
## armed:  {"id": <str>, "hash": "sha256:<hex of file bytes>"}
## dormant: {}  (empty -> mind_link omits the scenario field from hello).
##
## Determinism: NO randf/randi anywhere. Events come straight from the JSON
## off the frame counter, fired exactly once when at_tick == current tick.
## A bad event NEVER crashes the body — every fire is node-validity-guarded.
##
## §11 instrument-first: block_path / spawn_threat / sensory_blackout are
## honest stubs (logged with stub:true) — see §11 of the spec. teleport_npc,
## move_entity, drive_shock are fully implemented.

# --- Armed state (all immutable after _ready) ---
var _armed: bool = false
var _scenario_id: String = ""
var _file_hash: String = ""           # "sha256:<hex>"
var _events: Array = []               # sorted [{at_tick, kind, params}]
var _cursor: int = 0                  # next unconsumed index into _events

# --- Sensory-blackout window tracking ---
# {npc_name: {"until_tick": int, "saved_profile": Dictionary}}. We zero out the
# NPC's brain._sensor_profile for the window (vision_range=0, hearing_threshold
# above any possible stimulus), restoring the saved profile when the window
# ends. This is a REAL hook: npc_brain.update_perception re-reads the profile
# every tick and passes it to SensorSystem.query_vision / query_hearing_all,
# which early-out on those two keys. No edits to brain/controller/mind_link.
var _blackouts: Dictionary = {}

# --- Log ---
var _log_path: String = ""
var _log_file: FileAccess = null

# --- Public API -----------------------------------------------------------

func scenario_meta() -> Dictionary:
	## Trace-header provenance only (mind_link attaches this to hello). Never
	## consumed as a control signal — instrumentation, per §8 state-vector contract.
	if not _armed:
		return {}
	return {"id": _scenario_id, "hash": _file_hash}

func is_blackout_active(npc_name: String) -> bool:
	## True while a sensory_blackout window covers `npc_name` at the current
	## tick. Read-only probe (used by tests / future instrumentation); the
	## window itself is maintained by _physics_process -> _update_blackouts.
	if not _armed:
		return false
	return _blackouts.has(npc_name)

# --- Lifecycle -----------------------------------------------------------

func _ready() -> void:
	var path: String = OS.get_environment("BURG_SCENARIO")
	if path == "":
		# Not requested — stay fully dormant. burg runs unchanged.
		set_physics_process(false)
		return
	if not FileAccess.file_exists(path):
		push_warning("ScenarioRunner: BURG_SCENARIO=%s not found — staying dormant" % path)
		set_physics_process(false)
		return
	if not _load(path):
		set_physics_process(false)
		return
	_armed = true
	# Lazily open the log on first event write rather than here — if a scenario
	# has zero events we don't want an empty log file. _ensure_log() handles it.
	print("ScenarioRunner: armed id=%s hash=%s events=%d" %
		[_scenario_id, _file_hash, _events.size()])

func _load(path: String) -> bool:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_warning("ScenarioRunner: empty file at %s" % path)
		return false
	# Hash the raw file bytes — the experimenter's source of truth — so any
	# byte-level edit (even whitespace) changes the hash deterministically.
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	var digest: PackedByteArray = ctx.finish()
	var hex: String = ""
	for b in digest:
		hex += "%02x" % b
	_file_hash = "sha256:" + hex

	var text: String = bytes.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("ScenarioRunner: failed to parse JSON at %s (line %d): %s" %
			[path, json.get_error_line(), json.get_error_message()])
		return false
	var data: Variant = json.data
	if not (data is Dictionary):
		push_warning("ScenarioRunner: scenario root is not an object")
		return false
	var d: Dictionary = data
	_scenario_id = String(d.get("id", ""))
	if _scenario_id == "":
		_scenario_id = "unnamed"
	# `seed` is part of the schema but the runner itself doesn't RNG — it is
	# carried for the experimenter's own reproducibility bookkeeping. We do not
	# seed anything here; determinism comes from firing events off the frame
	# counter, not from any RNG.
	var evs: Variant = d.get("events", [])
	if not (evs is Array):
		push_warning("ScenarioRunner: 'events' is not an array; treating as empty")
		evs = []
	# Normalize + sort by at_tick so the cursor advances monotonically. Drop
	# malformed entries loudly rather than crashing later.
	var cleaned: Array = []
	for e in evs:
		if not (e is Dictionary):
			push_warning("ScenarioRunner: skipping non-object event: %s" % str(e))
			continue
		if not e.has("at_tick") or not e.has("kind"):
			push_warning("ScenarioRunner: skipping event missing at_tick/kind: %s" % str(e))
			continue
		var at: int = int(e["at_tick"])
		var kind: String = String(e["kind"])
		var params: Dictionary = e.get("params", {}) if e.get("params", {}) is Dictionary else {}
		cleaned.append({"at_tick": at, "kind": kind, "params": params})
	cleaned.sort_custom(func(a, b): return int(a["at_tick"]) < int(b["at_tick"]))
	_events = cleaned
	return true

func _physics_process(_delta: float) -> void:
	if not _armed:
		return
	_update_blackouts(Engine.get_physics_frames())
	var tick: int = Engine.get_physics_frames()
	# Advance the cursor; fire every event whose at_tick == tick exactly once.
	# Events are pre-sorted, so once we pass at_tick > tick we can stop. Any
	# at_tick in the past on the very first processed frame (e.g. scenario
	# loaded after ticks already elapsed — shouldn't happen since _ready runs
	# before the first _physics_process, but guard anyway) is fired immediately
	# so the disturbance isn't silently lost.
	while _cursor < _events.size() and int(_events[_cursor]["at_tick"]) <= tick:
		var ev: Dictionary = _events[_cursor]
		_fire(ev, tick)
		_cursor += 1

# --- Event dispatch ------------------------------------------------------

func _fire(ev: Dictionary, tick: int) -> void:
	var kind: String = String(ev["kind"])
	var params: Dictionary = ev.get("params", {})
	var stub: bool = false
	var note: String = ""
	# Every kind is wrapped so a bad event (missing NPC, vanished node, bad
	# coords) logs and continues instead of taking the body down.
	var res: Array  # [stub: bool, note: String]
	match kind:
		"teleport_npc":
			res = _do_teleport_npc(params)
		"move_entity":
			res = _do_move_entity(params)
		"drive_shock":
			res = _do_drive_shock(params)
		"sensory_blackout":
			res = _do_sensory_blackout(params, tick)
		"block_path":
			res = [true, "navigation_manager builds AStar2D from collision_map.png at load; no runtime block hook"]
		"spawn_threat":
			res = [true, "burg has no clean runtime entity spawner; threat table removed in Phase 7"]
		_:
			res = [true, "unknown kind"]
	if res.size() >= 1:
		stub = bool(res[0])
	if res.size() >= 2:
		note = String(res[1])
	_write_log(tick, kind, params, stub, note)

# Each _do_* returns Array [stub: bool, note: String]. stub=true means the
# disturbance was logged but NOT applied (cleanly-impossible kinds only, e.g.
# block_path where the navgrid is baked at load). teleport_npc / move_entity /
# drive_shock / sensory_blackout all return stub=false on the happy path.

func _do_teleport_npc(params: Dictionary) -> Array:
	var npc_name: String = String(params.get("npc", ""))
	var pos_arr: Variant = params.get("pos", null)
	if npc_name == "" or not (pos_arr is Array) or pos_arr.size() < 2:
		return [true, "missing/invalid npc or pos"]
	var pos: Vector2 = Vector2(float(pos_arr[0]), float(pos_arr[1]))
	var npc: Node = _find_npc(npc_name)
	if npc == null:
		return [true, "npc '%s' not in group 'npcs'" % npc_name]
	if not (npc is Node2D):
		return [true, "npc '%s' is not a Node2D" % npc_name]
	# CharacterBody2D.global_position — settable. The next physics step will
	# move_and_slide from here. We don't touch velocity; the brain / mind
	# re-derives movement next tick.
	npc.global_position = pos
	return [false, ""]

func _do_move_entity(params: Dictionary) -> Array:
	# GOAL INVALIDATION (§12 cond-5-vs-4 discriminator): move the world object
	# an NPC was heading toward. World objects are pure data in
	# WorldObjectRegistry.objects[id] — each has a "position" Vector2 that
	# brains re-read every perception tick, so mutating the dict moves the
	# object body-side immediately and consistently.
	var name_hint: String = String(params.get("name", ""))
	var id_hint: String = String(params.get("entity_id", params.get("id", "")))
	var pos_arr: Variant = params.get("pos", null)
	if not (pos_arr is Array) or pos_arr.size() < 2:
		return [true, "missing/invalid pos"]
	var pos: Vector2 = Vector2(float(pos_arr[0]), float(pos_arr[1]))
	var registry: Node = get_node_or_null("/root/WorldObjectRegistry")
	if registry == null:
		return [true, "WorldObjectRegistry autoload missing"]
	var target_id: String = ""
	if id_hint != "" and registry.objects.has(id_hint):
		target_id = id_hint
	elif name_hint != "":
		# Linear scan by display name (case-insensitive). There is no name->id
		# index; the registry is small (~25 objects).
		var lower: String = name_hint.to_lower()
		for oid in registry.objects:
			var obj: Dictionary = registry.objects[oid]
			if String(obj.get("name", "")).to_lower() == lower:
				target_id = oid
				break
	if target_id == "":
		return [true, "entity '%s'/'%s' not found in registry" % [name_hint, id_hint]]
	registry.objects[target_id]["position"] = pos
	return [false, "id=%s" % target_id]

func _do_drive_shock(params: Dictionary) -> Array:
	# Perturb drives by deltas. Drives live at npc.brain.layer1.{energy,hunger,
	# social_need,safety} as plain float members, clamped to [0,100] to match
	# the brain's own _apply_drive_effects convention. Schema key is "social"
	# (wire-facing); body-side member is social_need.
	var npc_name: String = String(params.get("npc", ""))
	var drives: Variant = params.get("drives", {})
	if npc_name == "" or not (drives is Dictionary) or drives.is_empty():
		return [true, "missing/invalid npc or drives"]
	var npc: Node = _find_npc(npc_name)
	if npc == null:
		return [true, "npc '%s' not in group 'npcs'" % npc_name]
	if not ("brain" in npc) or npc.brain == null or npc.brain.layer1 == null:
		return [true, "npc '%s' has no brain.layer1" % npc_name]
	var l1: Object = npc.brain.layer1
	var applied: Dictionary = {}
	for d in drives:
		var delta: float = float(drives[d])
		match String(d):
			"energy":
				if "energy" in l1:
					l1.energy = clampf(float(l1.energy) + delta, 0.0, 100.0)
					applied["energy"] = delta
			"hunger":
				if "hunger" in l1:
					l1.hunger = clampf(float(l1.hunger) + delta, 0.0, 100.0)
					applied["hunger"] = delta
			"social", "social_need":
				if "social_need" in l1:
					l1.social_need = clampf(float(l1.social_need) + delta, 0.0, 100.0)
					applied["social"] = delta
			"safety":
				if "safety" in l1:
					l1.safety = clampf(float(l1.safety) + delta, 0.0, 100.0)
					applied["safety"] = delta
	if applied.is_empty():
		return [true, "no recognized drive keys (want energy/hunger/social/safety)"]
	return [false, "applied=%s" % str(applied)]

func _do_sensory_blackout(params: Dictionary, tick: int) -> Array:
	# §9 weak-evidence probe: suppress the controlled NPC's perception (vision
	# AND hearing) for a window starting at `at_tick`. REAL implementation:
	# npc_brain.update_perception re-reads brain._sensor_profile every tick and
	# passes it to SensorSystem.query_vision / query_hearing_all. We zero out
	# vision_range (=0 -> the range check `dist > vision_range` rejects every
	# target) and crank hearing_threshold above any possible perceived_volume
	# (=2.0 -> `perceived_volume >= hearing_threshold` never holds). The
	# original profile is stashed and restored when the window ends.
	#
	# This requires no edits to npc_controller.gd / npc_brain.gd /
	# mind_link.gd / sensor_system.gd — it exploits the existing data flow.
	var npc_name: String = String(params.get("npc", ""))
	var duration: int = int(params.get("duration_ticks", 0))
	if duration <= 0:
		return [true, "duration_ticks must be > 0"]
	# If no npc given, the window applies to all NPCs (the experimenter usually
	# wants the controlled one; with no mind connected, all NPCs run their own
	# cognition and all get blacked out).
	var targets: Array = []
	if npc_name != "":
		targets = [npc_name]
	else:
		for n in get_tree().get_nodes_in_group("npcs"):
			if "npc_name" in n:
				targets.append(String(n.npc_name))
	var until: int = tick + duration
	var applied: Array = []
	for t in targets:
		var npc: Node = _find_npc(t)
		if npc == null or not ("brain" in npc) or npc.brain == null:
			applied.append("%s(missing)" % t)
			continue
		if not ("_sensor_profile" in npc.brain):
			applied.append("%s(no profile)" % t)
			continue
		# Don't clobber a saved profile if a blackout is already active (would
		# otherwise save the zeroed profile and "restore" to blind permanently).
		if not _blackouts.has(t):
			_blackouts[t] = {
				"until_tick": until,
				"saved_profile": npc.brain._sensor_profile.duplicate(true),
			}
		else:
			_blackouts[t]["until_tick"] = until
		var blinded: Dictionary = npc.brain._sensor_profile.duplicate(true)
		blinded["vision_range"] = 0.0
		blinded["hearing_threshold"] = 2.0  # perceived_volume is clamped to [0,1], so 2.0 blocks all
		npc.brain._sensor_profile = blinded
		applied.append(t)
	return [false, "blacked out %s until tick %d" % [str(applied), until]]

func _update_blackouts(tick: int) -> Array:
	## Restore the saved sensor profile for any NPC whose window has elapsed.
	## Called every physics tick from _physics_process.
	if _blackouts.is_empty():
		return []
	var expired: Array = []
	for npc_name in _blackouts.keys():
		var entry: Dictionary = _blackouts[npc_name]
		if tick < int(entry["until_tick"]):
			continue
		var npc: Node = _find_npc(npc_name)
		if npc != null and "brain" in npc and npc.brain != null and "_sensor_profile" in npc.brain:
			npc.brain._sensor_profile = entry["saved_profile"]
		expired.append(npc_name)
	for n in expired:
		_blackouts.erase(n)
	return expired

# --- Helpers -------------------------------------------------------------

func _find_npc(npc_name: String) -> Node:
	## Match by .npc_name in group "npcs" (mirrors mind_link.gd:209).
	if npc_name == "":
		return null
	for npc in get_tree().get_nodes_in_group("npcs"):
		if "npc_name" in npc and String(npc.npc_name) == npc_name:
			return npc
	return null

func _ensure_log() -> bool:
	## Open the log lazily on first event write so an empty-event scenario
	## doesn't create an empty file. Path is OS.get_user_data_dir() (writable
	## on every platform; res:// is read-only in exported builds). The full
	## absolute path is printed once on creation so the experimenter can find it.
	if _log_file != null:
		return true
	var ts: int = Time.get_unix_time_from_system()
	_log_path = OS.get_user_data_dir() + "/scenario_log_%d.jsonl" % ts
	_log_file = FileAccess.open(_log_path, FileAccess.WRITE)
	if _log_file == null:
		push_warning("ScenarioRunner: cannot open log at %s" % _log_path)
		return false
	print("ScenarioRunner: log -> %s" % ProjectSettings.globalize_path(_log_path))
	return true

func _write_log(tick: int, kind: String, params: Dictionary, stub: bool, note: String) -> void:
	if not _ensure_log():
		return
	var line: Dictionary = {
		"tick": tick,
		"kind": kind,
		"params": params,
		"ts": Time.get_unix_time_from_system(),
		"stub": stub,
	}
	if note != "":
		line["note"] = note
	_log_file.store_line(JSON.stringify(line))
	_log_file.flush()
