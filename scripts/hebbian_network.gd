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
var recent_reward_signal: float = 0.0  # accumulator in [0, 1]; decays per propagate()
var _recent_reward_events: Array = []   # drained by snapshot for trace v2
var _reward_consts_cache: Dictionary = {}  # lazy from PerceptionConstants

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

# Appraisal neurogenesis state — quality-constellation spawn (perception_spec §3.5,
# appraisal_layer_spec §5). Constants lazy-loaded from PerceptionConstants on
# first check (see _appraisal_consts()). Defaults match spec values.
var _appraisal_count: int = 0
var _appraisal_constellations: Dictionary = {}  # "id1,id2,id3" -> {sustained_seconds, quality_ids, last_tick}
var _appraisal_consts_cache: Dictionary = {}    # lazy-loaded from PerceptionConstants
var _new_appraisal_neurons: Array = []          # drained by snapshot for Python-side embedding init
var _last_appraisal_check_tick: int = 0         # for internal dt computation

# Phase 2 — per-entity sensory neurogenesis (perception_spec §5.2 prep work,
# spec'd in perception_implementation_plan.md Phase 2). The network keeps a
# tracker per entity_id (canonical UUID per F9, not display name); first
# encounter spawns a sense_visible_{entity_id} neuron, subsequent encounters
# re-activate it. Neurons GC'd after tracker_expiry_ticks of non-firing.
var _per_entity_trackers: Dictionary = {}       # entity_id -> {last_fire_tick, encounter_count}
var _per_entity_consts_cache: Dictionary = {}   # lazy from PerceptionConstants

# Phase 9 — cross-modal binding neurogenesis (spec §5.4).
# Per-eid history of same-tick visible+heard co-activations. When enough
# co-fire events accumulate within the cross_modal_window_seconds, a compound
# `bind_{entity_id}` neuron spawns wired to both modality channels.
var _cross_modal_co_fires: Dictionary = {}     # entity_id -> Array[tick_msec]
var _bind_spawned_eids: Dictionary = {}        # entity_id -> true (dedup)
var _new_bind_neurons: Array = []              # drained by snapshot for trace v2

# Phase 10 — temporal-texture neurogenesis (spec §5.5).
# Tracks per-eid sustained-above-threshold elapsed time on sense_visible_{eid}
# dwell (→ lingering) and sense_dist_{eid} rate (→ approaching_fast). When
# elapsed ≥ temporal_persistence_seconds, spawn the corresponding compound.
# The state is {eid -> {"lingering_secs": float, "approaching_secs": float,
# "last_tick": int}}; ticks below threshold reset the counter to 0.
var _temporal_tracker: Dictionary = {}
var _temporal_spawned: Dictionary = {}          # "{kind}:{eid}" -> true (dedup)
var _new_temporal_textures: Array = []          # drain for trace v2

# Phase 4 — distance × action-success compound emergence (spec §5.1).
# - signal_action_success(verb, target_eid) emits a transient "action_success_{verb}"
#   neuron at activation 50; it decays over ACTION_SUCCESS_DECAY_SECONDS.
# - The same call records the at-success distance in _action_success_history.
# - Once a verb accumulates N samples (distance_action_co_fire_count) within
#   distance_action_window_seconds at a stable distance band, q_{verb}able
#   spawns with a receptive field = mean ± std of recorded distances.
# - q_{verb}able is activated per-tick by sampling all visible sense_dist_*
#   and applying a gaussian over (current_dist - center).
const ACTION_SUCCESS_DECAY_SECONDS: float = 2.0
const ACTION_SUCCESS_INIT_ACTIVATION: float = 50.0
var _action_success_history: Dictionary = {}    # verb -> Array of {distance, ts, target_eid}
var _qable_neurons: Dictionary = {}             # verb -> {center, sigma, success_count}
var _action_success_consts_cache: Dictionary = {}

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
	# Decay the reward gate every tick so it fades within decay_seconds even
	# if no consumer (neurogenesis, etc.) explicitly resets it.
	decay_reward(delta)
	# Phase 4: action_success_* neurons drop linearly over 2s. Standard
	# DECAY_PER_FRAME (~0.998) is too slow to give the spec's transient feel.
	_decay_action_success(delta)

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

		# Reward-gating modifier per spec §2.4. recent_reward_signal accumulates
		# from signal_reward() and decays via decay_reward() called per tick.
		# β = 0.5 default → signal=1.0 doubles updates, signal=0 leaves them.
		var beta: float = float(_reward_consts()["beta"])
		var reward_gate: float = 1.0 + beta * recent_reward_signal

		var delta_w: float = lr * (src_act / 100.0) * (dst_act / 100.0) * reward_gate
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

	# Reward-gating also applies to new spontaneous connections — what fired
	# together AND was followed by reward gets bound more strongly.
	var beta: float = float(_reward_consts()["beta"])
	var reward_gate: float = 1.0 + beta * recent_reward_signal

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
			var initial_w: float = lr * (a["activation"] / 100.0) * (b["activation"] / 100.0) * reward_gate
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

	# Priority: stress > novelty > reward > vagal > distance-action compound
	if _check_stress_neurogenesis():
		return
	if _check_novelty_neurogenesis():
		return
	if _check_reward_neurogenesis():
		return
	if _check_vagal_neurogenesis():
		return
	# Phase 4: distance-action compound. Doesn't count toward MAX_DYNAMIC
	# (it's a compound quality, capped separately by max_compound_quality).
	check_distance_action_neurogenesis()

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

func _reward_consts() -> Dictionary:
	## Lazy-load Tier-2 reward seeds from PerceptionConstants (autoload).
	## Falls back to spec defaults if the autoload isn't available (headless tests).
	if not _reward_consts_cache.is_empty():
		return _reward_consts_cache
	var pc: Node = null
	if Engine.has_singleton("PerceptionConstants"):
		pc = Engine.get_singleton("PerceptionConstants")
	else:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	var lookup := func(key: String, default_value: Variant) -> Variant:
		if pc == null:
			return default_value
		var v: Variant = pc.call("get_value", key, default_value)
		return v if v != null else default_value
	_reward_consts_cache = {
		"beta":          float(lookup.call("hebbian.beta", 0.5)),
		"decay_seconds": float(lookup.call("hebbian.reward_signal_decay_seconds", 2.0)),
	}
	return _reward_consts_cache

func signal_reward(source_tag: String = "generic", magnitude: float = 1.0) -> void:
	## Emit a reward event. Accumulates into recent_reward_signal (capped at 1.0)
	## which gates Hebbian weight updates per spec §2.4: Δw *= (1 + β · signal).
	## After firing, the signal decays via decay_reward(dt) called by propagate().
	##
	## source_tag: short tag from data/perception_constants.json:reward_magnitudes
	##   e.g. "reward_drive_satisfaction", "reward_action_succeeded"
	## magnitude: [0, 1] event strength
	var m: float = clampf(magnitude, 0.0, 1.0)
	recent_reward_signal = clampf(recent_reward_signal + m, 0.0, 1.0)
	_recent_reward_events.append({
		"tag": source_tag,
		"magnitude": m,
		"tick": Time.get_ticks_msec(),
	})

