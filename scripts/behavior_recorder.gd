extends Node
## Wire-silent behavior recorder for native-vs-controlled parity runs.
##
## Dormant unless BURG_BEHAVIOR_LOG is set. Emits one CSV row/sec/NPC:
## ts,npc,x,y,action,location,stalled

var _path: String = ""
var _file: FileAccess = null
var _accum: float = 0.0

func _ready() -> void:
	_path = OS.get_environment("BURG_BEHAVIOR_LOG")
	if _path == "":
		set_process(false)
		return
	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		push_error("BehaviorRecorder: cannot open " + _path)
		set_process(false)
		return
	_file.store_line("ts,npc,x,y,action,location,stalled")
	set_process(true)

func _process(delta: float) -> void:
	if _file == null:
		return
	_accum += delta
	if _accum < 1.0:
		return
	_accum -= 1.0
	var tree := get_tree()
	if tree == null:
		return
	for npc in tree.get_nodes_in_group("npcs"):
		_record_npc(npc)
	_file.flush()

func _record_npc(npc: Node) -> void:
	var brain = npc.get("brain") if npc != null else null
	var action: String = ""
	var location: String = ""
	var stalled: bool = false
	if brain != null:
		var current_action = brain.get("current_action")
		if current_action is Dictionary:
			action = str(current_action.get("type", ""))
		var layer3 = brain.get("layer3")
		if layer3 != null and npc is Node2D:
			location = layer3.location_name_from_position(npc.global_position)
		var layer1 = brain.get("layer1")
		if layer1 != null:
			stalled = bool(layer1.get("is_stalled"))
	var pos := Vector2.ZERO
	if npc is Node2D:
		pos = npc.global_position
	var npc_name: String = str(npc.get("npc_name"))
	if npc_name == "" or npc_name == "<null>":
		npc_name = npc.name
	_file.store_line("%.3f,%s,%.3f,%.3f,%s,%s,%s" % [
		Time.get_unix_time_from_system(),
		_csv(npc_name),
		pos.x,
		pos.y,
		_csv(action),
		_csv(location),
		"true" if stalled else "false",
	])

func _csv(value: String) -> String:
	var s: String = value.replace("\"", "\"\"")
	if s.contains(",") or s.contains("\"") or s.contains("\n"):
		return "\"" + s + "\""
	return s
