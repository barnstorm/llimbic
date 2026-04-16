extends Node
## res://scripts/inference_client.gd — Inference client singleton (autoload)
## Both layers use persistent WebSocket connections (multiplexed JSON-RPC).
## Layer 2: ws://127.0.0.1:8420/ws  (fast projection/modulation)
## Layer 3: ws://127.0.0.1:8421/ws  (planning, dialogue, chat)

signal request_completed(request_id: String, success: bool, data: Dictionary)
signal server_push_received(npc_name: String, commands: Array)

const LAYER2_WS_URL: String = "ws://127.0.0.1:8420/ws"
const LAYER3_WS_URL: String = "ws://127.0.0.1:8421/ws"

var _request_counter: int = 0

# --- Layer 2 WebSocket ---
var _ws2: WebSocketPeer = null
var _ws2_connected: bool = false
var _ws2_pending: Dictionary = {}
var _ws2_reconnect_timer: float = 0.0

# --- Layer 3 WebSocket ---
var _ws3: WebSocketPeer = null
var _ws3_connected: bool = false
var _ws3_pending: Dictionary = {}
var _ws3_reconnect_timer: float = 0.0

func _ready() -> void:
	_connect_ws2()
	_connect_ws3()

func _process(delta: float) -> void:
	_poll_ws(_ws2, delta, "_ws2")
	_poll_ws(_ws3, delta, "_ws3")

# --- Generic WebSocket helpers ---

func _connect_ws2() -> void:
	_ws2 = WebSocketPeer.new()
	var err: int = _ws2.connect_to_url(LAYER2_WS_URL)
	if err != OK:
		_ws2 = null
		_ws2_connected = false
		_ws2_reconnect_timer = 25.0  # Try again in ~5s (30-25)

func _connect_ws3() -> void:
	_ws3 = WebSocketPeer.new()
	var err: int = _ws3.connect_to_url(LAYER3_WS_URL)
	if err != OK:
		_ws3 = null
		_ws3_connected = false
		_ws3_reconnect_timer = 25.0

func _poll_ws(ws: WebSocketPeer, delta: float, which: String) -> void:
	# Reconnect logic (30s backoff to avoid spam when server is down)
	if ws == null:
		var timer: float = get(which + "_reconnect_timer")
		timer += delta
		set(which + "_reconnect_timer", timer)
		if timer > 30.0:
			set(which + "_reconnect_timer", 0.0)
			if which == "_ws2":
				_connect_ws2()
			else:
				_connect_ws3()
		return

	ws.poll()
	var state: int = ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		var was_connected: bool = get(which + "_connected")
		if not was_connected:
			set(which + "_connected", true)
			var label: String = "Layer 2" if which == "_ws2" else "Layer 3"
			print("InferenceClient: WebSocket connected to " + label)
		while ws.get_available_packet_count() > 0:
			var text: String = ws.get_packet().get_string_from_utf8()
			_handle_ws_message(text, which)

	elif state == WebSocketPeer.STATE_CLOSING:
		pass  # Wait for full close

	elif state == WebSocketPeer.STATE_CLOSED:
		var was_connected: bool = get(which + "_connected")
		if was_connected:
			var label: String = "Layer 2" if which == "_ws2" else "Layer 3"
			push_warning("InferenceClient: " + label + " WebSocket closed")
		set(which + "_connected", false)
		# Fail pending requests
		var pending: Dictionary = get(which + "_pending")
		for req_id in pending.keys():
			var cb: Callable = pending[req_id]
			if cb.is_valid():
				cb.call(false, {"error": "WebSocket disconnected"})
		pending.clear()
		# Null out so reconnect fires
		if which == "_ws2":
			_ws2 = null
		else:
			_ws3 = null