func decay_reward(dt_seconds: float) -> void:
	## Exponential decay of the reward gate. Called by propagate() each tick so
	## the gate's effect fades within reward_signal_decay_seconds even if no
	## explicit consumer (e.g. neurogenesis) zeroes the signal.
	if recent_reward_signal <= 0.0:
		return
	var consts: Dictionary = _reward_consts()
	var tau: float = float(consts["decay_seconds"])
	if tau <= 0.0:
		recent_reward_signal = 0.0
		return
	# Exponential half-life feel: signal halves every ~tau seconds.
	var k: float = exp(-dt_seconds / tau)
	recent_reward_signal *= k
	if recent_reward_signal < 1e-4:
		recent_reward_signal = 0.0

func drain_recent_reward_events() -> Array:
	## Pop reward events accumulated since last drain. Snapshot calls this once
	## per tick to forward to the trace_logger (trace v2 reward_events_this_tick).
	if _recent_reward_events.is_empty():
		return []
	var out: Array = _recent_reward_events.duplicate()
	_recent_reward_events.clear()
	return out

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
# APPRAISAL NEUROGENESIS — quality-constellation spawn
# (perception_spec.md §3.5, appraisal_layer_spec.md §5)
# =========================================================================

func _appraisal_consts() -> Dictionary:
	## Lazy-load Tier-2 seeds from PerceptionConstants (autoload singleton).
	## Falls back to spec-default values if the autoload isn't available
	## (e.g., when this RefCounted is used outside the engine main loop).
	if not _appraisal_consts_cache.is_empty():
		return _appraisal_consts_cache
	var pc: Node = null
	if Engine.has_singleton("PerceptionConstants"):
		pc = Engine.get_singleton("PerceptionConstants")
	else:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	var lookup := func(key: String, default_value: Variant) -> Variant:
		if pc == null:
			return default_value
		var v: Variant = pc.call("get_value", key, default_value)
		return v if v != null else default_value
	_appraisal_consts_cache = {
		"max":           int(lookup.call("capacity.max_appraisal_per_being", 12)),
		"min_size":      int(lookup.call("neurogenesis_thresholds.appraisal_constellation_min", 3)),
		"threshold":     float(lookup.call("neurogenesis_thresholds.appraisal_constellation_threshold", 50.0)),
		"sustained_sec": float(lookup.call("neurogenesis_thresholds.appraisal_constellation_sustained_seconds", 6.0)),
	}
	return _appraisal_consts_cache

func check_appraisal_neurogenesis() -> bool:
	## Spawn an appraisal neuron when 3+ quality neurons sustain co-activation
	## above threshold for `sustained_sec` continuous seconds.
	##
	## dt is computed internally from Time.get_ticks_msec() since the last
	## call. Returns true if a neuron was spawned this call.
	var now: int = Time.get_ticks_msec()
	var dt_seconds: float
	if _last_appraisal_check_tick == 0:
		dt_seconds = 0.0
	else:
		dt_seconds = (now - _last_appraisal_check_tick) / 1000.0
	_last_appraisal_check_tick = now
	# Clamp dt to a reasonable range — long pauses (debugger, breakpoints)
	# shouldn't accumulate huge sustained-time swings.
	dt_seconds = clamp(dt_seconds, 0.0, 1.0)

	var consts: Dictionary = _appraisal_consts()
	if _appraisal_count >= int(consts["max"]):
		return false

	var min_size: int = int(consts["min_size"])
	var threshold: float = float(consts["threshold"])
	var sustained_required: float = float(consts["sustained_sec"])

	# Find all quality neurons above the appraisal threshold (higher than
	# QUALITY_EMIT_THRESHOLD — appraisals fire on stronger sustained patterns).
	var active_qualities: Array = []
	for neuron in neurons:
		if neuron["type"] == "quality" and neuron["activation"] >= threshold:
			active_qualities.append(neuron["id"])

	if active_qualities.size() < min_size:
		# Constellation broke; let trackers age out (handled below).
		_decay_appraisal_constellations(dt_seconds)
		return false

	active_qualities.sort()
	var key: String = ",".join(active_qualities)

	if not _appraisal_constellations.has(key):
		_appraisal_constellations[key] = {
			"sustained_seconds": 0.0,
			"quality_ids": active_qualities.duplicate(),
			"last_tick": now,
		}
	var entry: Dictionary = _appraisal_constellations[key]
	entry["sustained_seconds"] = float(entry["sustained_seconds"]) + dt_seconds
	entry["last_tick"] = now

	# Other constellations not currently active decay (lose accumulated time)
	# to prevent stale partial constellations from accumulating across long gaps.
	_decay_appraisal_constellations(dt_seconds, key)

	if float(entry["sustained_seconds"]) >= sustained_required:
		_spawn_appraisal_neuron(active_qualities)
		_appraisal_constellations.erase(key)
		return true

	return false

func _decay_appraisal_constellations(dt_seconds: float, except_key: String = "") -> void:
	## Constellations that didn't fire this tick lose accumulated sustained-time
	## at the same rate, so a constellation must fire CONTINUOUSLY (or near-so)
	## for the full window to spawn — not intermittently across many disjoint
	## periods.
	var to_erase: Array = []
	for key in _appraisal_constellations.keys():
		if key == except_key:
			continue
		var e: Dictionary = _appraisal_constellations[key]
		e["sustained_seconds"] = float(e["sustained_seconds"]) - dt_seconds
		if float(e["sustained_seconds"]) <= 0.0:
			to_erase.append(key)
	for k in to_erase:
		_appraisal_constellations.erase(k)

func _spawn_appraisal_neuron(quality_ids: Array) -> void:
	## Create a new appraisal neuron from a quality constellation.
	##
	## - Activation seeded at 40 (active enough to participate immediately).
	## - Incoming connections from each parent quality at weight 0.12.
	## - Outgoing connections develop via Hebbian learning over time.
	## - embedding_seed = {tag_text: activation} of each parent — Python-side
	##   AppraisalEmbeddingManager uses these to compute the initial embedding
	##   as a weighted mean of concept embeddings.
	## - Pushed onto _new_appraisal_neurons; snapshot drains and forwards to
	##   Python so the embedding manager can initialize this neuron's vector.
	if quality_ids.is_empty():
		return

	var neuron_id: String = "appr_%d" % _next_id
	_next_id += 1

	# Build embedding_seed from parent quality tag_texts (the words like
	# "tight", "pounding", "prickling") weighted by current activation. These
	# are the concepts whose embeddings get weighted-mean'd to form the
	# appraisal neuron's initial vector in LLM space.
	var embedding_seed: Dictionary = {}
	var parent_label_parts: Array = []
	for qid in quality_ids:
		var qn: Dictionary = _neuron_map.get(qid, {})
		if qn.is_empty():
			continue
		var tag: String = qn.get("tag_text", "")
		if tag == "":
			continue
		embedding_seed[tag] = float(qn.get("activation", 0.0))
		parent_label_parts.append(tag)

	if embedding_seed.is_empty():
		return

	var label: String = "appraisal(%s)" % "+".join(parent_label_parts)
	var neuron: Dictionary = {
		"id": neuron_id,
		"type": "appraisal",
		"activation": 40.0,
		"protected": false,
		"category": "appraisal",
		"age": 0,
		"label": label,
		"parent_qualities": quality_ids.duplicate(),
		"embedding_seed": embedding_seed,
		"co_activation_count": 0,
	}
	neurons.append(neuron)
	_neuron_map[neuron_id] = neuron

	# Wire incoming from each parent quality.
	for qid in quality_ids:
		if _neuron_map.has(qid):
			_add_connection(qid, neuron_id, 0.12)

	_appraisal_count += 1
	_dynamic_count += 1

	# Publish for the Python-side handshake. Snapshot drains this list each tick.
	_new_appraisal_neurons.append({
		"id": neuron_id,
		"label": label,
		"embedding_seed": embedding_seed,
		"parent_qualities": quality_ids.duplicate(),
		"spawned_tick": Time.get_ticks_msec(),
	})

	last_neurogenesis_event = {
		"type": "appraisal",
		"context": label,
		"parents": quality_ids.duplicate(),
		"embedding_seed": embedding_seed,
		"tick": Time.get_ticks_msec(),
	}

