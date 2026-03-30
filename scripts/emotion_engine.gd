extends RefCounted
## res://scripts/emotion_engine.gd — Deterministic emotion projection + modulation
## Replaces the L2 LLM for projection. Runs every tick, zero latency.

# GoEmotions indices
const IDX_ADMIRATION: int = 0
const IDX_AMUSEMENT: int = 1
const IDX_APPROVAL: int = 2
const IDX_CARING: int = 3
const IDX_DESIRE: int = 4
const IDX_EXCITEMENT: int = 5
const IDX_GRATITUDE: int = 6
const IDX_JOY: int = 7
const IDX_LOVE: int = 8
const IDX_OPTIMISM: int = 9
const IDX_PRIDE: int = 10
const IDX_RELIEF: int = 11
const IDX_ANGER: int = 12
const IDX_ANNOYANCE: int = 13
const IDX_DISAPPOINTMENT: int = 14
const IDX_DISAPPROVAL: int = 15
const IDX_DISGUST: int = 16
const IDX_EMBARRASSMENT: int = 17
const IDX_FEAR: int = 18
const IDX_GRIEF: int = 19
const IDX_NERVOUSNESS: int = 20
const IDX_REMORSE: int = 21
const IDX_SADNESS: int = 22
const IDX_CONFUSION: int = 23
const IDX_CURIOSITY: int = 24
const IDX_REALIZATION: int = 25
const IDX_SURPRISE: int = 26

var _baseline: Array = []  # persona baseline vector (gravity attractor)

func setup(persona_baseline: Array) -> void:
	_baseline = persona_baseline
	if _baseline.size() != 27:
		_baseline.clear()
		for i in range(27):
			_baseline.append(0.1)

func compute_emotions(l1_state: Dictionary, recent_events: Array, current_vector: Array) -> Array:
	## Compute updated 27-dim emotion vector from L1 state + events.
	## Deterministic, no LLM. Runs every tick.
	if current_vector.size() != 27:
		return _baseline.duplicate()

	var vec: Array = current_vector.duplicate()

	# Gravity toward persona baseline (slow pull)
	for i in range(27):
		vec[i] = vec[i] * 0.97 + _baseline[i] * 0.03

	# --- L1 state → emotion mapping (ported from layer2_model.py heuristics) ---
	var energy: float = l1_state.get("energy", 80.0)
	var hunger: float = l1_state.get("hunger", 20.0)
	var frustration: float = l1_state.get("frustration", 0.0)
	var safety: float = l1_state.get("safety", 80.0)
	var social_need: float = l1_state.get("social_need", 30.0)
	var momentum: float = l1_state.get("task_momentum", 0.0)

	# Low energy → sadness up, excitement down
	if energy < 30.0:
		vec[IDX_SADNESS] = minf(vec[IDX_SADNESS] + 0.02, 1.0)
		vec[IDX_EXCITEMENT] = maxf(vec[IDX_EXCITEMENT] - 0.02, 0.0)

	# High frustration → anger, annoyance
	if frustration > 0.3:
		vec[IDX_ANGER] = minf(vec[IDX_ANGER] + frustration * 0.04, 1.0)
		vec[IDX_ANNOYANCE] = minf(vec[IDX_ANNOYANCE] + frustration * 0.06, 1.0)
		vec[IDX_JOY] = maxf(vec[IDX_JOY] - frustration * 0.02, 0.0)

	# Low safety → fear, nervousness
	if safety < 40.0:
		var danger: float = (40.0 - safety) / 40.0
		vec[IDX_FEAR] = minf(vec[IDX_FEAR] + danger * 0.04, 1.0)
		vec[IDX_NERVOUSNESS] = minf(vec[IDX_NERVOUSNESS] + danger * 0.03, 1.0)

	# High social need → desire, slight sadness
	if social_need > 70.0:
		vec[IDX_DESIRE] = minf(vec[IDX_DESIRE] + 0.02, 1.0)
		vec[IDX_SADNESS] = minf(vec[IDX_SADNESS] + 0.01, 1.0)

	# High hunger → annoyance
	if hunger > 70.0:
		vec[IDX_ANNOYANCE] = minf(vec[IDX_ANNOYANCE] + 0.02, 1.0)

	# High momentum → pride, focus
	if momentum > 0.5:
		vec[IDX_PRIDE] = minf(vec[IDX_PRIDE] + momentum * 0.02, 1.0)

	# Satisfied drives → joy, relief
	if energy > 70.0 and hunger < 30.0 and safety > 70.0:
		vec[IDX_JOY] = minf(vec[IDX_JOY] + 0.01, 1.0)
		vec[IDX_RELIEF] = minf(vec[IDX_RELIEF] + 0.01, 1.0)

	# --- Event-driven spikes ---
	for event in recent_events:
		if event is not String:
			continue
		var ev: String = event.to_lower()
		if "fled" in ev or "fleeing" in ev:
			vec[IDX_FEAR] = minf(vec[IDX_FEAR] + 0.08, 1.0)
			vec[IDX_NERVOUSNESS] = minf(vec[IDX_NERVOUSNESS] + 0.05, 1.0)
		if "interrupted" in ev or "blocked" in ev:
			vec[IDX_ANNOYANCE] = minf(vec[IDX_ANNOYANCE] + 0.05, 1.0)
		if "discovered" in ev or "found" in ev:
			vec[IDX_CURIOSITY] = minf(vec[IDX_CURIOSITY] + 0.06, 1.0)
			vec[IDX_SURPRISE] = minf(vec[IDX_SURPRISE] + 0.04, 1.0)
		if "recovered" in ev or "resumed" in ev:
			vec[IDX_RELIEF] = minf(vec[IDX_RELIEF] + 0.06, 1.0)
		if "talked" in ev or "conversation" in ev:
			vec[IDX_JOY] = minf(vec[IDX_JOY] + 0.03, 1.0)
			vec[IDX_DESIRE] = maxf(vec[IDX_DESIRE] - 0.03, 0.0)
		if "broken" in ev or "empty" in ev:
			vec[IDX_DISAPPOINTMENT] = minf(vec[IDX_DISAPPOINTMENT] + 0.05, 1.0)
			vec[IDX_CONFUSION] = minf(vec[IDX_CONFUSION] + 0.03, 1.0)
		if "insult" in ev or "rude" in ev:
			vec[IDX_ANGER] = minf(vec[IDX_ANGER] + 0.1, 1.0)
			vec[IDX_DISAPPROVAL] = minf(vec[IDX_DISAPPROVAL] + 0.06, 1.0)

	# Clamp all
	for i in range(27):
		vec[i] = clampf(vec[i], 0.0, 1.0)

	return vec

