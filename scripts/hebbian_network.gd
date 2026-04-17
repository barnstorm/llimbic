extends RefCounted
## res://scripts/hebbian_network.gd — Hebbian neural network with neurogenesis
## Core "reptile brain": neurons, weighted connections, associative learning, neurogenesis.
## No LLM. Pure numeric dynamics.

# --- Neuron storage ---
# Each neuron: {id: String, type: String, activation: float, protected: bool,
#               category: String, age: int, label: String}
var neurons: Array = []
var _neuron_map: Dictionary = {}  # id -> neuron dict (fast lookup)

# --- Connection storage ---
# Each connection: {src: String, dst: String, weight: float}
var connections: Array = []

# --- Hebbian state ---
var _recent_pairs: Dictionary = {}  # "src:dst" -> cooldown ticks remaining
const HEBBIAN_TOP_K: int = 2
const HEBBIAN_THRESHOLD: float = 70.0  # both neurons must exceed this
const HEBBIAN_LR: float = 0.01
const HEBBIAN_DECAY: float = 0.001
const PAIR_COOLDOWN: int = 3  # cycles to skip after updating a pair

# --- Neurogenesis state ---
var stress_count: int = 0
var novelty_count: int = 0
var reward_count: int = 0
const MAX_STRESS: int = 5
const MAX_NOVELTY: int = 6
const MAX_REWARD: int = 6
const MAX_DYNAMIC: int = 32
var _dynamic_count: int = 0
var _next_id: int = 0

# Trigger accumulators (updated externally by substrate)
var sustained_stress_timer: float = 0.0
var novelty_exposure_timer: float = 0.0
var recent_reward_signal: float = 0.0

# Last event for debug
var last_neurogenesis_event: Dictionary = {}  # {type, context, tick}

# --- Propagation constants ---
const PROPAGATION_SCALE: float = 0.1
const DECAY_PER_FRAME: float = 0.998
const NOISE_RANGE: float = 0.05

# Action neuron baselines (floors to prevent collapse)
const ACTION_BASELINES: Dictionary = {
	"action_approach": 20.0,
	"action_avoid": 5.0,
	"action_observe": 20.0,
	"action_help": 15.0,
	"action_flee": 0.0,
}

# Vagal neuron baselines (floors — a being can always potentially feel safe)
const VAGAL_BASELINES: Dictionary = {
	"vagal_ventral": 10.0,
	"vagal_sympathetic": 5.0,
	"vagal_dorsal": 2.0,
}

# Quality neuron emission threshold
const QUALITY_EMIT_THRESHOLD: float = 40.0

# Quality neurogenesis: co-activation tracking
var _quality_coactivation: Dictionary = {}  # "q1:q2" -> {count: int, last_tick: int}
const QUALITY_COACT_THRESHOLD: int = 8  # co-activations before spawning compound

# Vagal neurogenesis state
var vagal_count: int = 0
const MAX_VAGAL: int = 8
var _vagal_coactivation: Dictionary = {}  # "vagal_id:action_id" -> sustained_seconds
const VAGAL_COACT_SPAWN_THRESHOLD: float = 4.0  # seconds of sustained co-activation
const QUALITY_COACT_WINDOW: int = 30000  # 30s window for co-activation counting
var _compound_quality_count: int = 0
const MAX_COMPOUND_QUALITIES: int = 16

# =========================================================================
# SETUP
# =========================================================================

func setup_default_network(persona: Dictionary) -> void:
	neurons.clear()
	connections.clear()
	_neuron_map.clear()
	_dynamic_count = 0
	stress_count = 0
	novelty_count = 0
	reward_count = 0
	_next_id = 0

	# Read drive defaults from persona data
	var drives: Dictionary = persona.get("drive_defaults", {})
	var init_energy: float = float(drives.get("energy", 80.0))
	var init_hunger: float = float(drives.get("hunger", 20.0))
	var init_social: float = float(drives.get("social", 30.0))
	var init_safety: float = float(drives.get("safety", 80.0))

	# --- Fixed neurons ---
	_add_neuron("drive_energy", "drive", init_energy, true, "", "Energy")
	_add_neuron("drive_hunger", "drive", init_hunger, true, "", "Hunger")
	_add_neuron("drive_social", "drive", init_social, true, "", "Social")
	_add_neuron("drive_safety", "drive", init_safety, true, "", "Safety")

	# Task state (stored 0-100, exposed as 0-1 by substrate)
	_add_neuron("task_momentum", "task", 0.0, false, "", "Momentum")
	_add_neuron("task_frustration", "task", 0.0, false, "", "Frustration")
	_add_neuron("task_int_tolerance", "task", 50.0, false, "", "IntTolerance")

	# Salience — fires when the network state warrants executive attention.
	# Starts unconnected. Learns what's worth thinking about through Hebbian
	# co-activation: when salience fires AND the thought loop produces a useful
	# result (action bias change, new intention), the connections that drove
	# salience get reinforced. The being learns its own attention pattern.
	_add_neuron("salience", "task", 0.0, false, "", "Salience")

	# Sensory (protected)
	_add_neuron("sense_at_home", "sensory", 0.0, true, "", "AtHome")
	_add_neuron("sense_at_work", "sensory", 0.0, true, "", "AtWork")
	_add_neuron("sense_hour", "sensory", 25.0, true, "", "Hour")
	_add_neuron("sense_nearby_npcs", "sensory", 0.0, true, "", "NearbyNPCs")
	_add_neuron("sense_is_stalled", "sensory", 0.0, true, "", "IsStalled")
	_add_neuron("sense_loc_familiarity", "sensory", 30.0, true, "", "LocFamiliar")
	_add_neuron("sense_is_night", "sensory", 0.0, true, "", "IsNight")
	_add_neuron("sense_at_food", "sensory", 0.0, true, "", "AtFood")

	# Action tendencies (emergent, read-only from outside)
	_add_neuron("action_approach", "action", 50.0, false, "", "Approach")
	_add_neuron("action_avoid", "action", 10.0, false, "", "Avoid")
	_add_neuron("action_observe", "action", 30.0, false, "", "Observe")
	_add_neuron("action_help", "action", 30.0, false, "", "Help")
	_add_neuron("action_flee", "action", 0.0, false, "", "Flee")

	# --- Arousal drive (master gain) ---
	_add_neuron("drive_arousal", "drive", 30.0, false, "", "Arousal")

	# --- Vagal neurons (autonomic envelope — three competing states) ---
	_add_neuron("vagal_ventral", "vagal", 60.0, false, "", "VentroVagal")       # safe/social (default dominant)
	_add_neuron("vagal_sympathetic", "vagal", 20.0, false, "", "Sympathetic")   # fight/flight
	_add_neuron("vagal_dorsal", "vagal", 5.0, false, "", "DorsalVagal")         # freeze/shutdown

	# --- Emotion sensory neurons (protected, learnable outgoing) ---
	# Activation SET from emotion vector each tick; outgoing connections learn via Hebbian
	_add_emotion_neuron("emo_fear", "Fear")
	_add_emotion_neuron("emo_anger", "Anger")
	_add_emotion_neuron("emo_disgust", "Disgust")
	_add_emotion_neuron("emo_nervousness", "Nervousness")
	_add_emotion_neuron("emo_grief", "Grief")
	_add_emotion_neuron("emo_joy", "Joy")
	_add_emotion_neuron("emo_excitement", "Excitement")
	_add_emotion_neuron("emo_sadness", "Sadness")
	_add_emotion_neuron("emo_embarrassment", "Embarrassment")
	_add_emotion_neuron("emo_relief", "Relief")
	_add_emotion_neuron("emo_curiosity", "Curiosity")

	# --- Quality neurons (somatic tag emitters) ---
	_seed_quality_neurons()

	# --- Initial connections ---
	var role: String = persona.get("role", "Villager")
	_seed_connections(role)

	# Apply persona-specific neural biases
	var biases: Array = persona.get("neural_biases", [])
	for bias in biases:
		if bias is Dictionary and bias.has("src") and bias.has("dst") and bias.has("weight"):
			_adjust_weight(str(bias["src"]), str(bias["dst"]), float(bias["weight"]))