func spawn_identity_appraisal(neuron_id: String, entity_id: String) -> bool:
	## Phase 5 — spawn an identity-appraisal for one entity_id. Python owns the
	## embedding state (mean of encounter-thought-embeddings in the
	## AppraisalEmbeddingManager); GDScript only wires the Hebbian node.
	##
	## Per docs/perception_implementation_plan.md §Phase 5:
	##   - Hebbian wiring: appr_identity_{entity_id} ← from sense_visible_{entity_id}
	##     + active somatic streams during spawn.
	##   - Outgoing to action / vagal develops via Hebbian learning — not authored.
	##
	## Incoming weight 0.12 mirrors the existing appraisal-from-quality parent
	## convention in _spawn_appraisal_neuron (kept as one rule, not a new knob).
	## "Active somatic stream" at spawn time = quality-type neurons with
	## activation ≥ 30 (same threshold get_active_appraisal_activations uses
	## for "currently firing"; no new tunable). Returns true on spawn, false
	## if the neuron already exists or the sense_visible prerequisite is missing.
	if neuron_id == "" or entity_id == "":
		return false
	if _neuron_map.has(neuron_id):
		return false

	var sense_visible_id: String = "sense_visible_" + entity_id
	if not _neuron_map.has(sense_visible_id):
		# The spawn request arrived before the per-entity sense neuron exists.
		# Refuse silently; a subsequent visibility tick will create the sense
		# neuron and the next thought-cycle spawn attempt will land.
		return false

	var neuron: Dictionary = {
		"id": neuron_id,
		"type": "appraisal",
		"activation": 40.0,
		"protected": false,
		"category": "identity_appraisal",
		"age": 0,
		"label": "identity(%s)" % entity_id,
		"entity_id": entity_id,
		"parent_qualities": [],
		"embedding_seed": {},  # Python-owned for identity appraisals
		"co_activation_count": 0,
	}
	neurons.append(neuron)
	_neuron_map[neuron_id] = neuron

	# Incoming: sense_visible_{eid}.
	_add_connection(sense_visible_id, neuron_id, 0.12)

	# Incoming: every active somatic (type=quality) neuron at spawn time.
	# Use the same activation floor (30) the cortical-feedback path uses to
	# decide which appraisals are "active" — keeps the semantics of "active"
	# consistent across the substrate.
	var wired_somatic: int = 0
	for n in neurons:
		if n.get("type", "") != "quality":
			continue
		if float(n.get("activation", 0.0)) < 30.0:
			continue
		if n.get("id", "") == neuron_id:
			continue
		_add_connection(String(n["id"]), neuron_id, 0.12)
		wired_somatic += 1

	_appraisal_count += 1
	_dynamic_count += 1

	last_neurogenesis_event = {
		"type": "identity_appraisal",
		"context": entity_id,
		"tick": Time.get_ticks_msec(),
		"somatic_parents": wired_somatic,
	}
	return true

func drain_new_appraisal_neurons() -> Array:
	## Pop all appraisal neurons spawned since the last drain. Called by the
	## per-tick snapshot builder; the returned list goes to Python so the
	## AppraisalEmbeddingManager can initialize() each one before drift starts.
	if _new_appraisal_neurons.is_empty():
		return []
	var out: Array = _new_appraisal_neurons.duplicate()
	_new_appraisal_neurons.clear()
	return out

# =========================================================================
# PER-ENTITY SENSORY NEUROGENESIS — Phase 2
# (perception_implementation_plan.md Phase 2; F9 entity_id_protocol.md)
# =========================================================================

func _per_entity_consts() -> Dictionary:
	if not _per_entity_consts_cache.is_empty():
		return _per_entity_consts_cache
	var pc: Node = null
	if Engine.has_singleton("PerceptionConstants"):
		pc = Engine.get_singleton("PerceptionConstants")
	else:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	var lookup := func(key: String, default_value: Variant) -> Variant:
		if pc == null:
			return default_value
		var v: Variant = pc.call("get_value", key, default_value)
		return v if v != null else default_value
	_per_entity_consts_cache = {
		"tracker_expiry_ticks": int(lookup.call("sensors.tracker_expiry_ticks", 600)),
		"distance_tau_tiles":   float(lookup.call("sensors.distance_tau_tiles", 4.0)),
		# α for the dwell EMA. Smaller = slower-rising / longer-memory dwell.
		# 0.05 ≈ "remembers ~20 ticks of history"; tunable per future need.
		"dwell_ema_alpha":      float(lookup.call("sensors.dwell_ema_alpha", 0.05)),
	}
	return _per_entity_consts_cache

func update_per_entity_sensory(visible_entities: Array) -> void:
	## Called every brain tick with the current list of visible entities/objects.
	## Each entry must carry:
	##   - id:              canonical entity_id (F9), e.g. "ent_a3f2…"
	##   - exposure:        [0, 1] — drives sense_visible activation
	##   - distance_tiles:  optional float; drives sense_dist activation
	##                      (falls back to 0 if absent)
	##
	## Per Phase 3 of perception_implementation_plan.md:
	##   - sense_visible_{eid}: activation = exposure * 100
	##   - sense_dist_{eid}:    activation = 100 * exp(-dist_tiles / TAU)
	## Each per-entity neuron also tracks rate (Δ activation / tick) and dwell
	## (exponential moving average) as fields on the neuron dict; these channels
	## are queryable via get_per_entity_channels() and feed Phase 4 compound
	## neurogenesis.
	##
	## Out-of-vision per-entity neurons decay naturally via propagate(); the
	## tracker is not refreshed, so eventually gc_per_entity_sensory drops them.
	var now: int = Time.get_ticks_msec()
	var consts: Dictionary = _per_entity_consts()
	var tau: float = float(consts["distance_tau_tiles"])
	var dwell_alpha: float = float(consts["dwell_ema_alpha"])

	for entity in visible_entities:
		var eid: String = str(entity.get("id", ""))
		if eid == "":
			continue
		var exposure: float = float(entity.get("exposure", 0.0))
		var dist_tiles: float = float(entity.get("distance_tiles", 0.0))
		var visible_act: float = clampf(exposure * 100.0, 0.0, 100.0)
		var dist_act: float = 100.0 * exp(-max(0.0, dist_tiles) / max(tau, 1e-6))
		dist_act = clampf(dist_act, 0.0, 100.0)

		_upsert_per_entity_neuron("sense_visible_" + eid, eid, "sees(%s)" % eid,
			visible_act, dwell_alpha)
		_upsert_per_entity_neuron("sense_dist_" + eid, eid, "near(%s)" % eid,
			dist_act, dwell_alpha)

		var tr: Dictionary = _per_entity_trackers.get(eid, {})
		if tr.is_empty():
			tr = {
				"last_fire_tick": now,
				"encounter_count": 1,
				"first_seen_tick": now,
			}
			last_neurogenesis_event = {
				"type": "per_entity_sensory",
				"context": eid,
				"tick": now,
			}
		else:
			tr["last_fire_tick"] = now
			tr["encounter_count"] = int(tr.get("encounter_count", 0)) + 1
		_per_entity_trackers[eid] = tr

