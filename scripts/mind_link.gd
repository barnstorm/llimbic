extends Node
## res://scripts/mind_link.gd — External-mind link (autoload, WS client).
##
## Demotes Godot to a pure I/O boundary for externally-controlled NPCs: the body
## emits MEASURED observations and applies MOTOR actions over a WebSocket to a
## Python "mind" (LCAEC). The in-Godot cognitive stack is bypassed for those NPCs.
##
## The firewall is structural (see docs/PROTOCOL.md, grounded_control §8): the
## observation carries no cognition-derived fields and the applied action is
## motor-only. This node never reads or writes drive/emotion/intention state; it
## only shuttles the frozen wire messages.
##
## Roles: Mind = server, body = client. We connect to ws://127.0.0.1:8430/ws
## (override with BURG_MIND_URL), send `hello`, and store the `hello_ack` that
## fixes the run (sync mode, which NPCs are controlled, lockstep timing).
##
## DORMANT unless BURG_MIND_URL is set — with it unset, burg behaves exactly as
## before (this autoload does nothing and is_active() stays false).
##
## Modeled on inference_client.gd's WebSocketPeer reconnect/poll loop.

const DEFAULT_URL: String = "ws://127.0.0.1:8430/ws"
const PROTO_VERSION: int = 3

# Action space advertised in the hello (matches PROTOCOL.md; max is the wire
# ceiling, per-NPC clamp uses the NPC's own `speed`).
const VEL_MAX: float = 112.0
const PRIMITIVES: Array = ["consume", "rest", "interact", "face_toward", "speak"]
const OBS_CHANNELS: Array = ["kinematics", "vision", "hearing", "drives", "proprio", "clock"]

# --- Connection state ---
var _url: String = ""
var _enabled: bool = false            # BURG_MIND_URL was set
var _ws: WebSocketPeer = null
var _connected: bool = false          # socket STATE_OPEN
var _reconnect_timer: float = 0.0
const RECONNECT_BACKOFF: float = 3.0  # seconds between reconnect attempts

# --- Handshake result (set on hello_ack) ---
var _acked: bool = false
var _sync_mode: String = "lockstep"
var _control_npcs: Array = []
var _deadline_ms: float = 50.0
var _on_timeout: String = "hold_last"   # or "zero_vel"
var _horizon: int = 1
var _allow_speak: bool = false          # v2: per-run speak gate (default OFF)
var _hello_sent: bool = false

# --- Per-NPC inbox ---
# Latest act per NPC (free-running hold-last).
var _latest_act: Dictionary = {}
# Acts keyed by "npc|seq" awaiting a lockstep consumer.
var _acts_by_seq: Dictionary = {}
# Last seq await_act finished with per NPC. A late act at or below this has no
# awaiter left (it already returned, possibly by timeout) and must be dropped in
# _handle_act, not stored — otherwise _acts_by_seq grows without bound whenever
# delay >= deadline (and on every act in free-running, which never consumes it).
var _last_done_seq: Dictionary = {}
# Diagnostics for the inbox bound (printed periodically only when relevant).
var _dropped_stale: int = 0
var _diag_timer: float = 0.0
const DIAG_INTERVAL: float = 10.0

# v3 actuation echo: last seq whose applied frame was sent, per NPC. Dedupes
# free-running hold-last re-applications (only the FIRST application echoes).
var _last_applied_seq: Dictionary = {}

# --- Public API -----------------------------------------------------------

func is_active() -> bool:
	## True once the handshake completed (hello_ack received) on an open socket.
	return _enabled and _connected and _acked

func is_controlled(npc_name: String) -> bool:
	## Per-NPC external-control toggle. NPCs not listed keep their own cognition.
	return _acked and npc_name in _control_npcs

func sync_mode() -> String:
	return _sync_mode

func deadline_ms() -> float:
	return _deadline_ms

func on_timeout() -> String:
	return _on_timeout

func horizon() -> int:
	return _horizon

func allow_speak() -> bool:
	## v2: whether this run's hello_ack permitted the "speak" primitive.
	return _allow_speak

func send_obs(npc_name: String, obs_dict: Dictionary) -> void:
	## Emit an observation for a controlled NPC. Fire-and-forget.
	if not _connected or _ws == null:
		return
	_ws.send_text(JSON.stringify(obs_dict))

func latest_act(npc_name: String) -> Dictionary:
	## Free-running hold-last: the most recent act for this NPC, or {} if none.
	return _latest_act.get(npc_name, {})