func _add_neuron(id: String, type: String, activation: float, protected: bool, category: String, label: String) -> void:
	var neuron: Dictionary = {
		"id": id,
		"type": type,
		"activation": activation,
		"protected": protected,
		"learnable_outgoing": false,
		"category": category,
		"age": 1000,  # fixed neurons treated as mature
		"label": label,
	}
	neurons.append(neuron)
	_neuron_map[id] = neuron

func _add_emotion_neuron(id: String, label: String) -> void:
	## Emotion sensory neuron — activation SET from emotion vector, outgoing connections learn.
	var neuron: Dictionary = {
		"id": id,
		"type": "emotion_sensory",
		"activation": 0.0,
		"protected": true,
		"learnable_outgoing": true,
		"category": "",
		"age": 1000,
		"label": label,
	}
	neurons.append(neuron)
	_neuron_map[id] = neuron

func _add_quality_neuron(id: String, tag_text: String, regions: Array, activation: float = 10.0) -> void:
	## Add a quality neuron — emits somatic tags when activated.
	## tag_text: the quality word (e.g. "tight", "churning")
	## regions: body regions this quality can bind to (e.g. ["chest", "gut"])
	var neuron: Dictionary = {
		"id": id,
		"type": "quality",
		"activation": activation,
		"protected": false,
		"category": "quality",
		"age": 1000,
		"label": tag_text,
		"tag_text": tag_text,
		"regions": regions,
	}
	neurons.append(neuron)
	_neuron_map[id] = neuron

func _add_connection(src: String, dst: String, weight: float) -> void:
	connections.append({"src": src, "dst": dst, "weight": weight})

func _seed_quality_neurons() -> void:
	## Seed base quality neurons — the body's vocabulary for felt experience.
	## Each quality can bind to multiple body regions.
	## Connections to drives/emotions determine WHEN they fire.

	# SENSATION
	_add_quality_neuron("q_tight",     "tight",       ["chest", "gut", "throat", "muscles"])
	_add_quality_neuron("q_loose",     "loose",       ["muscles", "chest"])
	_add_quality_neuron("q_heavy",     "heavy",       ["muscles", "head", "body"])
	_add_quality_neuron("q_light",     "light",       ["chest", "muscles"])
	_add_quality_neuron("q_hollow",    "hollow",      ["chest", "gut"])
	_add_quality_neuron("q_full",      "full",        ["gut", "chest"])

	# MOVEMENT
	_add_quality_neuron("q_pounding",  "pounding",    ["chest", "head"])
	_add_quality_neuron("q_churning",  "churning",    ["gut"])
	_add_quality_neuron("q_buzzing",   "buzzing",     ["head", "skin"])
	_add_quality_neuron("q_prickling", "prickling",   ["skin"])
	_add_quality_neuron("q_fluttering","fluttering",  ["chest", "gut"])
	_add_quality_neuron("q_crawling",  "crawling",    ["skin"])

	# TEMPERATURE
	_add_quality_neuron("q_warm",      "warm",        ["chest", "skin"])
	_add_quality_neuron("q_cold",      "cold",        ["skin", "chest"])
	_add_quality_neuron("q_numb",      "numb",        ["skin", "muscles", "body"])

	# PRESSURE / STATE
	_add_quality_neuron("q_pressure",  "pressure",    ["head", "chest"])
	_add_quality_neuron("q_constricted","constricted", ["throat", "chest"])
	_add_quality_neuron("q_open",      "open",        ["chest", "throat"])
	_add_quality_neuron("q_restless",  "restless",    ["muscles", "body"])
	_add_quality_neuron("q_settled",   "settled",     ["gut", "body"])
	_add_quality_neuron("q_foggy",     "foggy",       ["head"])
	_add_quality_neuron("q_clear",     "clear",       ["head"])
	_add_quality_neuron("q_coiled",    "coiled",      ["muscles"])
	_add_quality_neuron("q_aching",    "aching",      ["muscles", "head"])
	_add_quality_neuron("q_raw",       "raw",         ["throat", "skin"])
	_add_quality_neuron("q_dry",       "dry",         ["throat"])

	# WHOLE-BODY
	_add_quality_neuron("q_aroused",   "aroused",     ["body"])
	_add_quality_neuron("q_sluggish",  "sluggish",    ["body"])
	_add_quality_neuron("q_drawn",     "drawn",       ["body"])
	_add_quality_neuron("q_urgent",    "urgent",      ["body"])
	_add_quality_neuron("q_empty_need","yearning",    ["body", "chest"])

