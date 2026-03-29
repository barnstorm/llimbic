extends Node
## res://scripts/inference_client.gd — Inference client singleton (autoload)
## Layer 2: HTTP requests to localhost:8420
## Layer 3: WebSocket to localhost:8421/ws (persistent connection)

signal request_completed(request_id: String, success: bool, data: Dictionary)

const LAYER2_URL: String = "http://127.0.0.1:8420"
const LAYER3_WS_URL: String = "ws://127.0.0.1:8421/ws"
const MAX_CONCURRENT: int = 10
const REQUEST_TIMEOUT: float = 30.0

# HTTP queue for Layer 2
var _queue: Array[Dictionary] = []
var _active: Array[Dictionary] = []
var _request_counter: int = 0
var _server_available: bool = true
var _last_health_check: float = 0.0
var _health_check_interval: float = 10.0

# WebSocket for Layer 3
var _ws: WebSocketPeer = null
var _ws_connected: bool = false
var _ws_pending: Dictionary = {}  # request_id -> callback
var _ws_reconnect_timer: float = 0.0
var _ws_buffer: String = ""

func _ready() -> void:
	_connect_ws()

func _process(delta: float) -> void:
	# Process HTTP queue (Layer 2)
	while _active.size() < MAX_CONCURRENT and _queue.size() > 0:
		var req_data: Dictionary = _queue.pop_front()
		_send_http_request(req_data)

	# Periodic health check for Layer 2
	_last_health_check += delta
	if _last_health_check > _health_check_interval:
		_last_health_check = 0.0
		_check_health()

	# Poll WebSocket (Layer 3)
	_poll_ws(delta)

# ---- WebSocket (Layer 3) ----

func _connect_ws() -> void:
	_ws = WebSocketPeer.new()
	var err: int = _ws.connect_to_url(LAYER3_WS_URL)
	if err != OK:
		push_warning("InferenceClient: WebSocket connect failed: " + str(err))
		_ws = null
		_ws_connected = false

func _poll_ws(delta: float) -> void:
	if _ws == null:
		_ws_reconnect_timer += delta
		if _ws_reconnect_timer > 5.0:
			_ws_reconnect_timer = 0.0
			_connect_ws()
		return

	_ws.poll()
	var state: int = _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_connected:
			_ws_connected = true
			print("InferenceClient: WebSocket connected to Layer 3")
		# Read all available messages
		while _ws.get_available_packet_count() > 0:
			var pkt: PackedByteArray = _ws.get_packet()
			var text: String = pkt.get_string_from_utf8()
			_handle_ws_message(text)
	elif state == WebSocketPeer.STATE_CLOSED:
		var code: int = _ws.get_close_code()
		if _ws_connected:
			push_warning("InferenceClient: WebSocket closed (code " + str(code) + ")")
		_ws_connected = false
		_ws = null
		# Fail all pending L3 requests
		for req_id in _ws_pending.keys():
			var cb: Callable = _ws_pending[req_id]
			if cb.is_valid():
				cb.call(false, {"error": "WebSocket disconnected"})
		_ws_pending.clear()
	elif state == WebSocketPeer.STATE_CONNECTING:
		pass  # Still connecting