func report_applied(npc_name: String, seq: int) -> void:
	## v3 actuation echo. Called by npc_controller when an act is applied to the
	## actuators; sends {"t":"applied", npc, seq, t_apply} with t_apply on the
	## SAME clock as obs.t_emit, so the mind server can log the true
	## sensing->actuation delay (grounded_control §10) without ever mixing
	## clocks. Fire-and-forget, telemetry only — no mind consumes it (§8).
	## Dedupes by seq: free-running re-applies the same act every frame but only
	## the first application is the actuation event. Timeout/empty acts carry no
	## seq and echo nothing (an act that never actuated has no t_apply).
	if not _connected or _ws == null:
		return
	if seq <= int(_last_applied_seq.get(npc_name, -1)):
		return
	_last_applied_seq[npc_name] = seq
	_ws.send_text(JSON.stringify({
		"t": "applied",
		"npc": npc_name,
		"seq": seq,
		"t_apply": Time.get_unix_time_from_system(),
	}))

func await_act(npc_name: String, seq: int, deadline_ms_arg: float) -> Dictionary:
	## LOCKSTEP: yield (never busy-wait) until the matching act by seq arrives or
	## the deadline elapses. Returns the act dict, or {} on timeout (the caller
	## applies on_timeout policy). Yields on physics_frame so the WS poll in
	## _process keeps running between physics frames.
	var key: String = npc_name + "|" + str(seq)
	# Fast path: it may already be waiting in the inbox.
	if _acts_by_seq.has(key):
		var act: Dictionary = _acts_by_seq[key]
		_acts_by_seq.erase(key)
		_last_done_seq[npc_name] = seq
		return act
	var start_ms: int = Time.get_ticks_msec()
	var tree: SceneTree = get_tree()
	while (Time.get_ticks_msec() - start_ms) < int(deadline_ms_arg):
		# Bail out if the socket dropped mid-wait — no act is coming.
		if not _connected:
			break
		await tree.physics_frame
		if _acts_by_seq.has(key):
			var act2: Dictionary = _acts_by_seq[key]
			_acts_by_seq.erase(key)
			_last_done_seq[npc_name] = seq
			return act2
	# Timed out. Mark this seq done FIRST so a late arrival gets dropped in
	# _handle_act instead of leaking, then clear any entry that raced in.
	_last_done_seq[npc_name] = seq
	_acts_by_seq.erase(key)
	return {}

# --- Lifecycle ------------------------------------------------------------

func _ready() -> void:
	_url = OS.get_environment("BURG_MIND_URL")
	if _url == "":
		# Not requested — stay fully dormant. burg runs unchanged.
		_enabled = false
		set_process(false)
		return
	_enabled = true
	print("MindLink: BURG_MIND_URL=%s — connecting as external-mind body" % _url)
	_connect()

func _process(delta: float) -> void:
	if not _enabled:
		return
	_poll_ws(delta)
	# Inbox-bound diagnostic: only speaks when late acts are being dropped
	# (delay >= deadline), proving _acts_by_seq stays bounded instead of leaking.
	_diag_timer += delta
	if _diag_timer >= DIAG_INTERVAL:
		_diag_timer = 0.0
		if _dropped_stale > 0:
			print("MindLink: inbox=%d dropped_stale=%d" % [_acts_by_seq.size(), _dropped_stale])

func _connect() -> void:
	_ws = WebSocketPeer.new()
	var err: int = _ws.connect_to_url(_url)
	if err != OK:
		push_warning("MindLink: connect_to_url failed (%d), retrying in %.0fs" % [err, RECONNECT_BACKOFF])
		_ws = null
		_connected = false
		_reconnect_timer = 0.0

func _poll_ws(delta: float) -> void:
	# Reconnect with backoff when the socket is down.
	if _ws == null:
		_reconnect_timer += delta
		if _reconnect_timer >= RECONNECT_BACKOFF:
			_reconnect_timer = 0.0
			_connect()
		return

	_ws.poll()
	var state: int = _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			print("MindLink: WebSocket connected to " + _url)
			_send_hello()
		while _ws.get_available_packet_count() > 0:
			var text: String = _ws.get_packet().get_string_from_utf8()
			_handle_message(text)

	elif state == WebSocketPeer.STATE_CLOSING:
		pass  # wait for full close

	elif state == WebSocketPeer.STATE_CLOSED:
		if _connected or _acked:
			push_warning("MindLink: WebSocket closed — reconnecting")
		_reset_connection_state()
		_ws = null
		_reconnect_timer = 0.0