func _upsert_per_entity_neuron(neuron_id: String, eid: String, label: String,
		new_activation: float, dwell_alpha: float) -> void:
	## Spawn or refresh a per-entity neuron, updating its rate/dwell channels.
	if not _neuron_map.has(neuron_id):
		var neuron: Dictionary = {
			"id": neuron_id,
			"type": "sensory",
			"activation": new_activation,
			"protected": true,
			"learnable_outgoing": true,
			"category": "per_entity_sensory",
			"age": 0,
			"label": label,
			"entity_id": eid,
			# Phase 3 channels.
			"prev_activation": new_activation,
			"rate": 0.0,
			"dwell": new_activation,
		}
		neurons.append(neuron)
		_neuron_map[neuron_id] = neuron
		return
	var n: Dictionary = _neuron_map[neuron_id]
	var prev: float = float(n.get("activation", 0.0))
	n["prev_activation"] = prev
	n["activation"] = new_activation
	n["rate"] = new_activation - prev
	# Exponential moving average: dwell ← (1-α)·dwell + α·activation
	n["dwell"] = (1.0 - dwell_alpha) * float(n.get("dwell", new_activation)) + dwell_alpha * new_activation

func get_per_entity_channels() -> Dictionary:
	## Return per-entity channel values for snapshot/trace recording.
	## Shape: {entity_id: {visible, dist, rate_visible, rate_dist, dwell_visible, dwell_dist}}
	## Channels for entities currently in the per-entity registry only.
	var out: Dictionary = {}
	for eid in _per_entity_trackers.keys():
		var v_id: String = "sense_visible_" + eid
		var d_id: String = "sense_dist_" + eid
		var v: Dictionary = _neuron_map.get(v_id, {})
		var d: Dictionary = _neuron_map.get(d_id, {})
		if v.is_empty() and d.is_empty():
			continue
		out[eid] = {
			"visible":       float(v.get("activation", 0.0)),
			"dist":          float(d.get("activation", 0.0)),
			"rate_visible":  float(v.get("rate", 0.0)),
			"rate_dist":     float(d.get("rate", 0.0)),
			"dwell_visible": float(v.get("dwell", 0.0)),
			"dwell_dist":    float(d.get("dwell", 0.0)),
		}
	return out

func gc_per_entity_sensory() -> int:
	## Remove sense_visible_{entity_id} neurons whose tracker hasn't fired
	## within tracker_expiry_ticks. Returns count removed.
	## Call at the same cadence as other neurogenesis checks (~every 2s).
	var consts: Dictionary = _per_entity_consts()
	var expiry_ms: int = int(consts["tracker_expiry_ticks"]) * 16  # ~16ms/frame at 60Hz
	var now: int = Time.get_ticks_msec()
	var removed: int = 0
	var to_drop: Array = []
	for eid in _per_entity_trackers.keys():
		var tr: Dictionary = _per_entity_trackers[eid]
		if now - int(tr.get("last_fire_tick", 0)) > expiry_ms:
			to_drop.append(eid)
	for eid in to_drop:
		# Phase 3: each entity has multiple per-entity neuron families
		# (sense_visible_*, sense_dist_*); GC them all together.
		var neuron_ids: Array = ["sense_visible_" + eid, "sense_dist_" + eid]
		for neuron_id in neuron_ids:
			if not _neuron_map.has(neuron_id):
				continue
			neurons = neurons.filter(func(n: Dictionary) -> bool: return n["id"] != neuron_id)
			_neuron_map.erase(neuron_id)
			connections = connections.filter(func(c: Dictionary) -> bool:
				return c["src"] != neuron_id and c["dst"] != neuron_id
			)
			removed += 1
		_per_entity_trackers.erase(eid)
	return removed

# =========================================================================
# F9 MERGE PROTOCOL — entity_id reconciliation
# (data/entity_id_protocol.md)
# =========================================================================

func merge_entity_ids(canonical_id: String, deprecated_id: String) -> bool:
	## Reconcile two entity_id neuron families when they refer to the same
	## real entity (e.g. initial misidentification, save migration). Per F9:
	## activation = max, weights = sum, tracker = combined. Handles every
	## per-entity neuron family registered in PER_ENTITY_PREFIXES.
	##
	## For the common case (stranger → name-bind), no merge is needed because
	## neurons are keyed on the immutable entity_id, not display name. This
	## function exists for the genuine same-entity-two-ids case.
	if canonical_id == "" or deprecated_id == "" or canonical_id == deprecated_id:
		return false
	var any_merge: bool = false

	# Every per-entity prefix that participates in the merge. Add new ones here
	# as future phases introduce more per-entity neuron families.
	const PER_ENTITY_PREFIXES: Array = [
		"sense_visible_", "sense_dist_", "appr_identity_",
		"sense_heard_", "bind_",                            # Phase 9 cross-modal
		"q_lingering_", "q_approaching_fast_",              # Phase 10 temporal
	]
	for prefix in PER_ENTITY_PREFIXES:
		if _merge_per_entity_neuron(prefix, canonical_id, deprecated_id):
			any_merge = true

	# Tracker merge.
	if _per_entity_trackers.has(deprecated_id):
		var dep_tr: Dictionary = _per_entity_trackers[deprecated_id]
		var canon_tr: Dictionary = _per_entity_trackers.get(canonical_id, {})
		var combined: Dictionary = {
			"last_fire_tick": max(
				int(canon_tr.get("last_fire_tick", 0)),
				int(dep_tr.get("last_fire_tick", 0))
			),
			"encounter_count": int(canon_tr.get("encounter_count", 0)) + int(dep_tr.get("encounter_count", 0)),
			"first_seen_tick": min(
				int(canon_tr.get("first_seen_tick", dep_tr.get("first_seen_tick", 0))),
				int(dep_tr.get("first_seen_tick", canon_tr.get("first_seen_tick", 0)))
			),
		}
		_per_entity_trackers[canonical_id] = combined
		_per_entity_trackers.erase(deprecated_id)
		any_merge = true

	return any_merge