func _seed_quality_connections() -> void:
	## Wire quality neurons to their source signals.
	## Multiple sources per quality = ambiguity by design.

	# tight: frustration, low safety (inverted via emotion feedback path)
	# Note: drive_safety is HIGH=safe. Direct negative conn means high safety SUPPRESSES tight.
	# Tight activation comes from emotion feedback (fear, anger) and frustration.
	_add_connection("task_frustration", "q_tight", 0.06)
	# loose: safety high
	_add_connection("drive_safety", "q_loose", 0.04)
	# heavy: low energy (inverted — emotion feedback sadness handles this too)
	_add_connection("task_frustration", "q_heavy", 0.03)
	# light: energy high, joy
	_add_connection("drive_energy", "q_light", 0.03)
	# hollow: social need high, hunger high, grief
	_add_connection("drive_social", "q_hollow", 0.05)        # lonely → hollow
	_add_connection("drive_hunger", "q_hollow", 0.04)        # hungry → hollow
	# full: hunger low, safety high
	_add_connection("drive_hunger", "q_full", -0.04)         # sated → full
	_add_connection("drive_safety", "q_full", 0.02)

	# pounding: flee high, arousal high
	_add_connection("action_flee", "q_pounding", 0.08)
	_add_connection("drive_arousal", "q_pounding", 0.04)
	# churning: hunger (fear/nervousness via emotion feedback)
	_add_connection("drive_hunger", "q_churning", 0.04)
	# buzzing: curiosity/arousal (via action_observe + arousal)
	_add_connection("action_observe", "q_buzzing", 0.04)
	_add_connection("drive_arousal", "q_buzzing", 0.03)
	# prickling: flee tendency (low safety via fear emotion feedback)
	_add_connection("action_flee", "q_prickling", 0.06)
	# fluttering: arousal + social (excitement/nervousness ambiguity)
	_add_connection("drive_arousal", "q_fluttering", 0.04)
	_add_connection("drive_social", "q_fluttering", 0.03)
	# crawling: sustained fear (via emotion feedback)
	_add_connection("action_flee", "q_crawling", 0.03)

	# warm: social presence, help tendency
	_add_connection("sense_nearby_npcs", "q_warm", 0.05)
	_add_connection("action_help", "q_warm", 0.03)
	# cold: isolation (low energy via sadness emotion feedback)
	_add_connection("drive_social", "q_cold", 0.03)         # lonely → cold
	# numb: sustained stress (energy collapse via emotion feedback)
	_add_connection("task_frustration", "q_numb", 0.03)

	# pressure: frustration + stalled
	_add_connection("task_frustration", "q_pressure", 0.06)
	_add_connection("sense_is_stalled", "q_pressure", 0.05)
	# constricted: nervousness/fear (via emotion feedback)
	_add_connection("action_flee", "q_constricted", 0.04)
	# open: safety high, social satisfied
	_add_connection("drive_safety", "q_open", 0.04)
	_add_connection("sense_nearby_npcs", "q_open", 0.02)

	# restless: approach high + momentum low
	_add_connection("action_approach", "q_restless", 0.04)
	_add_connection("task_momentum", "q_restless", -0.03)
	# settled: home, fed, safe
	_add_connection("sense_at_home", "q_settled", 0.04)
	_add_connection("drive_safety", "q_settled", 0.03)
	_add_connection("drive_hunger", "q_settled", -0.03)
	# foggy: low energy
	# foggy: sadness/low energy (via emotion feedback)
	_add_connection("task_frustration", "q_foggy", 0.03)
	# clear: high energy, low frustration
	_add_connection("drive_energy", "q_clear", 0.04)
	# coiled: flee + anger/frustration
	_add_connection("action_flee", "q_coiled", 0.05)
	_add_connection("task_frustration", "q_coiled", 0.04)
	# aching: low energy + sustained frustration
	_add_connection("drive_energy", "q_aching", -0.03)
	_add_connection("task_frustration", "q_aching", 0.03)
	# raw: high frustration
	_add_connection("task_frustration", "q_raw", 0.05)
	# dry: nervousness, social need
	_add_connection("drive_social", "q_dry", 0.04)

	# Whole-body states
	_add_connection("drive_arousal", "q_aroused", 0.06)
	_add_connection("drive_energy", "q_sluggish", -0.05)
	_add_connection("drive_arousal", "q_sluggish", -0.04)
	_add_connection("action_approach", "q_drawn", 0.04)
	_add_connection("drive_social", "q_drawn", 0.03)
	_add_connection("task_momentum", "q_urgent", 0.05)
	_add_connection("drive_hunger", "q_urgent", 0.03)
	_add_connection("drive_social", "q_empty_need", 0.05)    # yearning from loneliness
	_add_connection("drive_hunger", "q_empty_need", 0.03)    # yearning from hunger

	# Arousal drive: fed by action neuron activations + novelty
	_add_connection("action_flee", "drive_arousal", 0.06)
	_add_connection("action_approach", "drive_arousal", 0.03)
	_add_connection("action_observe", "drive_arousal", 0.02)
	# Note: familiarity high suppresses arousal via negative weight (correct: high familiarity * -0.03 = lower arousal)
	_add_connection("sense_loc_familiarity", "drive_arousal", -0.02)
	_add_connection("task_frustration", "drive_arousal", 0.03)