func _reset_connection_state() -> void:
	_connected = false
	_acked = false
	_hello_sent = false
	_allow_speak = false
	# Drop stale acts so a reconnect starts clean (seqs restart per session).
	_acts_by_seq.clear()
	_latest_act.clear()
	_last_done_seq.clear()
	_last_applied_seq.clear()

func _send_hello() -> void:
	if _hello_sent or _ws == null:
		return
	var npcs: Array = []
	for npc in get_tree().get_nodes_in_group("npcs"):
		if "npc_name" in npc and npc.npc_name != "":
			npcs.append(npc.npc_name)
	var hello: Dictionary = {
		"t": "hello",
		"proto": PROTO_VERSION,
		"body_id": "burg",
		"npcs": npcs,
		"action_space": {
			"vel": {"dim": 2, "unit": "px/s", "max": VEL_MAX},
			"primitives": PRIMITIVES,
		},
		"obs_channels": OBS_CHANNELS,
		"physics_tps": Engine.physics_ticks_per_second,
	}
	# v2 experimenter-plane provenance: which scenario the body loaded (if a
	# ScenarioRunner autoload is present and armed). Trace-header metadata only.
	var scenario_runner: Node = get_node_or_null("/root/ScenarioRunner")
	if scenario_runner != null and scenario_runner.has_method("scenario_meta"):
		var meta: Dictionary = scenario_runner.scenario_meta()
		if not meta.is_empty():
			hello["scenario"] = meta
	_ws.send_text(JSON.stringify(hello))
	_hello_sent = true
	print("MindLink: sent hello (npcs=%s)" % str(npcs))

func _handle_message(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("MindLink: failed to parse incoming JSON")
		return
	var data: Dictionary = json.data if json.data is Dictionary else {}
	var t: String = data.get("t", "")
	match t:
		"hello_ack":
			_handle_hello_ack(data)
		"act":
			_handle_act(data)
		"step":
			pass  # explicit-advance control frame; the physics loop already gates per-seq
		"episode":
			var event: String = data.get("event", "")
			print("MindLink: episode %s (%s)" % [event, data.get("reason", "")])
		_:
			# Unknown message type — ignore (the mind is the authority; we only
			# consume what we understand).
			pass

func _handle_hello_ack(data: Dictionary) -> void:
	# Version mismatch fails loudly on both sides (the mind refuses at hello;
	# we refuse the ack) — never run half-upgraded.
	var proto: int = int(data.get("proto", 1))
	if proto != PROTO_VERSION:
		push_error("MindLink: hello_ack proto %d != %d — upgrade the other side; staying inactive" %
			[proto, PROTO_VERSION])
		return
	_sync_mode = data.get("sync", "lockstep")
	var ctrl: Variant = data.get("control_npcs", [])
	_control_npcs = ctrl if ctrl is Array else []
	_horizon = int(data.get("horizon", 1))
	var ls: Dictionary = data.get("lockstep", {}) if data.get("lockstep", {}) is Dictionary else {}
	_deadline_ms = float(ls.get("deadline_ms", 50.0))
	_on_timeout = str(ls.get("on_timeout", "hold_last"))
	_allow_speak = bool(data.get("allow_speak", false))
	_acked = true
	print("MindLink: hello_ack — sync=%s controlling=%s deadline_ms=%.0f on_timeout=%s allow_speak=%s" %
		[_sync_mode, str(_control_npcs), _deadline_ms, _on_timeout, str(_allow_speak)])

func _handle_act(data: Dictionary) -> void:
	var npc_name: String = data.get("npc", "")
	if npc_name == "":
		return
	# Free-running hold-last cache.
	_latest_act[npc_name] = data
	# Lockstep per-seq inbox (echoes obs.seq). Only lockstep consumes this map,
	# and only for seqs still awaited — a late act (its awaiter timed out and
	# returned) is dropped here, which is what bounds the inbox.
	if _sync_mode == "lockstep" and data.has("seq"):
		var seq: int = int(data["seq"])
		if seq <= int(_last_done_seq.get(npc_name, -1)):
			_dropped_stale += 1
			return
		var key: String = npc_name + "|" + str(seq)
		_acts_by_seq[key] = data
