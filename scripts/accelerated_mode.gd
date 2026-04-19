extends Node
## res://scripts/accelerated_mode.gd — accelerated-simulation harness (autoload).
##
## Phase 1.5 of docs/perception_implementation_plan.md.
##
## Reads BURG_ACCEL from the environment at startup. If set to a positive
## number, sets Engine.time_scale to that value, accelerating every per-frame
## delta by the same factor.
##
## What scales:
##   - Hebbian propagate / hebbian_update / neurogenesis / somatic emit
##   - Drive baseline drift in layer1_substrate
##   - Animation / movement (NPC speed_mul × delta)
##   - Reward decay (decay_reward(delta))
##
## What does NOT scale:
##   - LLM thought cycles (cadence is wall-clock-gated by min/max_thought_interval).
##     The plan calls this out explicitly: "LLM calls remain real."
##   - Trace timestamps (Python side, time.time())
##
## Acceptance per plan:
##   - 1 wall-clock hour produces ≥10 simulated hours of substrate ticks
##   - Substrate behavior on probe scenes matches real-time within noise
##
## Usage:
##   BURG_ACCEL=10 godot --headless --path . scenes/main.tscn
##   (or via scripts/run_accelerated.sh)

const ENV_VAR: String = "BURG_ACCEL"
const DEFAULT_SCALE: float = 1.0
const MAX_SCALE: float = 60.0  # safety cap; physics gets unstable past this

var scale: float = DEFAULT_SCALE

func _enter_tree() -> void:
	# Read once, before any other autoload starts ticking.
	var raw: String = OS.get_environment(ENV_VAR)
	if raw == "":
		print("[AcceleratedMode] disabled (BURG_ACCEL unset). time_scale=%.1f" % Engine.time_scale)
		return
	var parsed: float = raw.to_float()
	if parsed <= 0.0:
		print("[AcceleratedMode] BURG_ACCEL=%s invalid; staying at 1x" % raw)
		return
	scale = clampf(parsed, 0.1, MAX_SCALE)
	Engine.time_scale = scale
	# Speed up physics ticks too so Hebbian / drive updates aren't bottlenecked
	# by the default 60 Hz physics rate. At higher acceleration we want more
	# physics frames per wall-second so per-frame delta stays small.
	Engine.physics_ticks_per_second = int(clamp(60.0 * scale, 60.0, 240.0))
	print("[AcceleratedMode] ENABLED time_scale=%.1fx physics_tps=%d" %
		[scale, Engine.physics_ticks_per_second])