func _merge_per_entity_neuron(prefix: String, canonical_id: String, deprecated_id: String) -> bool:
	## Merge one per-entity neuron family ({prefix}{deprecated_id}) into its
	## canonical counterpart. Activation=max, weights=sum, then drop deprecated.
	var canon_id: String = prefix + canonical_id
	var dep_id: String = prefix + deprecated_id
	if not _neuron_map.has(dep_id):
		return false
	if _neuron_map.has(canon_id):
		_neuron_map[canon_id]["activation"] = max(
			float(_neuron_map[canon_id]["activation"]),
			float(_neuron_map[dep_id]["activation"])
		)
		for c in connections:
			if c["src"] == dep_id:
				var existing: int = _find_connection(canon_id, c["dst"])
				if existing >= 0:
					connections[existing]["weight"] = clampf(
						float(connections[existing]["weight"]) + float(c["weight"]),
						-1.0, 1.0
					)
				else:
					_add_connection(canon_id, c["dst"], float(c["weight"]))
			elif c["dst"] == dep_id:
				var existing2: int = _find_connection(c["src"], canon_id)
				if existing2 >= 0:
					connections[existing2]["weight"] = clampf(
						float(connections[existing2]["weight"]) + float(c["weight"]),
						-1.0, 1.0
					)
				else:
					_add_connection(c["src"], canon_id, float(c["weight"]))
	else:
		# No canonical exists; rename deprecated in place.
		_neuron_map[dep_id]["id"] = canon_id
		_neuron_map[dep_id]["entity_id"] = canonical_id
		_neuron_map[canon_id] = _neuron_map[dep_id]
		for c in connections:
			if c["src"] == dep_id:
				c["src"] = canon_id
			if c["dst"] == dep_id:
				c["dst"] = canon_id
	neurons = neurons.filter(func(n: Dictionary) -> bool: return n["id"] != dep_id)
	_neuron_map.erase(dep_id)
	connections = connections.filter(func(c: Dictionary) -> bool:
		return c["src"] != dep_id and c["dst"] != dep_id
	)
	return true

func _find_connection(src: String, dst: String) -> int:
	for i in range(connections.size()):
		if connections[i]["src"] == src and connections[i]["dst"] == dst:
			return i
	return -1

# =========================================================================
# PHASE 4 — DISTANCE × ACTION-SUCCESS COMPOUND EMERGENCE (spec §5.1)
# =========================================================================

func _action_success_consts() -> Dictionary:
	if not _action_success_consts_cache.is_empty():
		return _action_success_consts_cache
	var pc: Node = null
	if Engine.has_singleton("PerceptionConstants"):
		pc = Engine.get_singleton("PerceptionConstants")
	else:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	var lookup := func(key: String, default_value: Variant) -> Variant:
		if pc == null:
			return default_value
		var v: Variant = pc.call("get_value", key, default_value)
		return v if v != null else default_value
	_action_success_consts_cache = {
		"co_fire_count":   int(lookup.call("neurogenesis_thresholds.distance_action_co_fire_count", 10)),
		"window_seconds":  float(lookup.call("neurogenesis_thresholds.distance_action_window_seconds", 60.0)),
		"max_compound":    int(lookup.call("capacity.max_compound_quality", 16)),
	}
	return _action_success_consts_cache

func signal_action_success(verb: String, target_eid: String = "") -> void:
	## Engine-side hook: emits a transient action_success_{verb} signal at
	## activation 50. The signal decays over ACTION_SUCCESS_DECAY_SECONDS via
	## propagate(). If target_eid is provided AND a sense_dist_{eid} exists,
	## the at-success distance is recorded for distance-action neurogenesis.
	if verb == "":
		return
	var v: String = verb.to_lower()
	var neuron_id: String = "action_success_" + v
	if not _neuron_map.has(neuron_id):
		var neuron: Dictionary = {
			"id": neuron_id,
			"type": "sensory",
			"activation": ACTION_SUCCESS_INIT_ACTIVATION,
			"protected": true,
			"learnable_outgoing": true,
			"category": "action_success",
			"age": 0,
			"label": "success(%s)" % v,
			"verb": v,
		}
		neurons.append(neuron)
		_neuron_map[neuron_id] = neuron
	else:
		# Latest pulse wins (don't accumulate above 50 — substrate-level cap).
		_neuron_map[neuron_id]["activation"] = max(
			float(_neuron_map[neuron_id]["activation"]),
			ACTION_SUCCESS_INIT_ACTIVATION
		)

	# Record at-success distance for compound neurogenesis.
	if target_eid != "":
		var dist_neuron: Dictionary = _neuron_map.get("sense_dist_" + target_eid, {})
		if not dist_neuron.is_empty():
			var dist_act: float = float(dist_neuron.get("activation", 0.0))
			# Activation = 100·exp(-d/τ), so d = -τ·ln(act/100). Recover the tile
			# distance from the activation we observed at success.
			var tau: float = float(_per_entity_consts().get("distance_tau_tiles", 4.0))
			var dist_tiles: float = -tau * log(max(dist_act, 1e-3) / 100.0)
			var hist: Array = _action_success_history.get(v, [])
			hist.append({
				"distance_tiles": dist_tiles,
				"ts": Time.get_ticks_msec(),
				"target_eid": target_eid,
			})
			_action_success_history[v] = hist

func _decay_action_success(dt_seconds: float) -> void:
	## Linear decay: action_success_* neurons drop from 50 → 0 over
	## ACTION_SUCCESS_DECAY_SECONDS. Called from propagate() each tick.
	if _neuron_map.is_empty():
		return
	var drop: float = (ACTION_SUCCESS_INIT_ACTIVATION / max(ACTION_SUCCESS_DECAY_SECONDS, 1e-3)) * dt_seconds
	for neuron in neurons:
		if neuron.get("category", "") == "action_success":
			neuron["activation"] = max(0.0, float(neuron["activation"]) - drop)

func check_distance_action_neurogenesis() -> bool:
	## Spec §5.1: when N action-success events for verb V cluster at a stable
	## distance band within window_seconds, spawn q_{verb}able with that band
	## as its receptive field. Called every neurogenesis cycle.
	var consts: Dictionary = _action_success_consts()
	var n_required: int = int(consts["co_fire_count"])
	var window_sec: float = float(consts["window_seconds"])
	var max_comp: int = int(consts["max_compound"])
	var now: int = Time.get_ticks_msec()
	var window_ms: int = int(window_sec * 1000.0)

	for verb in _action_success_history.keys():
		# Already have a q_{verb}able? Skip (one per verb for now).
		if _qable_neurons.has(verb):
			continue
		if _compound_quality_count >= max_comp:
			return false

		# Drop expired samples.
		var hist: Array = _action_success_history[verb]
		hist = hist.filter(func(h: Dictionary) -> bool:
			return now - int(h["ts"]) <= window_ms
		)
		_action_success_history[verb] = hist
		if hist.size() < n_required:
			continue

		# Compute receptive band statistics.
		var distances: Array = []
		for h in hist:
			distances.append(float(h["distance_tiles"]))
		var mean_d: float = 0.0
		for d in distances:
			mean_d += d
		mean_d /= distances.size()
		var var_sum: float = 0.0
		for d in distances:
			var_sum += (d - mean_d) * (d - mean_d)
		var std_d: float = sqrt(var_sum / distances.size())
		# Clamp σ to a useful range — too tight = brittle, too wide = useless.
		std_d = clampf(std_d, 0.5, 6.0)

		_spawn_qable_compound(verb, mean_d, std_d, distances.size())
		# Clear history once the compound exists.
		_action_success_history.erase(verb)
		return true
	return false