func _handle_ws_message(text: String, which: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var data: Dictionary = json.data if json.data is Dictionary else {}

	# Handle server push messages (unsolicited, from thought loop)
	if data.get("push", false):
		var npc_name: String = data.get("npc", "")
		var commands: Array = data.get("commands", [])
		if npc_name != "" and commands.size() > 0:
			server_push_received.emit(npc_name, commands)
		return

	var req_id: String = data.get("id", "")
	var pending: Dictionary = get(which + "_pending")
	if req_id == "" or not pending.has(req_id):
		return

	var callback: Callable = pending[req_id]
	pending.erase(req_id)

	if data.has("error"):
		if callback.is_valid():
			callback.call(false, {"error": data["error"]})
		request_completed.emit(req_id, false, {"error": data["error"]})
	else:
		var result: Dictionary = data.get("result", {})
		if callback.is_valid():
			callback.call(true, result)
		request_completed.emit(req_id, true, result)

func _send(ws: WebSocketPeer, connected: bool, pending: Dictionary, method: String, params: Dictionary, callback: Callable) -> String:
	var req_id: String = _next_id()
	if ws == null or not connected:
		callback.call(false, {"error": "WebSocket not connected"})
		return req_id
	pending[req_id] = callback
	var msg: Dictionary = {"id": req_id, "method": method, "params": params}
	ws.send_text(JSON.stringify(msg))
	return req_id

func _next_id() -> String:
	_request_counter += 1
	return "req_" + str(_request_counter)

# --- Layer 2 API ---

func layer2_project(layer1_state: Dictionary, recent_events: Array, current_vector: Array, callback: Callable) -> String:
	return _send(_ws2, _ws2_connected, _ws2_pending, "project", {
		"layer1_state": layer1_state,
		"recent_events": recent_events,
		"current_vector": current_vector
	}, callback)

func layer2_modulate(directives: String, current_vector: Array, callback: Callable) -> String:
	return _send(_ws2, _ws2_connected, _ws2_pending, "modulate", {
		"directives": directives,
		"current_vector": current_vector
	}, callback)

# --- Layer 3 API ---

func layer3_plan(role: String, memory_summary: String, current_context: String, emotion_summary: String, callback: Callable, npc_name_str: String = "") -> String:
	## Legacy prose-based plan request.
	return _send(_ws3, _ws3_connected, _ws3_pending, "plan", {
		"role": role, "npc_name": npc_name_str, "memory_summary": memory_summary,
		"current_context": current_context, "emotion_summary": emotion_summary
	}, callback)

func layer3_plan_packet(packet: Dictionary, callback: Callable) -> String:
	## Structured packet-based plan request. Sends the full packet as-is.
	# Convert Vector2 and non-JSON-safe types in current_chunk
	var safe_packet: Dictionary = packet.duplicate()
	var chunk: Dictionary = safe_packet.get("current_chunk", {})
	if not chunk.is_empty():
		var safe_chunk: Dictionary = {}
		for key in chunk:
			var val = chunk[key]
			if val is Vector2:
				safe_chunk[key] = [val.x, val.y]
			else:
				safe_chunk[key] = val
		safe_packet["current_chunk"] = safe_chunk
	# Convert top_emotions value floats (already safe)
	# Convert problem_objects position fields
	var problems: Array = safe_packet.get("problem_objects", [])
	var safe_problems: Array = []
	for p in problems:
		var sp: Dictionary = p.duplicate()
		if sp.has("position") and sp["position"] is Vector2:
			sp["position"] = [sp["position"].x, sp["position"].y]
		safe_problems.append(sp)
	safe_packet["problem_objects"] = safe_problems
	return _send(_ws3, _ws3_connected, _ws3_pending, "plan_v2", safe_packet, callback)

func layer3_reflect_packet(packet: Dictionary, callback: Callable) -> String:
	## Structured packet-based reflection request.
	return _send(_ws3, _ws3_connected, _ws3_pending, "reflect_v2", packet, callback)

func layer3_reflect(memory_events: Array, callback: Callable, npc_name_str: String = "", npc_role: String = "") -> String:
	return _send(_ws3, _ws3_connected, _ws3_pending, "reflect", {
		"memory_events": memory_events, "npc_name": npc_name_str, "role": npc_role
	}, callback)

func layer3_dialogue(role: String, emotion_summary: String, relationship_context: String, recent_events: Array, callback: Callable, npc_name_str: String = "") -> String:
	## Legacy prose-based dialogue request.
	return _send(_ws3, _ws3_connected, _ws3_pending, "dialogue", {
		"role": role, "npc_name": npc_name_str, "emotion_summary": emotion_summary,
		"relationship_context": relationship_context, "recent_events": recent_events
	}, callback)

func layer3_dialogue_packet(packet: Dictionary, callback: Callable) -> String:
	## Structured packet-based dialogue request.
	return _send(_ws3, _ws3_connected, _ws3_pending, "dialogue_v2", packet, callback)

func layer3_chat_packet(packet: Dictionary, conversation_history: Array, player_message: String, callback: Callable) -> String:
	## Structured packet-based chat request. Merges packet with conversation context.
	var payload: Dictionary = packet.duplicate()
	payload["conversation_history"] = conversation_history
	payload["player_message"] = player_message
	return _send(_ws3, _ws3_connected, _ws3_pending, "chat_v2", payload, callback)

func layer3_converse_packet(speaker_packet: Dictionary, listener_packet: Dictionary, callback: Callable) -> String:
	## Structured packet-based NPC-to-NPC conversation request.
	var payload: Dictionary = {
		"speaker": speaker_packet,
		"listener": listener_packet,
	}
	return _send(_ws3, _ws3_connected, _ws3_pending, "converse_v2", payload, callback)

func layer3_chat(role: String, npc_name_str: String, emotion_summary: String, relationship_context: String, recent_events: Array, conversation_history: Array, player_message: String, callback: Callable) -> String:
	return _send(_ws3, _ws3_connected, _ws3_pending, "chat", {
		"role": role, "npc_name": npc_name_str, "emotion_summary": emotion_summary,
		"relationship_context": relationship_context, "recent_events": recent_events,
		"conversation_history": conversation_history, "player_message": player_message
	}, callback)

func layer3_converse(speaker_role: String, speaker_emotion: String, listener_role: String, listener_emotion: String, shared_context: String, speaker_recent: Array, callback: Callable, speaker_name_str: String = "", listener_name_str: String = "") -> String:
	return _send(_ws3, _ws3_connected, _ws3_pending, "converse", {
		"speaker_role": speaker_role, "speaker_name": speaker_name_str,
		"speaker_emotion": speaker_emotion,
		"listener_role": listener_role, "listener_name": listener_name_str,
		"listener_emotion": listener_emotion,
		"shared_context": shared_context, "speaker_recent": speaker_recent
	}, callback)

# --- Thought loop API ---

func register_npc(npc_name: String, persona: Dictionary) -> String:
	## Register an NPC with the server thought loop.
	return _send(_ws3, _ws3_connected, _ws3_pending, "register_npc", {
		"npc_name": npc_name, "persona": persona
	}, func(_s: bool, _d: Dictionary) -> void: pass)

func send_state_snapshot(snapshot: Dictionary) -> String:
	## Send a state snapshot for the thought loop. Fire-and-forget.
	return _send(_ws3, _ws3_connected, _ws3_pending, "state_update", snapshot,
		func(_s: bool, _d: Dictionary) -> void: pass)

func notify_speech(listener_name: String, listener_role: String, utterance: String, speaker_name: String) -> String:
	## Notify the server that an NPC heard speech — triggers belief extraction.
	return _send(_ws3, _ws3_connected, _ws3_pending, "extract_beliefs", {
		"listener_name": listener_name, "listener_role": listener_role,
		"utterance": utterance, "speaker_name": speaker_name,
	}, func(_s: bool, _d: Dictionary) -> void: pass)

# --- Availability check ---

func is_server_available() -> bool:
	## Returns true if at least one layer connection is up.
	## Callers should check this before making requests.
	return _ws2_connected or _ws3_connected

func is_layer2_available() -> bool:
	return _ws2_connected

func is_layer3_available() -> bool:
	return _ws3_connected
