extends Node
## res://scripts/inference_client.gd — HTTP inference client singleton (autoload)
## Manages async requests to the Python inference server at localhost:8420

signal request_completed(request_id: String, success: bool, data: Dictionary)

const BASE_URL: String = "http://127.0.0.1:8420"
const MAX_CONCURRENT: int = 4
const REQUEST_TIMEOUT: float = 5.0

var _queue: Array[Dictionary] = []
var _active: Array[Dictionary] = []
var _request_counter: int = 0
var _server_available: bool = true
var _last_health_check: float = 0.0
var _health_check_interval: float = 10.0

func _ready() -> void:
	pass

func _process(delta: float) -> void:
	# Process queue
	while _active.size() < MAX_CONCURRENT and _queue.size() > 0:
		var req_data: Dictionary = _queue.pop_front()
		_send_request(req_data)

	# Periodic health check
	_last_health_check += delta
	if _last_health_check > _health_check_interval:
		_last_health_check = 0.0
		_check_health()

func layer2_project(layer1_state: Dictionary, recent_events: Array, current_vector: Array, callback: Callable) -> String:
	var request_id: String = _next_id()
	var body: Dictionary = {
		"layer1_state": layer1_state,
		"recent_events": recent_events,
		"current_vector": current_vector
	}
	_enqueue(request_id, "/layer2/project", body, callback)
	return request_id

func layer2_modulate(directives: String, current_vector: Array, callback: Callable) -> String:
	var request_id: String = _next_id()
	var body: Dictionary = {
		"directives": directives,
		"current_vector": current_vector
	}
	_enqueue(request_id, "/layer2/modulate", body, callback)
	return request_id

func layer3_plan(role: String, memory_summary: String, current_context: String, emotion_summary: String, callback: Callable) -> String:
	var request_id: String = _next_id()
	var body: Dictionary = {
		"role": role,
		"memory_summary": memory_summary,
		"current_context": current_context,
		"emotion_summary": emotion_summary
	}
	_enqueue(request_id, "/layer3/plan", body, callback)
	return request_id

func layer3_reflect(memory_events: Array, callback: Callable) -> String:
	var request_id: String = _next_id()
	var body: Dictionary = {
		"memory_events": memory_events
	}
	_enqueue(request_id, "/layer3/reflect", body, callback)
	return request_id

func layer3_dialogue(role: String, emotion_summary: String, relationship_context: String, recent_events: Array, callback: Callable) -> String:
	var request_id: String = _next_id()
	var body: Dictionary = {
		"role": role,
		"emotion_summary": emotion_summary,
		"relationship_context": relationship_context,
		"recent_events": recent_events
	}
	_enqueue(request_id, "/layer3/dialogue", body, callback)
	return request_id

func is_server_available() -> bool:
	return _server_available

func _next_id() -> String:
	_request_counter += 1
	return "req_" + str(_request_counter)

func _enqueue(request_id: String, endpoint: String, body: Dictionary, callback: Callable) -> void:
	_queue.append({
		"id": request_id,
		"endpoint": endpoint,
		"body": body,
		"callback": callback
	})

func _send_request(req_data: Dictionary) -> void:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT
	add_child(http)

	var url: String = BASE_URL + req_data["endpoint"]
	var json_body: String = JSON.stringify(req_data["body"])
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])

	var entry: Dictionary = {
		"id": req_data["id"],
		"http": http,
		"callback": req_data["callback"],
		"endpoint": req_data["endpoint"]
	}
	_active.append(entry)

	http.request_completed.connect(_on_request_completed.bind(entry))
	var err: int = http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		_handle_failure(entry, "HTTP request error: " + str(err))

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, entry: Dictionary) -> void:
	# Remove from active
	_active.erase(entry)

	# Clean up HTTPRequest node
	if is_instance_valid(entry["http"]):
		entry["http"].queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_handle_failure(entry, "HTTP error: result=" + str(result) + " code=" + str(response_code))
		return

	_server_available = true
	var json := JSON.new()
	var parse_err: int = json.parse(body.get_string_from_utf8())
	if parse_err != OK:
		_handle_failure(entry, "JSON parse error")
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}
	var callback: Callable = entry["callback"]
	if callback.is_valid():
		callback.call(true, data)
	request_completed.emit(entry["id"], true, data)

func _handle_failure(entry: Dictionary, reason: String) -> void:
	if is_instance_valid(entry.get("http")):
		entry["http"].queue_free()
	_active.erase(entry)
	_server_available = false

	var callback: Callable = entry["callback"]
	if callback.is_valid():
		callback.call(false, {"error": reason})
	request_completed.emit(entry["id"], false, {"error": reason})

func _check_health() -> void:
	var http := HTTPRequest.new()
	http.timeout = 3.0
	add_child(http)
	http.request_completed.connect(_on_health_check.bind(http))
	var err: int = http.request(BASE_URL + "/health", PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		_server_available = false
		http.queue_free()

func _on_health_check(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray, http: HTTPRequest) -> void:
	if is_instance_valid(http):
		http.queue_free()
	_server_available = (result == HTTPRequest.RESULT_SUCCESS and response_code == 200)