func _spawn_qable_compound(verb: String, center: float, sigma: float, sample_count: int) -> void:
	var compound_id: String = "q_%sable" % verb
	if _neuron_map.has(compound_id):
		return
	var neuron: Dictionary = {
		"id": compound_id,
		"type": "quality",
		"activation": 0.0,
		"protected": false,
		"category": "compound_quality_distance",
		"age": 0,
		"label": "%sable@%.1f±%.1f" % [verb, center, sigma],
		"tag_text": "%sable" % verb,
		"regions": ["body"],
		# Phase 4 receptive field — read by update_qable_activations().
		"verb": verb,
		"receptive_center": center,
		"receptive_sigma":  sigma,
		"success_count":    sample_count,
	}
	neurons.append(neuron)
	_neuron_map[compound_id] = neuron
	_qable_neurons[verb] = neuron

	# Wire incoming from all currently-known per-entity sense_dist neurons
	# (receptive activation overrides on tick; these wires let propagate also
	# carry contribution). New sense_dist neurons added later won't auto-wire,
	# but Phase 4's gaussian update reads them directly each tick anyway.
	for n in neurons:
		if n.get("category", "") == "per_entity_sensory" and n["id"].begins_with("sense_dist_"):
			_add_connection(n["id"], compound_id, 0.05)

	_compound_quality_count += 1
	last_neurogenesis_event = {
		"type": "compound_quality_distance",
		"context": compound_id,
		"verb": verb,
		"center": center,
		"sigma": sigma,
		"samples": sample_count,
		"tick": Time.get_ticks_msec(),
	}

func update_qable_activations() -> void:
	## Phase 4 receptive-field activation. For each q_{verb}able, sample all
	## visible sense_dist_* neurons and set activation = 100·exp(-((d-c)²)/(2σ²))
	## taken at its peak (closest to center). This makes the compound fire when
	## an entity is currently at the empirically-successful distance for the verb.
	if _qable_neurons.is_empty():
		return
	var tau: float = float(_per_entity_consts().get("distance_tau_tiles", 4.0))
	# Pre-compute the current distance (in tiles) for each visible entity.
	var visible_distances: Array = []
	for n in neurons:
		if n.get("category", "") == "per_entity_sensory" and n["id"].begins_with("sense_dist_"):
			var act: float = float(n.get("activation", 0.0))
			if act < 1.0:
				continue  # not really visible
			var d: float = -tau * log(max(act, 1e-3) / 100.0)
			visible_distances.append(d)

	for verb in _qable_neurons.keys():
		var qn: Dictionary = _qable_neurons[verb]
		var c: float = float(qn["receptive_center"])
		var sigma: float = max(float(qn["receptive_sigma"]), 0.5)
		var best: float = 0.0
		for d in visible_distances:
			var x: float = (d - c) / sigma
			var act: float = 100.0 * exp(-0.5 * x * x)
			if act > best:
				best = act
		qn["activation"] = best

func get_active_appraisal_activations() -> Dictionary:
	## Return {appraisal_id: activation} for appraisal neurons above 30.
	## Used by the cortical-feedback loop to know which appraisals to drift.
	var out: Dictionary = {}
	for neuron in neurons:
		if neuron["type"] == "appraisal" and float(neuron["activation"]) >= 30.0:
			out[neuron["id"]] = float(neuron["activation"])
	return out

# =========================================================================
# PHASE 9 — CROSS-MODAL BINDING
# (perception_implementation_plan.md Phase 9, perception_spec.md §5.4)
# =========================================================================

func update_per_entity_heard(heard_entities: Array) -> void:
	## Called each brain tick with the set of eids the being heard this tick.
	## Each entry: { id: entity_id, strength: 0..1 (e.g. perceived_volume) }.
	## Spawns/refreshes sense_heard_{eid}; if sense_visible_{eid} is also
	## firing above 30 this same tick, logs a co-activation for the cross-
	## modal binding neurogenesis rule.
	##
	## Unlike sense_visible_, there is no GC schedule tied to a tracker — the
	## neuron decays naturally via propagate() when no new heard events arrive.
	## The binding-coactivation history is time-windowed on its own.
	if heard_entities.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	var window_ms: int = int(float(_cross_modal_consts().get("cross_modal_window_seconds", 30.0)) * 1000.0)
	var cfire_count: int = int(_cross_modal_consts().get("cross_modal_co_fire_count", 5))
	var dwell_alpha: float = float(_per_entity_consts().get("dwell_ema_alpha", 0.05))

	for entry in heard_entities:
		var eid: String = str(entry.get("id", ""))
		if eid == "":
			continue
		var strength: float = clampf(float(entry.get("strength", 0.0)), 0.0, 1.0)
		var heard_act: float = strength * 100.0
		_upsert_per_entity_neuron("sense_heard_" + eid, eid, "hears(%s)" % eid,
			heard_act, dwell_alpha)

		# Co-activation check. sense_visible_ must be present AND active above
		# the 30 "active" floor used consistently throughout the substrate.
		var visible_id: String = "sense_visible_" + eid
		if _neuron_map.has(visible_id) and float(_neuron_map[visible_id].get("activation", 0.0)) >= 30.0 \
				and heard_act >= 30.0:
			var history: Array = _cross_modal_co_fires.get(eid, [])
			history.append(now)
			# Prune outside the window.
			var cutoff: int = now - window_ms
			while history.size() > 0 and int(history[0]) < cutoff:
				history.pop_front()
			_cross_modal_co_fires[eid] = history
			if history.size() >= cfire_count and not _bind_spawned_eids.get(eid, false):
				_spawn_cross_modal_binding(eid)

func _cross_modal_consts() -> Dictionary:
	## Small lazy accessor for the two constants this phase uses. Reuses the
	## neurogenesis_thresholds block that the plan already populates.
	var pc: Node = null
	if Engine.has_singleton("PerceptionConstants"):
		pc = Engine.get_singleton("PerceptionConstants")
	else:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	var lookup := func(key: String, default_value: Variant) -> Variant:
		if pc == null:
			return default_value
		var v: Variant = pc.call("get_value", key, default_value)
		return v if v != null else default_value
	return {
		"cross_modal_co_fire_count": int(lookup.call("neurogenesis_thresholds.cross_modal_co_fire_count", 5)),
		"cross_modal_window_seconds": float(lookup.call("neurogenesis_thresholds.cross_modal_window_seconds", 30.0)),
	}