func _seed_vagal_connections() -> void:
	## Wire the three vagal neurons into the network.
	## These are learnable connections — Hebbian co-activation will reshape them.
	## Two beings with different experiences will develop different vagal responses.

	# --- Inputs: what activates each vagal state ---
	# Ventral (safe/social): social presence, familiarity, home
	# Note: safety drives ventral WEAKLY — safe doesn't mean calm, calm means calm.
	# Ventral requires active social/environmental signals, not just absence of threat.
	_add_connection("sense_nearby_npcs", "vagal_ventral", 0.06)
	_add_connection("sense_loc_familiarity", "vagal_ventral", 0.04)
	_add_connection("sense_at_home", "vagal_ventral", 0.05)
	_add_connection("drive_safety", "vagal_ventral", 0.03)  # weak — safety helps but doesn't drive

	# Sympathetic (fight/flight): arousal, frustration, active fleeing
	# These need to be strong enough to overcome ventral's inhibition
	_add_connection("drive_arousal", "vagal_sympathetic", 0.07)
	_add_connection("task_frustration", "vagal_sympathetic", 0.06)
	_add_connection("action_flee", "vagal_sympathetic", 0.08)
	# Low safety feeds sympathetic (the actual threat signal)
	# Using frustration and flee as proxies since drive_safety is high=safe

	# Dorsal (freeze/shutdown): sustained sympathetic, extreme stress
	# Dorsal is activated by sympathetic overflow — it's the collapse after fight/flight fails.
	# When sympathetic is low (threat resolved), dorsal has no positive inputs and decays.
	_add_connection("task_frustration", "vagal_dorsal", 0.04)
	_add_connection("vagal_sympathetic", "vagal_dorsal", 0.05)  # prolonged mobilization → collapse

	# --- Mutual inhibition (asymmetric = hierarchy + hysteresis) ---
	# Ventral is polite — easy to dislodge (newest system fails first)
	_add_connection("vagal_ventral", "vagal_sympathetic", -0.04)
	_add_connection("vagal_ventral", "vagal_dorsal", -0.05)
	# Sympathetic is sticky — harder to calm down than to alarm
	_add_connection("vagal_sympathetic", "vagal_ventral", -0.12)
	_add_connection("vagal_sympathetic", "vagal_dorsal", -0.02)  # weak — sympathetic CAN exhaust into dorsal
	# Dorsal is heavy — can't skip straight to safe, but DOES suppress sympathetic
	# (you can't fight when you've collapsed — that's the shutdown)
	_add_connection("vagal_dorsal", "vagal_ventral", -0.15)
	_add_connection("vagal_dorsal", "vagal_sympathetic", -0.08)

	# --- Output to action neurons (direct, learnable) ---
	# Ventral enables social behavior
	_add_connection("vagal_ventral", "action_approach", 0.05)
	_add_connection("vagal_ventral", "action_help", 0.06)
	_add_connection("vagal_ventral", "action_observe", 0.03)
	_add_connection("vagal_ventral", "action_flee", -0.04)
	# Sympathetic enables mobilization
	_add_connection("vagal_sympathetic", "action_flee", 0.06)
	_add_connection("vagal_sympathetic", "action_approach", 0.03)  # fight option
	_add_connection("vagal_sympathetic", "action_help", -0.05)
	_add_connection("vagal_sympathetic", "action_observe", -0.03)  # tunnel vision
	# Dorsal suppresses everything except passive avoidance
	_add_connection("vagal_dorsal", "action_approach", -0.06)
	_add_connection("vagal_dorsal", "action_help", -0.06)
	_add_connection("vagal_dorsal", "action_observe", -0.04)
	_add_connection("vagal_dorsal", "action_flee", -0.04)  # can't even flee
	_add_connection("vagal_dorsal", "action_avoid", 0.04)  # passive only

	# --- Output to quality neurons (vagal colors body sensation) ---
	# Ventral → comfort sensations
	_add_connection("vagal_ventral", "q_settled", 0.04)
	_add_connection("vagal_ventral", "q_warm", 0.03)
	_add_connection("vagal_ventral", "q_open", 0.04)
	# Sympathetic → threat sensations
	_add_connection("vagal_sympathetic", "q_pounding", 0.05)
	_add_connection("vagal_sympathetic", "q_coiled", 0.04)
	_add_connection("vagal_sympathetic", "q_tight", 0.04)
	# Dorsal → shutdown sensations
	_add_connection("vagal_dorsal", "q_numb", 0.06)
	_add_connection("vagal_dorsal", "q_heavy", 0.05)
	_add_connection("vagal_dorsal", "q_foggy", 0.04)
	_add_connection("vagal_dorsal", "q_cold", 0.04)

func _seed_emotion_quality_connections() -> void:
	## No pre-wired emotion→quality connections.
	## Emotions and quality neurons start unconnected. The being discovers
	## what emotions feel like in its body through Hebbian co-activation:
	## fear fires + tight fires (from low safety) → network learns fear→tight.
	## Different beings develop different emotion→body mappings.
	pass

func _seed_emotion_action_connections() -> void:
	## Seed emotion→action/task connections. These replace the hardcoded nudges in
	## layer1_substrate.gd:apply_emotion_feedback(). fear→safety stays hardcoded
	## because drive_safety is protected (propagation can't reach it).
	_add_connection("emo_anger", "task_frustration", 0.06)
	_add_connection("emo_curiosity", "action_observe", 0.06)
	_add_connection("emo_fear", "action_flee", 0.07)
	_add_connection("emo_joy", "action_approach", 0.05)
	_add_connection("emo_nervousness", "action_avoid", 0.05)

func _seed_connections(role: String) -> void:
	# --- Quality neuron connections ---
	_seed_quality_connections()

	# --- Vagal neuron connections ---
	_seed_vagal_connections()

	# --- Emotion → quality + action connections ---
	_seed_emotion_quality_connections()
	_seed_emotion_action_connections()

	# --- Sensory -> Drive (homeostatic) ---
	_add_connection("sense_at_home", "drive_energy", 0.3)    # energy recovers at home
	_add_connection("sense_at_home", "drive_safety", 0.2)    # safe at home
	_add_connection("sense_is_night", "drive_energy", 0.15)  # night + home = sleep recovery
	_add_connection("sense_at_food", "drive_hunger", -0.2)   # hunger drops at food locations
	_add_connection("sense_nearby_npcs", "drive_social", -0.15)  # company satisfies social
	_add_connection("sense_loc_familiarity", "drive_safety", 0.2)  # familiar = safe

	# --- Sensory -> Task ---
	_add_connection("sense_is_stalled", "task_frustration", 0.15)  # stalling builds frustration
	_add_connection("sense_is_stalled", "task_momentum", -0.02)    # stalling erodes momentum

	# --- Task -> Task ---
	_add_connection("task_momentum", "task_int_tolerance", 0.05)   # momentum builds tolerance

	# --- Drive/Task -> Action (replace _update_tendencies formulas) ---
	# approach = f(social_need_inv, energy, exploration_bias)
	_add_connection("drive_social", "action_approach", -0.06)    # high social_need suppresses approach
	_add_connection("drive_energy", "action_approach", 0.03)     # energy enables approach

	# avoid = f(frustration, safety_inv)
	_add_connection("task_frustration", "action_avoid", 0.05)    # frustration drives avoidance
	_add_connection("drive_safety", "action_avoid", -0.03)       # low safety increases avoid

	# observe = f(frustration, attention)
	_add_connection("task_frustration", "action_observe", 0.04)  # frustrated agents scan harder
	_add_connection("sense_is_stalled", "action_observe", 0.03)  # stalled agents look around

	# help = f(trust_avg, frustration_inv) — trust handled externally via modulation
	_add_connection("task_frustration", "action_help", -0.03)    # frustration reduces helpfulness

	# flee = f(safety_inv, energy_inv)
	_add_connection("drive_safety", "action_flee", -0.05)        # low safety triggers flee
	_add_connection("drive_energy", "action_flee", -0.02)        # low energy triggers flee

	# --- Cross-drive influences ---
	_add_connection("drive_hunger", "task_frustration", 0.02)    # extreme hunger is frustrating
	_add_connection("drive_social", "action_observe", 0.02)      # lonely beings watch others

	# Role-specific neural biases are now applied from persona data
	# via neural_biases array in the persona JSON file

func _adjust_weight(src: String, dst: String, delta: float) -> void:
	for conn in connections:
		if conn["src"] == src and conn["dst"] == dst:
			conn["weight"] = clampf(conn["weight"] + delta, -1.0, 1.0)
			return
	# If connection doesn't exist, create it
	_add_connection(src, dst, delta)