func _handle_ws_message(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("InferenceClient: Bad WS JSON: " + text.substr(0, 100))
		return
	var data: Dictionary = json.data if json.data is Dictionary else {}
	var req_id: String = data.get("id", "")
	if req_id == "" or not _ws_pending.has(req_id):
		return

	var callback: Callable = _ws_pending[req_id]
	_ws_pending.erase(req_id)

	if data.has("error"):
		if callback.is_valid():
			callback.call(false, {"error": data["error"]})
		request_completed.emit(req_id, false, {"error": data["error"]})
	else:
		var result: Dictionary = data.get("result", {})
		if callback.is_valid():
			callback.call(true, result)
		request_completed.emit(req_id, true, result)

func _send_ws(method: String, params: Dictionary, callback: Callable) -> String:
	var req_id: String = _next_id()
	if _ws == null or not _ws_connected:
		# Queue will be lost — call back with failure
		callback.call(false, {"error": "WebSocket not connected"})
		return req_id

	_ws_pending[req_id] = callback
	var msg: Dictionary = {"id": req_id, "method": method, "params": params}
	_ws.send_text(JSON.stringify(msg))
	return req_id

# ---- Layer 2 (HTTP) ----

func layer2_project(layer1_state: Dictionary, recent_events: Array, current_vector: Array, callback: Callable) -> String:
	var request_id: String = _next_id()
	var body: Dictionary = {
		"layer1_state": layer1_state,
		"recent_events": recent_events,
		"current_vector": current_vector
	}
	_enqueue_http(request_id, "/layer2/project", body, callback)
	return request_id

func layer2_modulate(directives: String, current_vector: Array, callback: Callable) -> String:
	var request_id: String = _next_id()
	var body: Dictionary = {
		"directives": directives,
		"current_vector": current_vector
	}
	_enqueue_http(request_id, "/layer2/modulate", body, callback)
	return request_id

# ---- Layer 3 (WebSocket) ----

func layer3_plan(role: String, memory_summary: String, current_context: String, emotion_summary: String, callback: Callable) -> String:
	return _send_ws("plan", {
		"role": role, "memory_summary": memory_summary,
		"current_context": current_context, "emotion_summary": emotion_summary
	}, callback)

func layer3_reflect(memory_events: Array, callback: Callable) -> String:
	return _send_ws("reflect", {"memory_events": memory_events}, callback)

func layer3_dialogue(role: String, emotion_summary: String, relationship_context: String, recent_events: Array, callback: Callable) -> String:
	return _send_ws("dialogue", {
		"role": role, "emotion_summary": emotion_summary,
		"relationship_context": relationship_context, "recent_events": recent_events
	}, callback)

func layer3_chat(role: String, npc_name_str: String, emotion_summary: String, relationship_context: String, recent_events: Array, conversation_history: Array, player_message: String, callback: Callable) -> String:
	return _send_ws("chat", {
		"role": role, "npc_name": npc_name_str, "emotion_summary": emotion_summary,
		"relationship_context": relationship_context, "recent_events": recent_events,
		"conversation_history": conversation_history, "player_message": player_message
	}, callback)

func layer3_converse(speaker_role: String, speaker_emotion: String, listener_role: String, listener_emotion: String, shared_context: String, speaker_recent: Array, callback: Callable) -> String:
	return _send_ws("converse", {
		"speaker_role": speaker_role, "speaker_emotion": speaker_emotion,
		"listener_role": listener_role, "listener_emotion": listener_emotion,
		"shared_context": shared_context, "speaker_recent": speaker_recent
	}, callback)

func is_server_available() -> bool:
	return _server_available

# ---- HTTP internals ----

func _next_id() -> String:
	_request_counter += 1
	return "req_" + str(_request_counter)

func _enqueue_http(request_id: String, endpoint: String, body: Dictionary, callback: Callable) -> void:
	_queue.append({
		"id": request_id,
		"endpoint": endpoint,
		"body": body,
		"callback": callback,
	})

func _send_http_request(req_data: Dictionary) -> void:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT
	add_child(http)

	var url: String = LAYER2_URL + req_data["endpoint"]
	var json_body: String = JSON.stringify(req_data["body"])
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])

	var entry: Dictionary = {
		"id": req_data["id"],
		"http": http,
		"callback": req_data["callback"],
		"endpoint": req_data["endpoint"]
	}
	_active.append(entry)

	http.request_completed.connect(_on_http_completed.bind(entry))
	var err: int = http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		_handle_http_failure(entry, "HTTP request error: " + str(err))

func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, entry: Dictionary) -> void:
	_active.erase(entry)
	if is_instance_valid(entry["http"]):
		entry["http"].queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_handle_http_failure(entry, "HTTP error: result=" + str(result) + " code=" + str(response_code))
		return

	_server_available = true
	var json := JSON.new()
	var parse_err: int = json.parse(body.get_string_from_utf8())
	if parse_err != OK:
		_handle_http_failure(entry, "JSON parse error")
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}
	var callback: Callable = entry["callback"]
	if callback.is_valid():
		callback.call(true, data)
	request_completed.emit(entry["id"], true, data)

func _handle_http_failure(entry: Dictionary, reason: String) -> void:
	if is_instance_valid(entry.get("http")):
		entry["http"].queue_free()
	_active.erase(entry)
	push_warning("InferenceClient: " + reason + " for " + str(entry.get("endpoint", "?")))
	var callback: Callable = entry["callback"]
	if callback.is_valid():
		callback.call(false, {"error": reason})
	request_completed.emit(entry["id"], false, {"error": reason})

func _check_health() -> void:
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	http.request_completed.connect(_on_health_check.bind(http))
	var err: int = http.request(LAYER2_URL + "/health", PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()

func _on_health_check(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray, http: HTTPRequest) -> void:
	if is_instance_valid(http):
		http.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		_server_available = true