func _spawn_cross_modal_binding(entity_id: String) -> void:
	## Spawn bind_{entity_id} compound neuron wired to both modality channels.
	## The compound counts toward `_compound_quality_count` so F4 fallback
	## decay treats it the same as Phase 4's q_*able compounds — a new
	## bind-compound is a new piece of substrate affordance.
	if entity_id == "":
		return
	var neuron_id: String = "bind_" + entity_id
	if _neuron_map.has(neuron_id):
		return
	var visible_id: String = "sense_visible_" + entity_id
	var heard_id: String = "sense_heard_" + entity_id
	if not (_neuron_map.has(visible_id) and _neuron_map.has(heard_id)):
		return

	var neuron: Dictionary = {
		"id": neuron_id,
		"type": "compound_quality",
		"activation": 40.0,
		"protected": false,
		"category": "compound_quality_cross_modal",
		"age": 0,
		"label": "bind(%s)" % entity_id,
		"entity_id": entity_id,
		"parent_visible": visible_id,
		"parent_heard": heard_id,
	}
	neurons.append(neuron)
	_neuron_map[neuron_id] = neuron

	# Incoming wiring from both modality sense-neurons. Weight 0.12 matches
	# the existing appraisal-parent + identity-appraisal-parent convention —
	# no new tuning constant; the Hebbian rule will refine them.
	_add_connection(visible_id, neuron_id, 0.12)
	_add_connection(heard_id, neuron_id, 0.12)

	_compound_quality_count += 1
	_dynamic_count += 1
	_bind_spawned_eids[entity_id] = true

	_new_bind_neurons.append({
		"id": neuron_id,
		"entity_id": entity_id,
		"spawned_tick": Time.get_ticks_msec(),
	})

	last_neurogenesis_event = {
		"type": "cross_modal_binding",
		"context": entity_id,
		"tick": Time.get_ticks_msec(),
	}

func drain_new_bind_neurons() -> Array:
	## Pop all bind_* neurons spawned since the last drain. Called by the
	## per-tick snapshot builder; mirrors drain_new_appraisal_neurons.
	if _new_bind_neurons.is_empty():
		return []
	var out: Array = _new_bind_neurons.duplicate()
	_new_bind_neurons.clear()
	return out

# =========================================================================
# PHASE 10 — TEMPORAL TEXTURE NEUROGENESIS
# (perception_implementation_plan.md Phase 10, perception_spec.md §5.5)
# =========================================================================

func _temporal_consts() -> Dictionary:
	## Lazy accessor for the three temporal-texture constants.
	var pc: Node = null
	if Engine.has_singleton("PerceptionConstants"):
		pc = Engine.get_singleton("PerceptionConstants")
	else:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			pc = tree.root.get_node_or_null("/root/PerceptionConstants")
	var lookup := func(key: String, default_value: Variant) -> Variant:
		if pc == null:
			return default_value
		var v: Variant = pc.call("get_value", key, default_value)
		return v if v != null else default_value
	return {
		"persistence_seconds": float(lookup.call("neurogenesis_thresholds.temporal_persistence_seconds", 8.0)),
		"dwell_min": float(lookup.call("neurogenesis_thresholds.temporal_dwell_min", 30.0)),
		"rate_min": float(lookup.call("neurogenesis_thresholds.temporal_rate_min", 0.5)),
	}

func update_temporal_textures(dt_seconds: float) -> void:
	## Called every brain tick. For every per-entity tracker eid still live,
	## inspect the parent sense neurons' dwell/rate channels. Each channel's
	## "sustained above threshold" elapsed time is a separate counter: when
	## the counter crosses `temporal_persistence_seconds`, the corresponding
	## compound spawns (once — dedup by "{kind}:{eid}").
	##
	## This rule is per-entity. Different eids accumulate independently; one
	## entity going briefly below threshold does NOT reset another's counter.
	## Partial sustaining (e.g. 3 seconds high, 0.5 s low, 3 seconds high)
	## resets the counter on the low tick — spec §5.5's "high for T seconds"
	## means continuous.
	var consts: Dictionary = _temporal_consts()
	var persistence: float = float(consts["persistence_seconds"])
	var dwell_min: float = float(consts["dwell_min"])
	var rate_min: float = float(consts["rate_min"])

	for eid in _per_entity_trackers.keys():
		var vis: Dictionary = _neuron_map.get("sense_visible_" + eid, {})
		var dst: Dictionary = _neuron_map.get("sense_dist_" + eid, {})
		if vis.is_empty() and dst.is_empty():
			continue
		var tr: Dictionary = _temporal_tracker.get(eid, {
			"lingering_secs": 0.0,
			"approaching_secs": 0.0,
		})

		# Lingering: sustained high dwell on the visibility channel.
		var dwell: float = float(vis.get("dwell", 0.0))
		if dwell >= dwell_min:
			tr["lingering_secs"] = float(tr.get("lingering_secs", 0.0)) + dt_seconds
		else:
			tr["lingering_secs"] = 0.0

		# Approaching fast: sustained high POSITIVE rate on the distance channel.
		# sense_dist activation = 100*exp(-d/τ) — it INCREASES as distance
		# decreases, so positive rate = getting closer. A positive magnitude
		# threshold avoids firing on micro-jitter (rate ~0 but technically > 0).
		var rate: float = float(dst.get("rate", 0.0))
		if rate >= rate_min:
			tr["approaching_secs"] = float(tr.get("approaching_secs", 0.0)) + dt_seconds
		else:
			tr["approaching_secs"] = 0.0

		_temporal_tracker[eid] = tr

		# Spawn checks — one per kind, dedup via _temporal_spawned keys.
		if float(tr["lingering_secs"]) >= persistence:
			_spawn_temporal_texture("lingering", eid, "sense_visible_" + eid)
		if float(tr["approaching_secs"]) >= persistence:
			_spawn_temporal_texture("approaching_fast", eid, "sense_dist_" + eid)

func _spawn_temporal_texture(kind: String, entity_id: String, parent_sense_id: String) -> void:
	## Spawn q_{kind}_{entity_id} compound wired to its parent sense-neuron.
	## `tag_text` carries the spec's decoded token ("lingering" / "approaching")
	## so Phase 7's renderer can pick it up as an inline token for the eid.
	if kind == "" or entity_id == "":
		return
	var neuron_id: String = "q_%s_%s" % [kind, entity_id]
	if _temporal_spawned.get("%s:%s" % [kind, entity_id], false):
		return
	if _neuron_map.has(neuron_id):
		_temporal_spawned["%s:%s" % [kind, entity_id]] = true
		return
	if not _neuron_map.has(parent_sense_id):
		# Parent was GC'd between tracker tick and spawn — bail; next encounter
		# will rebuild the counter.
		return

	var tag: String = kind  # "lingering" or "approaching_fast"
	var neuron: Dictionary = {
		"id": neuron_id,
		"type": "compound_quality",
		"activation": 40.0,
		"protected": false,
		"category": "compound_quality_temporal",
		"age": 0,
		"label": "%s(%s)" % [kind, entity_id],
		"entity_id": entity_id,
		"tag_text": tag,
		"temporal_kind": kind,
		"parent_sense": parent_sense_id,
	}
	neurons.append(neuron)
	_neuron_map[neuron_id] = neuron

	_add_connection(parent_sense_id, neuron_id, 0.12)

	_compound_quality_count += 1
	_dynamic_count += 1
	_temporal_spawned["%s:%s" % [kind, entity_id]] = true

	_new_temporal_textures.append({
		"id": neuron_id,
		"kind": kind,
		"entity_id": entity_id,
		"parent_sense": parent_sense_id,
		"spawned_tick": Time.get_ticks_msec(),
	})

	last_neurogenesis_event = {
		"type": "temporal_texture",
		"context": "%s(%s)" % [kind, entity_id],
		"tick": Time.get_ticks_msec(),
	}