# =========================================================================
# CORE API
# =========================================================================

func get_activation(id: String) -> float:
	var n: Dictionary = _neuron_map.get(id, {})
	if n.is_empty():
		return 0.0
	return n["activation"]

func get_vagal_state() -> Dictionary:
	return {
		"ventral": get_activation("vagal_ventral"),
		"sympathetic": get_activation("vagal_sympathetic"),
		"dorsal": get_activation("vagal_dorsal"),
	}

func get_dominant_vagal() -> String:
	var v: float = get_activation("vagal_ventral")
	var s: float = get_activation("vagal_sympathetic")
	var d: float = get_activation("vagal_dorsal")
	if d > s and d > v:
		return "dorsal"
	if s > v:
		return "sympathetic"
	return "ventral"

func set_activation(id: String, value: float) -> void:
	var n: Dictionary = _neuron_map.get(id, {})
	if n.is_empty():
		return
	n["activation"] = clampf(value, 0.0, 100.0)

# =========================================================================
# PROPAGATION — called every physics frame
# =========================================================================

func propagate(delta: float) -> void:
	# Accumulate connection contributions
	var contributions: Dictionary = {}
	for conn in connections:
		var src_n: Dictionary = _neuron_map.get(conn["src"], {})
		if src_n.is_empty():
			continue
		var contribution: float = src_n["activation"] * conn["weight"] * PROPAGATION_SCALE
		if not contributions.has(conn["dst"]):
			contributions[conn["dst"]] = 0.0
		contributions[conn["dst"]] += contribution

	# Apply contributions to non-protected neurons
	var dt_scale: float = delta * 60.0  # normalize to ~1.0 at 60fps
	for neuron in neurons:
		if neuron["protected"]:
			continue
		var extra: float = contributions.get(neuron["id"], 0.0)
		neuron["activation"] += extra * dt_scale

	# Decay and noise for non-protected neurons
	for neuron in neurons:
		if neuron["protected"]:
			continue
		neuron["activation"] = neuron["activation"] * DECAY_PER_FRAME + randf_range(-NOISE_RANGE, NOISE_RANGE)
		neuron["activation"] = clampf(neuron["activation"], 0.0, 100.0)
		if neuron["age"] < 1000:
			neuron["age"] += 1

	# Enforce action neuron baselines
	for id in ACTION_BASELINES:
		var n: Dictionary = _neuron_map.get(id, {})
		if not n.is_empty() and n["activation"] < ACTION_BASELINES[id]:
			n["activation"] = ACTION_BASELINES[id]

	# Enforce vagal neuron baselines
	for id in VAGAL_BASELINES:
		var n: Dictionary = _neuron_map.get(id, {})
		if not n.is_empty() and n["activation"] < VAGAL_BASELINES[id]:
			n["activation"] = VAGAL_BASELINES[id]

# =========================================================================
# HEBBIAN LEARNING — called every ~0.5s
# =========================================================================

func hebbian_update(learning_rate_mod: float) -> void:
	# Tick down pair cooldowns
	var expired: Array = []
	for key in _recent_pairs:
		_recent_pairs[key] -= 1
		if _recent_pairs[key] <= 0:
			expired.append(key)
	for key in expired:
		_recent_pairs.erase(key)

	# Find co-activated connection pairs
	var candidates: Array = []
	for i in connections.size():
		var conn: Dictionary = connections[i]
		var src_n: Dictionary = _neuron_map.get(conn["src"], {})
		var dst_n: Dictionary = _neuron_map.get(conn["dst"], {})
		if src_n.is_empty() or dst_n.is_empty():
			continue
		if src_n["protected"] and not src_n.get("learnable_outgoing", false):
			continue  # don't learn on pure input connections (src side)
		if src_n["activation"] > HEBBIAN_THRESHOLD and dst_n["activation"] > HEBBIAN_THRESHOLD:
			var score: float = src_n["activation"] + dst_n["activation"] + randf_range(0.0, 10.0)
			var pair_key: String = conn["src"] + ":" + conn["dst"]
			if _recent_pairs.has(pair_key):
				continue
			candidates.append({"index": i, "score": score, "key": pair_key})

	# Sort by score descending
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"]
	)

	# Update top K
	var updated: int = 0
	for cand in candidates:
		if updated >= HEBBIAN_TOP_K:
			break
		var conn: Dictionary = connections[cand["index"]]
		var src_act: float = _neuron_map[conn["src"]]["activation"]
		var dst_act: float = _neuron_map[conn["dst"]]["activation"]

		var lr: float = HEBBIAN_LR * learning_rate_mod
		# New neurons learn at 2x rate
		if _neuron_map[conn["src"]]["age"] < 20 or _neuron_map[conn["dst"]]["age"] < 20:
			lr *= 2.0

		var delta_w: float = lr * (src_act / 100.0) * (dst_act / 100.0)
		conn["weight"] = clampf(
			conn["weight"] + delta_w - (conn["weight"] * HEBBIAN_DECAY),
			-1.0, 1.0
		)

		_recent_pairs[cand["key"]] = PAIR_COOLDOWN
		updated += 1

	# Also check for potential NEW connections between highly co-activated neurons
	# that aren't yet connected (spontaneous association)
	if updated < HEBBIAN_TOP_K:
		_check_spontaneous_connections(learning_rate_mod)

func _check_spontaneous_connections(learning_rate_mod: float) -> void:
	# Find pairs of non-protected neurons both above threshold with no existing connection
	var active_neurons: Array = []
	for neuron in neurons:
		if neuron["protected"] and not neuron.get("learnable_outgoing", false):
			continue
		if neuron["activation"] > HEBBIAN_THRESHOLD:
			active_neurons.append(neuron)

	if active_neurons.size() < 2:
		return

	# Check pairs (limit to avoid O(n^2) explosion)
	var checked: int = 0
	for i in active_neurons.size():
		for j in range(i + 1, active_neurons.size()):
			if checked > 10:
				return
			checked += 1
			var a: Dictionary = active_neurons[i]
			var b: Dictionary = active_neurons[j]
			if _connection_exists(a["id"], b["id"]):
				continue
			# Create new connection with small initial weight
			var lr: float = HEBBIAN_LR * learning_rate_mod
			var initial_w: float = lr * (a["activation"] / 100.0) * (b["activation"] / 100.0)
			if absf(initial_w) > 0.001:
				_add_connection(a["id"], b["id"], initial_w)

func _connection_exists(src: String, dst: String) -> bool:
	for conn in connections:
		if (conn["src"] == src and conn["dst"] == dst) or (conn["src"] == dst and conn["dst"] == src):
			return true
	return false

