extends SceneTree
## res://tests/test_acceleration.gd — Phase 1.5 acceleration acceptance.
##
## Output line (parseable by the calling shell):
##   ACCEL_MEASURE: wall_sec=N.NN sim_sec=N.NN frames=N ratio=N.NN target=N.NN
##
## Usage:
##   godot --path /home/thermos/workspace/burg --headless --quit \
##         --script res://tests/test_acceleration.gd -- WINDOW_SEC

const WINDOW_SEC_DEFAULT: float = 5.0
const MARKER := "ACCEL_MEASURE:"

class _Probe extends Node:
	var sim_seconds: float = 0.0
	var frames: int = 0
	func _process(delta: float) -> void:
		sim_seconds += delta
		frames += 1

var _probe: _Probe = null
var _t_wall_start: float = 0.0
var _t_wall_end: float = 0.0

func _initialize() -> void:
	# Called once when the SceneTree starts. Equivalent to scene-load time.
	var window_sec: float = WINDOW_SEC_DEFAULT
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() >= 1:
		var n: float = args[0].to_float()
		if n > 0.0:
			window_sec = n

	_probe = _Probe.new()
	root.add_child(_probe)
	_t_wall_start = Time.get_unix_time_from_system()
	_t_wall_end = _t_wall_start + window_sec

func _process(delta: float) -> bool:
	# SceneTree._process is called every main-loop iteration.
	# Return true to quit the main loop.
	if Time.get_unix_time_from_system() >= _t_wall_end:
		var wall_actual: float = Time.get_unix_time_from_system() - _t_wall_start
		var ratio: float = _probe.sim_seconds / max(wall_actual, 1e-6)
		var target: float = Engine.time_scale  # read at end so autoload's value is in effect
		print("%s wall_sec=%.3f sim_sec=%.3f frames=%d ratio=%.3f target=%.3f" % [
			MARKER, wall_actual, _probe.sim_seconds, _probe.frames, ratio, target
		])
		return true
	return false
