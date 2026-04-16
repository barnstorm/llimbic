extends Node
## res://scripts/game_manager.gd — Time-of-day system (autoload)

signal time_changed(hour: float)
signal day_changed(day: int)

@export var time_scale: float = 1.0  # 1 game-minute = 1 real-second
@export var start_hour: float = 6.0

var current_hour: float = 6.0
var current_day: int = 1

var _convo_log: FileAccess = null

func _ready() -> void:
	current_hour = start_hour
	var dir := DirAccess.open("res://")
	if dir and not dir.dir_exists("logs"):
		dir.make_dir("logs")
	_convo_log = FileAccess.open("res://logs/conversations.log", FileAccess.WRITE)
	if _convo_log:
		_convo_log.store_line("=== Conversations Log ===")

func log_conversation(speaker: String, listener: String, utterance: String, context: String = "") -> void:
	## Write a conversation line to the shared log.
	var timestamp: String = "Day %d %s" % [current_day, get_time_string()]
	var line: String = "[%s] %s → %s: \"%s\"" % [timestamp, speaker, listener, utterance]
	if context != "":
		line += " (%s)" % context
	if _convo_log:
		_convo_log.store_line(line)
		_convo_log.flush()
	print("[CONVO] " + line)

func _process(delta: float) -> void:
	# 1 game-minute per real-second at time_scale=1.0
	var minutes_elapsed: float = delta * time_scale
	var hours_elapsed: float = minutes_elapsed / 60.0
	var old_hour: float = current_hour
	current_hour += hours_elapsed

	if current_hour >= 24.0:
		current_hour -= 24.0
		current_day += 1
		day_changed.emit(current_day)

	# Emit time_changed every half-hour (game time)
	if int(old_hour * 2) != int(current_hour * 2):
		time_changed.emit(current_hour)

func get_time_string() -> String:
	var h: int = int(current_hour)
	var m: int = int(fmod(current_hour * 60.0, 60.0))
	var period: String = "AM" if h < 12 else "PM"
	var display_h: int = h % 12
	if display_h == 0:
		display_h = 12
	return "%d:%02d %s" % [display_h, m, period]

func get_day_string() -> String:
	return "Day " + str(current_day)