# =========================================================================
# NEUROGENESIS — called every ~2s
# =========================================================================

func check_neurogenesis() -> void:
	if _dynamic_count >= MAX_DYNAMIC:
		return

	# Priority: stress > novelty > reward > vagal
	if _check_stress_neurogenesis():
		return
	if _check_novelty_neurogenesis():
		return
	if _check_reward_neurogenesis():
		return
	_check_vagal_neurogenesis()

func _check_stress_neurogenesis() -> bool:
	if stress_count >= MAX_STRESS:
		# Cap reached — strengthen existing stress neurons instead
		if sustained_stress_timer > 3.0 or get_activation("task_frustration") > 75.0:
			_strengthen_existing("stress")
			sustained_stress_timer = 0.0
		return false

	var frustration: float = get_activation("task_frustration")
	if sustained_stress_timer > 3.0 or frustration > 75.0:
		var context: String = _get_stress_context()
		var neuron_id: String = "dyn_stress_%s_%d" % [context, _next_id]
		_next_id += 1

		_add_neuron(neuron_id, "dynamic", 50.0, false, "stress", "stress(%s)" % context)
		neurons[-1]["age"] = 0  # new neuron

		# Stress neurons inhibit frustration and boost observation
		_add_connection(neuron_id, "task_frustration", -0.1)
		_add_connection("task_frustration", neuron_id, 0.3)  # activated by what they regulate
		_add_connection(neuron_id, "action_observe", 0.05)

		# Context-specific connections
		match context:
			"hunger":
				_add_connection("drive_hunger", neuron_id, 0.2)
				_add_connection(neuron_id, "action_approach", 0.03)
			"safety":
				_add_connection("drive_safety", neuron_id, -0.2)  # low safety activates
				_add_connection(neuron_id, "action_flee", 0.04)
			"social":
				_add_connection("drive_social", neuron_id, 0.2)
				_add_connection(neuron_id, "action_approach", 0.03)
			"blocked":
				_add_connection("sense_is_stalled", neuron_id, 0.3)
				_add_connection(neuron_id, "action_avoid", 0.04)

		stress_count += 1
		_dynamic_count += 1
		sustained_stress_timer = 0.0
		last_neurogenesis_event = {"type": "stress", "context": context, "tick": Time.get_ticks_msec()}
		return true
	return false

func _check_novelty_neurogenesis() -> bool:
	if novelty_count >= MAX_NOVELTY:
		return false

	if novelty_exposure_timer > 5.0 and get_activation("sense_loc_familiarity") < 30.0:
		var neuron_id: String = "dyn_novelty_%d" % _next_id
		_next_id += 1

		_add_neuron(neuron_id, "dynamic", 50.0, false, "novelty", "novelty")
		neurons[-1]["age"] = 0

		# Novelty neurons boost observation and approach
		_add_connection(neuron_id, "action_observe", 0.06)
		_add_connection(neuron_id, "action_approach", 0.04)
		_add_connection("sense_loc_familiarity", neuron_id, -0.15)  # unfamiliar activates
		_add_connection("task_frustration", neuron_id, -0.05)  # frustration suppresses curiosity

		novelty_count += 1
		_dynamic_count += 1
		novelty_exposure_timer = 0.0
		last_neurogenesis_event = {"type": "novelty", "context": "exploration", "tick": Time.get_ticks_msec()}
		return true
	return false

func _check_reward_neurogenesis() -> bool:
	if reward_count >= MAX_REWARD:
		return false

	if recent_reward_signal > 0.0:
		var context: String = _get_reward_context()
		var neuron_id: String = "dyn_reward_%s_%d" % [context, _next_id]
		_next_id += 1

		_add_neuron(neuron_id, "dynamic", 60.0, false, "reward", "reward(%s)" % context)
		neurons[-1]["age"] = 0

		# Reward neurons reinforce the drive-action pathway that led to satisfaction
		_add_connection(neuron_id, "action_approach", 0.05)
		match context:
			"energy":
				_add_connection("drive_energy", neuron_id, 0.15)
				_add_connection(neuron_id, "task_momentum", 0.03)
			"hunger":
				_add_connection("drive_hunger", neuron_id, -0.15)  # satisfied hunger activates
				_add_connection(neuron_id, "action_approach", 0.03)
			"social":
				_add_connection("drive_social", neuron_id, -0.15)
				_add_connection(neuron_id, "action_help", 0.04)
			"safety":
				_add_connection("drive_safety", neuron_id, 0.15)
				_add_connection(neuron_id, "action_observe", 0.03)

		reward_count += 1
		_dynamic_count += 1
		recent_reward_signal = 0.0
		last_neurogenesis_event = {"type": "reward", "context": context, "tick": Time.get_ticks_msec()}
		return true
	return false

func _get_stress_context() -> String:
	# What's causing the most stress right now?
	if get_activation("sense_is_stalled") > 50.0:
		return "blocked"
	var worst: String = "general"
	var worst_val: float = 0.0
	# Check which drive is most extreme
	if get_activation("drive_hunger") > worst_val:
		worst_val = get_activation("drive_hunger")
		worst = "hunger"
	if (100.0 - get_activation("drive_safety")) > worst_val:
		worst_val = 100.0 - get_activation("drive_safety")
		worst = "safety"
	if get_activation("drive_social") > worst_val:
		worst_val = get_activation("drive_social")
		worst = "social"
	if (100.0 - get_activation("drive_energy")) > worst_val:
		worst = "energy"
	return worst

func _get_reward_context() -> String:
	# Which drive is in the best state right now? (just recovered)
	var best: String = "general"
	var best_score: float = -1.0
	# Energy high = good
	if get_activation("drive_energy") > best_score:
		best_score = get_activation("drive_energy")
		best = "energy"
	# Hunger low = good (invert)
	if (100.0 - get_activation("drive_hunger")) > best_score:
		best_score = 100.0 - get_activation("drive_hunger")
		best = "hunger"
	# Social low = good (invert)
	if (100.0 - get_activation("drive_social")) > best_score:
		best_score = 100.0 - get_activation("drive_social")
		best = "social"
	# Safety high = good
	if get_activation("drive_safety") > best_score:
		best = "safety"
	return best

func _strengthen_existing(category: String) -> void:
	# When neurogenesis cap reached, boost existing neurons of this category
	for neuron in neurons:
		if neuron["category"] == category:
			neuron["activation"] = clampf(neuron["activation"] + 10.0, 0.0, 100.0)

