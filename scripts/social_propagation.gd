extends Node
## res://scripts/social_propagation.gd — Social event exchange between nearby NPCs

var _pulse_timer: float = 0.0
var _pulse_interval: float = 5.0  # every 5 real seconds (~5 game minutes at scale 1)
var _cooldowns: Dictionary = {}  # "npcA:npcB" -> time remaining

func _ready() -> void:
	pass

func _process(delta: float) -> void:
	# Tick cooldowns
	var expired: Array = []
	for key in _cooldowns:
		_cooldowns[key] -= delta
		if _cooldowns[key] <= 0.0:
			expired.append(key)
	for key in expired:
		_cooldowns.erase(key)

	# Pulse
	_pulse_timer += delta
	if _pulse_timer < _pulse_interval:
		return
	_pulse_timer = 0.0

	_do_propagation_pulse()

func _do_propagation_pulse() -> void:
	var npcs: Array = get_tree().get_nodes_in_group("npcs")
	if npcs.size() < 2:
		return

	for i in range(npcs.size()):
		for j in range(i + 1, npcs.size()):
			var npc_a: Node = npcs[i]
			var npc_b: Node = npcs[j]
			_try_exchange(npc_a, npc_b)

func _try_exchange(npc_a: Node, npc_b: Node) -> void:
	# Must be within 2 tiles (64px)
	var dist: float = npc_a.global_position.distance_to(npc_b.global_position)
	if dist > 64.0:
		return

	# Both must have brain with social_need > 30
	if npc_a.brain == null or npc_b.brain == null:
		return
	if npc_a.brain.layer1.social_need < 30.0 or npc_b.brain.layer1.social_need < 30.0:
		return

	# Cooldown check
	var key: String = _pair_key(npc_a.npc_name, npc_b.npc_name)
	if _cooldowns.has(key):
		return

	# Base 50% chance, 2x in public zones
	var chance: float = 0.5
	var location: String = ""
	if npc_a.brain.layer3:
		location = npc_a.brain.layer3.location_name_from_position(npc_a.global_position)
	if location in ["town_square", "market"]:
		chance = 1.0  # 2x

	if randf() > chance:
		return

	# Exchange events
	_exchange_events(npc_a, npc_b)
	_exchange_events(npc_b, npc_a)

	# Set cooldown (5 game minutes = 5 real seconds at scale 1, using 300 seconds base)
	_cooldowns[key] = 300.0  # 5 game minutes at 1 game-min = 1 real-sec

	# Satisfy social need
	npc_a.brain.layer1.social_need = clampf(npc_a.brain.layer1.social_need - 10.0, 0.0, 100.0)
	npc_b.brain.layer1.social_need = clampf(npc_b.brain.layer1.social_need - 10.0, 0.0, 100.0)

func _exchange_events(from_npc: Node, to_npc: Node) -> void:
	var events: Array = from_npc.brain.memory.get_tagged_events_for_exchange()
	if events.is_empty():
		return

	# Pick one random event to share
	var evt: Dictionary = events[randi() % events.size()]
	var new_salience: float = evt["salience"] * 0.7  # 30% reduction
	var desc: String = str(evt["description"])

	# Add as second-hand to receiver
	to_npc.brain.memory.add_tagged_event(
		desc,
		new_salience,
		["second-hand"],
		from_npc.npc_name
	)

	# Record observation
	to_npc.brain.memory.add_observation(
		from_npc.npc_name,
		"nearby",
		"shared gossip"
	)
	from_npc.brain.memory.add_observation(
		to_npc.npc_name,
		"nearby",
		"exchanged stories"
	)

	# Track NPC encounter
	from_npc.brain.on_npc_nearby(to_npc.npc_name)
	to_npc.brain.on_npc_nearby(from_npc.npc_name)

func _pair_key(name_a: String, name_b: String) -> String:
	if name_a < name_b:
		return name_a + ":" + name_b
	return name_b + ":" + name_a
