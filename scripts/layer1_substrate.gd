extends RefCounted
## res://scripts/layer1_substrate.gd — Layer 1 behavioral substrate (pure GDScript, no LLM)
## Updates every physics tick. Maintains drives, action tendencies, trust, familiarity.

# Core drives (0-100)
var energy: float = 80.0
var hunger: float = 20.0
var social_need: float = 30.0
var safety: float = 80.0

# Task state (0-1)
var task_momentum: float = 0.0
var interruption_tolerance: float = 0.5
var frustration: float = 0.0
var reorientation_timer: float = 0.0  # seconds of pause after interruption

# Per-entity trust dictionary: entity_name -> float (0-1)
var trust: Dictionary = {}

# Per-location familiarity: location_name -> float (0-1)
var place_familiarity: Dictionary = {}

# Action tendencies (0-1)
var approach: float = 0.5
var avoid: float = 0.1
var observe: float = 0.3
var help: float = 0.3
var flee: float = 0.0

# Modulation inputs from Layer 2 (bounded floats)
var learning_rate_mod: float = 1.0
var exploration_bias: float = 0.0
var attention_weight: float = 1.0
var interruption_sensitivity: float = 0.5
var persistence_scale: float = 1.0

# Role-based defaults
var _role: String = ""
var _is_at_home: bool = false
var _is_at_work: bool = false
var _current_location: String = ""
var _nearby_npcs: int = 0
var _hour: float = 6.0

func setup(role: String) -> void:
	_role = role
	# Role-based starting values
	match role:
		"Guard":
			safety = 90.0
			energy = 90.0
			social_need = 20.0
		"Baker":
			energy = 75.0
			hunger = 10.0
		"Courier":
			energy = 85.0
			social_need = 40.0
		"Innkeeper":
			social_need = 15.0
			energy = 70.0
		"Farmer":
			energy = 85.0
			hunger = 15.0
		"Gossip":
			social_need = 10.0
		"Herbalist":
			safety = 85.0
		"Blacksmith":
			energy = 80.0

func update(delta: float) -> void:
	var rate: float = delta * learning_rate_mod

	# Energy: depletes during activity, recovers at home
	if _is_at_home:
		energy = clampf(energy + 3.0 * rate, 0.0, 100.0)
	else:
		energy = clampf(energy - 0.8 * rate, 0.0, 100.0)

	# Hunger: rises over time
	hunger = clampf(hunger + 0.5 * rate, 0.0, 100.0)
	# Satisfied at food locations
	if _current_location in ["bakery", "inn", "market", "farm"]:
		hunger = clampf(hunger - 2.0 * rate, 0.0, 100.0)

	# Social need: rises over time, satisfied by proximity
	social_need = clampf(social_need + 0.3 * rate, 0.0, 100.0)
	if _nearby_npcs > 0:
		social_need = clampf(social_need - 1.5 * float(_nearby_npcs) * rate, 0.0, 100.0)

	# Safety: recovers in familiar places
	var loc_comfort: float = place_familiarity.get(_current_location, 0.3)
	safety = clampf(safety + (loc_comfort - 0.5) * 2.0 * rate, 0.0, 100.0)
	if _is_at_home:
		safety = clampf(safety + 2.0 * rate, 0.0, 100.0)

	# Task momentum: builds while pursuing plan
	if task_momentum > 0.0:
		task_momentum = clampf(task_momentum + 0.02 * persistence_scale * rate, 0.0, 1.0)
	# Interruption tolerance scales with momentum
	interruption_tolerance = clampf(0.3 + task_momentum * 0.5 - interruption_sensitivity * 0.2, 0.0, 1.0)

	# Frustration: slow decay
	frustration = clampf(frustration - 0.01 * rate, 0.0, 1.0)

	# Reorientation timer: counts down after interruption
	if reorientation_timer > 0.0:
		reorientation_timer = maxf(reorientation_timer - delta, 0.0)

	# Day cycle: energy recovers faster at home at night
	if _hour >= 21.0 or _hour < 6.0:
		if _is_at_home:
			energy = clampf(energy + 5.0 * rate, 0.0, 100.0)

	# Update action tendencies
	_update_tendencies()

func _update_tendencies() -> void:
	# Approach: high when social, low energy reduces
	approach = clampf((100.0 - social_need) / 100.0 * 0.6 + energy / 100.0 * 0.3 + exploration_bias * 0.3, 0.0, 1.0)
	# Avoid: high frustration, low safety
	avoid = clampf(frustration * 0.5 + (100.0 - safety) / 100.0 * 0.3, 0.0, 1.0)
	# Observe: moderate baseline, boosted by attention weight
	observe = clampf(0.2 + attention_weight * 0.3, 0.0, 1.0)
	# Help: trust-based, reduced by frustration
	var avg_trust: float = 0.5
	if trust.size() > 0:
		var sum: float = 0.0
		for t in trust.values():
			sum += t
		avg_trust = sum / float(trust.size())
	help = clampf(avg_trust * 0.5 - frustration * 0.3, 0.0, 1.0)
	# Flee: low safety + low energy
	flee = clampf((100.0 - safety) / 100.0 * 0.5 + (100.0 - energy) / 100.0 * 0.2 - 0.3, 0.0, 1.0)

func set_context(hour: float, at_home: bool, at_work: bool, location: String, nearby_count: int) -> void:
	_hour = hour
	_is_at_home = at_home
	_is_at_work = at_work
	_current_location = location
	_nearby_npcs = nearby_count

func apply_interruption() -> void:
	frustration = clampf(frustration + 0.1, 0.0, 1.0)
	task_momentum = clampf(task_momentum - 0.3, 0.0, 1.0)
	# Reorientation cost: NPC pauses before resuming. Higher frustration = longer pause.
	reorientation_timer = 0.5 + frustration * 1.5  # 0.5-2.0 seconds

func start_task() -> void:
	task_momentum = 0.1

func get_state_dict() -> Dictionary:
	return {
		"energy": energy,
		"hunger": hunger,
		"social_need": social_need,
		"safety": safety,
		"task_momentum": task_momentum,
		"interruption_tolerance": interruption_tolerance,
		"frustration": frustration,
		"approach": approach,
		"avoid": avoid,
		"observe": observe,
		"help": help,
		"flee": flee
	}

func should_interrupt_for(urgency: String) -> bool:
	match urgency:
		"critical":
			return true
		"high":
			return frustration < 0.7 and task_momentum < 0.6
		"medium":
			return task_momentum < interruption_tolerance
		_:
			return task_momentum < 0.2