func _check_vagal_neurogenesis() -> bool:
	## Spawn vagal-action bridge neurons from sustained co-activation.
	## A being that fights when scared grows a "fight" neuron.
	## A being that freezes grows a "shutdown" neuron.
	## This is how beings individuate their threat responses.
	if vagal_count >= MAX_VAGAL:
		return false

	var dominant: String = get_dominant_vagal()
	var dom_act: float = get_activation("vagal_" + dominant if not dominant.begins_with("vagal_") else dominant)
	# Need to look up properly
	match dominant:
		"ventral":
			dom_act = get_activation("vagal_ventral")
		"sympathetic":
			dom_act = get_activation("vagal_sympathetic")
		"dorsal":
			dom_act = get_activation("vagal_dorsal")

	if dom_act < 60.0:
		return false  # vagal state not strong enough

	# Find co-active action neurons
	var action_ids: Array = ["action_approach", "action_avoid", "action_observe", "action_help", "action_flee"]
	for action_id in action_ids:
		var action_act: float = get_activation(action_id)
		if action_act < 60.0:
			continue

		var key: String = dominant + ":" + action_id
		if not _vagal_coactivation.has(key):
			_vagal_coactivation[key] = 0.0
		_vagal_coactivation[key] += 0.033  # ~2s neurogenesis interval, accumulate

		if _vagal_coactivation[key] >= VAGAL_COACT_SPAWN_THRESHOLD:
			_spawn_vagal_neuron(dominant, action_id)
			_vagal_coactivation.erase(key)
			return true

	# Decay tracking for pairs that stopped co-activating
	var to_erase: Array = []
	for key in _vagal_coactivation:
		var parts: Array = key.split(":")
		if parts.size() < 2:
			to_erase.append(key)
			continue
		var vag_id: String = "vagal_" + parts[0]
		var act_id: String = parts[1]
		var vag_act: float = get_activation(vag_id)
		var act_act: float = get_activation(act_id)
		if vag_act < 50.0 or act_act < 50.0:
			_vagal_coactivation[key] = maxf(_vagal_coactivation[key] - 0.05, 0.0)
			if _vagal_coactivation[key] <= 0.0:
				to_erase.append(key)
	for key in to_erase:
		_vagal_coactivation.erase(key)

	# Ventral sustained without co-active action = secure base
	if dominant == "ventral" and dom_act > 70.0:
		var key: String = "ventral:secure"
		if not _vagal_coactivation.has(key):
			_vagal_coactivation[key] = 0.0
		_vagal_coactivation[key] += 0.033
		if _vagal_coactivation[key] >= VAGAL_COACT_SPAWN_THRESHOLD * 2.0:  # takes longer — resilience is earned
			_spawn_secure_base_neuron()
			_vagal_coactivation.erase(key)
			return true

	return false

func _spawn_vagal_neuron(vagal_state: String, action_id: String) -> void:
	## Create a bridge neuron between a vagal state and an action.
	## This neuron IS the being's learned threat response pattern.
	var action_short: String = action_id.replace("action_", "")
	var context: String = vagal_state + "_" + action_short

	var neuron_id: String = "dyn_vagal_%s_%d" % [context, _next_id]
	_next_id += 1

	_add_neuron(neuron_id, "dynamic", 50.0, false, "vagal", "vagal(%s)" % context)
	neurons[-1]["age"] = 0  # new neuron — learns at 2x rate

	# Wire: vagal state activates this neuron, this neuron boosts the action
	var vagal_id: String = "vagal_" + vagal_state
	_add_connection(vagal_id, neuron_id, 0.2)
	_add_connection(neuron_id, action_id, 0.08)

	# Also connect the action back to the neuron (reinforcement loop)
	_add_connection(action_id, neuron_id, 0.1)

	vagal_count += 1
	_dynamic_count += 1
	last_neurogenesis_event = {
		"type": "vagal",
		"context": context,
		"vagal_state": vagal_state,
		"action": action_short,
		"tick": Time.get_ticks_msec(),
	}

func _spawn_secure_base_neuron() -> void:
	## Create a self-reinforcing ventral neuron — resilience from sustained safety.
	## Makes this being harder to destabilize in the future.
	var neuron_id: String = "dyn_vagal_secure_%d" % _next_id
	_next_id += 1

	_add_neuron(neuron_id, "dynamic", 50.0, false, "vagal", "vagal(secure)")
	neurons[-1]["age"] = 0

	# Self-reinforcing: ventral activates it, it reinforces ventral
	_add_connection("vagal_ventral", neuron_id, 0.15)
	_add_connection(neuron_id, "vagal_ventral", 0.08)
	# Also suppresses sympathetic onset — harder to alarm
	_add_connection(neuron_id, "vagal_sympathetic", -0.05)

	vagal_count += 1
	_dynamic_count += 1
	last_neurogenesis_event = {
		"type": "vagal",
		"context": "secure_base",
		"vagal_state": "ventral",
		"action": "resilience",
		"tick": Time.get_ticks_msec(),
	}

# =========================================================================
# NEUROGENESIS TRACKING — called by substrate each tick
# =========================================================================

func update_stress_tracking(frustration_01: float, safety_01: float, delta: float) -> void:
	# frustration_01 and safety_01 are 0-1 scale from substrate interface
	if frustration_01 > 0.5 or safety_01 < 0.3:
		sustained_stress_timer += delta
	else:
		sustained_stress_timer = maxf(sustained_stress_timer - delta * 0.5, 0.0)

func update_novelty_tracking(familiarity_01: float, delta: float) -> void:
	if familiarity_01 < 0.3:
		novelty_exposure_timer += delta
	else:
		novelty_exposure_timer = maxf(novelty_exposure_timer - delta * 0.5, 0.0)

func signal_reward() -> void:
	recent_reward_signal = 1.0

# =========================================================================
# SOMATIC TAG EMISSION — called every tick by somatic stream
# =========================================================================