func update_temporal_activations() -> void:
	## Per-tick activation refresh for temporal textures. A q_lingering_{eid}
	## fires in proportion to the parent sense_visible_{eid}'s current dwell;
	## a q_approaching_fast_{eid} fires in proportion to the parent
	## sense_dist_{eid}'s current rate (clamped positive). When the parent
	## channel fades (entity leaves / stops approaching), the compound's
	## activation correctly fades with it.
	for n in neurons:
		if String(n.get("category", "")) != "compound_quality_temporal":
			continue
		var parent_id: String = String(n.get("parent_sense", ""))
		if parent_id == "" or not _neuron_map.has(parent_id):
			n["activation"] = 0.0
			continue
		var parent: Dictionary = _neuron_map[parent_id]
		var kind: String = String(n.get("temporal_kind", ""))
		var new_act: float = 0.0
		if kind == "lingering":
			new_act = clampf(float(parent.get("dwell", 0.0)), 0.0, 100.0)
		elif kind == "approaching_fast":
			var rate: float = float(parent.get("rate", 0.0))
			# Map a modest positive rate (≥ rate_min) to a reportable activation.
			# 10x scaling centers typical approach rates (0.5..5 per tick) into
			# the 5..50 activation band where the "active" floor reads.
			new_act = clampf(maxf(0.0, rate) * 10.0, 0.0, 100.0)
		n["activation"] = new_act

func drain_new_temporal_textures() -> Array:
	## Drain recently-spawned temporal texture neurons for trace v2.
	if _new_temporal_textures.is_empty():
		return []
	var out: Array = _new_temporal_textures.duplicate()
	_new_temporal_textures.clear()
	return out

func get_active_temporal_textures(floor: float = 30.0) -> Dictionary:
	## {entity_id: {"lingering": act_or_0, "approaching_fast": act_or_0}}
	## for per-entity temporal compounds currently firing above `floor`. Used
	## by the Phase 7 renderer to inline "lingering" / "approaching" tokens
	## on the matching entity's prompt line.
	var out: Dictionary = {}
	for n in neurons:
		if String(n.get("category", "")) != "compound_quality_temporal":
			continue
		if float(n.get("activation", 0.0)) < floor:
			continue
		var eid: String = String(n.get("entity_id", ""))
		if eid == "":
			continue
		var kind: String = String(n.get("temporal_kind", ""))
		var entry: Dictionary = out.get(eid, {})
		entry[kind] = float(n["activation"])
		out[eid] = entry
	return out

func get_active_heard_activations(floor: float = 0.0) -> Dictionary:
	## Phase 9 — {eid: activation of sense_heard_{eid}} for the caller to
	## rank heard percepts alongside visible ones. Empty/undifferentiated
	## return at cold-start is correct (no heard neurons yet).
	var out: Dictionary = {}
	for n in neurons:
		var id: String = String(n.get("id", ""))
		if not id.begins_with("sense_heard_"):
			continue
		var act: float = float(n.get("activation", 0.0))
		if act < floor:
			continue
		out[id.substr("sense_heard_".length())] = act
	return out

func get_active_bind_activations(floor: float = 30.0) -> Dictionary:
	## {eid: activation} for currently-firing cross-modal bind compounds.
	## Used by trace recording and downstream diagnostics (§9.4 probes).
	var out: Dictionary = {}
	for n in neurons:
		if String(n.get("category", "")) != "compound_quality_cross_modal":
			continue
		if float(n.get("activation", 0.0)) < floor:
			continue
		out[String(n.get("entity_id", ""))] = float(n["activation"])
	return out

func get_active_compounds(activation_floor: float = 30.0) -> Dictionary:
	## Phase 7 — {compound_neuron_id: activation} for compound-quality neurons
	## above `activation_floor`. Covers both `compound_quality` (quality-pair
	## compounds, Phase 4's q_{a}+{b}) and `compound_quality_distance`
	## (q_{verb}able, the distance-action compounds that gate affordance verbs).
	##
	## The 30.0 floor matches the "active appraisal" convention used everywhere
	## else in the substrate — no new tuning constant.
	var out: Dictionary = {}
	for neuron in neurons:
		var cat: String = String(neuron.get("category", ""))
		if not (cat == "compound_quality" or cat == "compound_quality_distance"):
			continue
		var act: float = float(neuron.get("activation", 0.0))
		if act < activation_floor:
			continue
		out[String(neuron["id"])] = act
	return out

func get_compound_count() -> int:
	## Phase 7 F4 — number of compound-quality neurons currently in the graph
	## (regardless of activation). Drives the fallback-decay coefficient:
	## `max(0, 1 - count / N_FALLBACK_RETIRE)` retires the crude distance
	## fallback once enough compounds have emerged.
	return int(_compound_quality_count)

func get_outgoing_weight_sum(neuron_id: String) -> float:
	## Phase 6 — summed absolute outgoing propagation weight of a single neuron.
	##
	## Per docs/perception_spec.md §5.3 and docs/perception_implementation_plan.md
	## Phase 6: a percept's salience = "summed outgoing propagation weight of
	## their sense-neuron". Two beings with the same sensory field but different
	## reward histories will have different Hebbian weights, and therefore
	## different propagation sums on their per-entity sense neurons — this is
	## the mechanism by which attention individuates.
	##
	## Absolute value because a strongly-negative outgoing weight (inhibitory)
	## is still influence on downstream state; the being "pays attention" to
	## the percept either way. No new tuning constant, no new fixed weight —
	## every weight read here is Hebbian-learned from co-activation history.
	if neuron_id == "":
		return 0.0
	var s: float = 0.0
	for c in connections:
		if String(c["src"]) == neuron_id:
			s += absf(float(c["weight"]))
	return s

func get_perception_salience(entity_ids: Array) -> Dictionary:
	## Phase 6 — per-entity perception salience from sense_visible_{eid}
	## outgoing weight sums. Returns {eid: float}; eids with no matching sense
	## neuron (never encountered, or GC'd) map to 0.0.
	##
	## NOTE: keyed on sense_visible_{eid} alone. sense_dist_{eid} captures the
	## same entity at a different substrate level; its outgoing weights will
	## track visibility patterns closely. The spec's "sense_X" language reads
	## most naturally as the base visibility neuron, which also matches how
	## Phase 2's F9 merge protocol already treats the family.
	var out: Dictionary = {}
	for eid in entity_ids:
		var s: String = String(eid)
		if s == "":
			continue
		out[s] = get_outgoing_weight_sum("sense_visible_" + s)
	return out

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