func compute_modulation(emotion_vector: Array, chunk_priority: float) -> Dictionary:
	## Compute L1 modulation parameters from emotion state + chunk priority.
	## Deterministic fixed mapping, runs every tick.
	if emotion_vector.size() != 27:
		return {"learning_rate_mod": 1.0, "exploration_bias": 0.0, "attention_weight": 1.0, "interruption_sensitivity": 0.5, "persistence_scale": 1.0}

	var fear: float = emotion_vector[IDX_FEAR]
	var curiosity: float = emotion_vector[IDX_CURIOSITY]
	var anger: float = emotion_vector[IDX_ANGER]
	var joy: float = emotion_vector[IDX_JOY]
	var pride: float = emotion_vector[IDX_PRIDE]
	var nervousness: float = emotion_vector[IDX_NERVOUSNESS]

	# Negative valence aggregate
	var neg_sum: float = 0.0
	for i in range(12, 23):
		neg_sum += emotion_vector[i]

	return {
		"learning_rate_mod": clampf(1.0 + curiosity * 0.5 - fear * 0.3, 0.5, 2.0),
		"exploration_bias": clampf(curiosity * 0.8 - fear * 0.4 - nervousness * 0.2, 0.0, 1.0),
		"attention_weight": clampf(0.5 + fear * 0.3 + chunk_priority * 0.2, 0.0, 1.0),
		"interruption_sensitivity": clampf(0.5 - chunk_priority * 0.3 + curiosity * 0.2 - pride * 0.1, 0.0, 1.0),
		"persistence_scale": clampf(1.0 + chunk_priority * 0.5 + anger * 0.2 + pride * 0.2 - neg_sum * 0.05, 0.5, 2.0),
	}