func emit_quality_tags(suppression: Dictionary = {}) -> Array:
	## Emit somatic tags from active quality neurons.
	## Returns Array of strings like ["gut:empty:churning", "chest:tight"].
	## suppression: {region: float} — reduces emission probability for suppressed regions.
	var region_qualities: Dictionary = {}  # region -> [quality_text, ...]

	for neuron in neurons:
		if neuron["type"] != "quality":
			continue
		if neuron["activation"] < QUALITY_EMIT_THRESHOLD:
			continue

		var tag_text: String = neuron.get("tag_text", "")
		if tag_text == "":
			continue
		var regions: Array = neuron.get("regions", [])
		if regions.is_empty():
			continue

		# Emission probability scales with activation above threshold
		var intensity: float = (neuron["activation"] - QUALITY_EMIT_THRESHOLD) / (100.0 - QUALITY_EMIT_THRESHOLD)
		var prob: float = clampf(0.2 + intensity * 0.6, 0.1, 0.9)

		# Arousal modulates probability (higher arousal = more tags fire)
		var arousal: float = get_activation("drive_arousal") / 100.0
		prob = clampf(prob + (arousal - 0.3) * 0.3, 0.05, 0.95)

		if randf() > prob:
			continue

		# Assign to regions (pick most relevant based on what drives are active)
		for region in regions:
			# Apply suppression
			var supp: float = suppression.get(region, 0.0)
			if supp > 0.0 and randf() < supp:
				continue
			if not region_qualities.has(region):
				region_qualities[region] = []
			if tag_text not in region_qualities[region]:
				region_qualities[region].append(tag_text)

	# Build a quick lookup: (tag_text, region) -> max activation
	var _quality_act_cache: Dictionary = {}  # "quality:region" -> float
	for neuron in neurons:
		if neuron["type"] != "quality":
			continue
		if neuron["activation"] < QUALITY_EMIT_THRESHOLD:
			continue
		var tt: String = neuron.get("tag_text", "")
		for r in neuron.get("regions", []):
			var key: String = tt + ":" + r
			if not _quality_act_cache.has(key) or neuron["activation"] > _quality_act_cache[key]:
				_quality_act_cache[key] = neuron["activation"]

	# Pick strongest quality per region — one clear sensation, not a wall of noise
	var tags: Array = []
	for region in region_qualities:
		var best_quality: String = ""
		var best_activation: float = 0.0
		for quality in region_qualities[region]:
			# Find the neuron that produced this quality to compare activations
			var act: float = _quality_act_cache.get(quality + ":" + region, 0.0)
			if act > best_activation:
				best_activation = act
				best_quality = quality
		if best_quality != "":
			tags.append(region + ":" + best_quality)

	return tags

func get_active_quality_ids() -> Array:
	## Return IDs of quality neurons above emission threshold.
	## Used by quality neurogenesis to detect co-activation.
	var active: Array = []
	for neuron in neurons:
		if neuron["type"] == "quality" and neuron["activation"] >= QUALITY_EMIT_THRESHOLD:
			active.append(neuron["id"])
	return active

# =========================================================================
# QUALITY NEUROGENESIS — compound qualities from sustained co-activation
# =========================================================================

func check_quality_neurogenesis() -> void:
	## Spawn compound quality neurons when base qualities co-activate repeatedly.
	## These are felt patterns unique to this being — born from experience.
	if _compound_quality_count >= MAX_COMPOUND_QUALITIES:
		return

	var active: Array = get_active_quality_ids()
	if active.size() < 2:
		return

	var now: int = Time.get_ticks_msec()

	# Track co-activation pairs
	for i in range(active.size()):
		for j in range(i + 1, active.size()):
			var key: String = active[i] + ":" + active[j]
			if not _quality_coactivation.has(key):
				_quality_coactivation[key] = {"count": 0, "last_tick": now}

			var entry: Dictionary = _quality_coactivation[key]
			# Only count if enough time passed since last count (avoid frame-spam)
			if now - entry["last_tick"] > 2000:  # 2s minimum between counts
				entry["count"] += 1
				entry["last_tick"] = now

			# Spawn compound if threshold reached
			if entry["count"] >= QUALITY_COACT_THRESHOLD:
				_spawn_compound_quality(active[i], active[j])
				_quality_coactivation.erase(key)
				return  # one per check cycle

	# Expire stale co-activation tracking
	var expired: Array = []
	for key in _quality_coactivation:
		if now - _quality_coactivation[key]["last_tick"] > QUALITY_COACT_WINDOW:
			expired.append(key)
	for key in expired:
		_quality_coactivation.erase(key)

func _spawn_compound_quality(parent_a_id: String, parent_b_id: String) -> void:
	## Create a compound quality neuron that inherits tag fragments from both parents.
	var parent_a: Dictionary = _neuron_map.get(parent_a_id, {})
	var parent_b: Dictionary = _neuron_map.get(parent_b_id, {})
	if parent_a.is_empty() or parent_b.is_empty():
		return

	var tag_a: String = parent_a.get("tag_text", "")
	var tag_b: String = parent_b.get("tag_text", "")
	if tag_a == "" or tag_b == "":
		return

	# Compound tag = bound pair of parent qualities
	var compound_tag: String = tag_a + ":" + tag_b

	# Inherit regions from both parents (union)
	var regions_a: Array = parent_a.get("regions", [])
	var regions_b: Array = parent_b.get("regions", [])
	var compound_regions: Array = regions_a.duplicate()
	for r in regions_b:
		if r not in compound_regions:
			compound_regions.append(r)

	var compound_id: String = "q_compound_%d" % _next_id
	_next_id += 1

	_add_quality_neuron(compound_id, compound_tag, compound_regions, 40.0)
	neurons[-1]["age"] = 0  # new neuron — learns at 2x rate

	# Connect to the same sources as parents (inherit their wiring)
	for conn in connections:
		if conn["dst"] == parent_a_id or conn["dst"] == parent_b_id:
			# Check if connection to this source already exists
			if not _connection_exists(conn["src"], compound_id):
				_add_connection(conn["src"], compound_id, conn["weight"] * 0.5)

	# Also connect parents to compound (co-activation reinforces it)
	_add_connection(parent_a_id, compound_id, 0.15)
	_add_connection(parent_b_id, compound_id, 0.15)

	_compound_quality_count += 1
	last_neurogenesis_event = {
		"type": "compound_quality",
		"context": compound_tag,
		"parents": [parent_a_id, parent_b_id],
		"tick": Time.get_ticks_msec(),
	}

# =========================================================================
# DEBUG
# =========================================================================

func get_neuron_count() -> int:
	return neurons.size()

func get_connection_count() -> int:
	return connections.size()

func get_dynamic_neuron_count() -> int:
	return _dynamic_count

func get_debug_state() -> Dictionary:
	var dynamic_neurons: Array = []
	for neuron in neurons:
		if neuron["category"] != "":
			dynamic_neurons.append({
				"id": neuron["id"],
				"label": neuron["label"],
				"activation": neuron["activation"],
				"category": neuron["category"],
				"age": neuron["age"],
			})
	return {
		"neuron_count": neurons.size(),
		"connection_count": connections.size(),
		"dynamic_count": _dynamic_count,
		"stress_count": stress_count,
		"novelty_count": novelty_count,
		"reward_count": reward_count,
		"last_event": last_neurogenesis_event,
		"dynamic_neurons": dynamic_neurons,
		"stress_timer": sustained_stress_timer,
		"novelty_timer": novelty_exposure_timer,
	}
