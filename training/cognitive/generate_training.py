#!/usr/bin/env python3
"""
Training data generator for cognitive processing model.
Generates JSONL training examples for think, infer, appraise, and speak modes.
Uses combinatorial variation across being types, drives, signals, and scenarios.
"""

import json
import random
import sys
from dataclasses import dataclass
from typing import Optional

random.seed(42)

SYSTEM_MSG = "You are a cognitive processing module for a simulated being. You receive the being's state and produce structured JSON responses. Never add commentary outside the JSON."

# ─── Being definitions ───────────────────────────────────────────────────────

@dataclass
class Being:
    name: str
    category: str  # human, animal, mythical
    locations: list
    activities: list
    thought_style: str  # full, terse, sparse
    can_speak: bool = True

BEINGS = [
    # Humans
    Being("innkeeper", "human", ["inn"],
          ["wiping the counter", "serving drinks", "sweeping the floor", "counting coins",
           "restocking shelves", "writing in a ledger", "preparing a room", "locking the door"],
          "full"),
    Being("guard", "human", ["guard_post", "gate", "town_square", "graveyard"],
          ["standing watch", "walking patrol", "sharpening sword", "checking papers",
           "leaning against the wall", "gripping weapon", "scanning the road"],
          "full"),
    Being("baker", "human", ["bakery", "market"],
          ["kneading dough", "pulling bread from the oven", "measuring flour", "decorating a cake",
           "setting out fresh bread", "cleaning the oven", "selling bread at the stall"],
          "full"),
    Being("farmer", "human", ["farm", "market"],
          ["tending crops", "pulling weeds", "feeding chickens", "mending the fence",
           "planting seeds", "loading produce", "checking the barn", "sitting on the porch"],
          "full"),
    Being("herbalist", "human", ["herbalist_shop", "forest"],
          ["sorting remedies", "grinding herbs", "brewing tea", "labeling jars",
           "examining a plant", "mixing a remedy", "reading notes", "gathering herbs"],
          "full"),
    Being("blacksmith", "human", ["blacksmith"],
          ["hammering at the forge", "examining a blade", "organizing tools", "cooling metal",
           "starting the forge", "tempering a blade", "testing a repair", "banking the fire"],
          "full"),
    Being("courier", "human", ["road", "town_square", "inn"],
          ["walking", "sitting down", "picking up a package", "reading a notice board",
           "eating a meal", "writing in a journal", "searching for an address"],
          "full"),
    Being("gossip", "human", ["market", "well", "town_square", "home", "inn"],
          ["chatting with neighbors", "drawing water", "looking around", "buying vegetables",
           "pacing", "looking out the window", "mending clothes", "shopping"],
          "full"),
    # Animals
    Being("wolf", "animal", ["forest"],
          ["prowling", "resting", "sniffing the air", "drinking from a stream",
           "grooming", "marking territory", "watching the pack sleep", "leading the pack"],
          "terse", can_speak=False),
    Being("dog", "animal", ["farm", "home", "town_square", "inn", "market"],
          ["lying in the sun", "sitting by the gate", "running in circles", "sniffing around",
           "lying by the door", "chasing tail", "watching sheep", "sitting near the kitchen"],
          "terse", can_speak=False),
    Being("cat", "animal", ["bakery", "inn", "home", "market", "herbalist_shop", "farm", "stable"],
          ["sitting on a windowsill", "sleeping on a chair", "grooming", "watching from the rafters",
           "skulking between stalls", "sitting on a fence post", "crouching under a bench"],
          "terse", can_speak=False),
    Being("horse", "animal", ["stable", "road", "farm"],
          ["standing idle", "pulling a cart", "grazing", "stamping feet",
           "being brushed", "eating oats", "being ridden"],
          "terse", can_speak=False),
    Being("crow", "animal", ["town_square", "farm", "forest", "market"],
          ["perched on a roof", "circling above", "sitting on a signpost", "perched in a tree",
           "calling to other crows", "watching from a fence post"],
          "terse", can_speak=False),
    Being("rat", "animal", ["inn", "market", "bakery", "stable"],
          ["hiding under a stall", "hiding in the wall", "sneaking toward the pantry",
           "nibbling on grain", "running through the walls", "building a nest"],
          "terse", can_speak=False),
    # Mythical
    Being("forest spirit", "mythical", ["forest"],
          ["drifting among the trees", "watching the treeline", "tending to a tree",
           "sensing vibrations in the roots", "resting in the canopy", "watching a clearing"],
          "sparse", can_speak=False),
    Being("stone golem", "mythical", ["gate"],
          ["standing guard", "scanning the perimeter", "blocking the entrance",
           "repairing the gate mechanism"],
          "sparse"),
    Being("ghost", "mythical", ["graveyard", "inn", "church", "home"],
          ["drifting among headstones", "hovering near the altar", "watching the living",
           "standing beside own grave", "drifting through the common room"],
          "sparse"),
    Being("water elemental", "mythical", ["well"],
          ["circling slowly", "flowing gently", "churning", "filtering sediment",
           "sensing vibrations in the water"],
          "sparse", can_speak=False),
]

LOCATIONS = ["inn", "bakery", "market", "farm", "guard_post", "blacksmith", "herbalist_shop",
             "town_square", "forest", "stable", "gate", "home", "road", "well", "church", "graveyard"]

EMOTIONS = ["calm", "content", "happy", "joyful", "excited", "eager", "hopeful", "proud",
            "satisfied", "grateful", "warm", "friendly", "amused", "curious", "focused",
            "determined", "resolute", "alert", "vigilant", "wary", "suspicious", "cautious",
            "nervous", "anxious", "afraid", "terrified", "panicked", "uneasy",
            "angry", "furious", "frustrated", "annoyed", "irritated", "indignant",
            "sad", "lonely", "melancholy", "grieving", "despairing", "mournful",
            "tired", "exhausted", "weary", "bored", "restless", "drained",
            "worried", "concerned", "alarmed", "desperate",
            "peaceful", "serene", "relaxed", "drowsy", "nostalgic", "reflective",
            "embarrassed", "ashamed", "guilty", "confused", "surprised",
            "neutral", "indifferent"]

# ─── Signal templates ────────────────────────────────────────────────────────

ENTITY_NAMES = ["Roland the Guard", "Marta the Baker", "Felix the Courier", "Ivy the Herbalist",
                "Thomas the Farmer", "Agnes", "Gertrude", "Henrich", "Edith",
                "a traveler", "a stranger", "a merchant", "a child", "an old woman",
                "a hooded figure", "a wounded man", "Player"]

ENTITY_TYPES_ANIMAL = ["deer", "rabbit", "mouse", "hawk", "bear", "stray cat", "stray dog"]

SIGNALS = {
    "nothing_notable": [
        "nothing_notable"
    ],
    "entity_appeared": [
        "entity_appeared — {entity}, {dist} tiles {direction}",
        "entity_appeared — {entity}, {dist} tiles {direction}, {behavior}",
    ],
    "entity_vanished": [
        "entity_vanished — {entity} left the area",
        "entity_vanished — {entity} walked away",
        "entity_vanished — {entity} disappeared around a bend",
    ],
    "sound_heard": [
        "sound_heard — {sound}, from the {direction}",
        "sound_heard — {sound}, faint, from the {direction}",
        "sound_heard — {sound}, loud, from the {direction}",
    ],
    "drive_critical": [
        "drive_critical — {drive} at {value}",
        "drive_critical — {drive} at {value}, rising",
    ],
    "object_state_changed": [
        "object_state_changed — {change}",
    ],
    "memory_recalled": [
        "memory_recalled — {memory}",
    ],
    "time_passed": [
        "time_passed — {time}",
    ],
    "stall_detected": [
        "stall_detected — been doing the same task for a while",
        "stall_detected — been at this for too long",
    ],
}

DIRECTIONS = ["north", "south", "east", "west"]
DISTANCES = [1, 2, 3, 4, 5, 6]
BEHAVIORS = ["walking quickly", "approaching", "carrying a basket", "looking around",
             "sitting alone", "running", "limping", "armed", "talking loudly"]
SOUNDS = ["shouting", "footsteps", "knocking", "howling", "singing", "laughter",
          "screaming", "hammering", "hoofbeats", "glass breaking", "thunder",
          "arguing", "whispering", "crying", "a bell ringing"]
DRIVES_LIST = ["hunger", "energy", "social", "safety"]
CHANGES = ["fence broken", "door left open", "supplies running low", "fire started",
           "crops damaged", "tools missing", "water level dropping", "new notice posted",
           "package arrived", "weather changing"]
MEMORIES = ["an old friend who moved away", "the last harvest festival",
            "a debt owed to the merchant", "a promise made to a friend",
            "the winter that nearly killed the town", "a childhood game",
            "the old innkeeper who retired", "a story my grandmother told"]
TIMES = ["dawn", "midday", "afternoon", "dusk", "evening", "night", "late night"]

# ─── Scenario templates for think mode ───────────────────────────────────────

@dataclass
class ThinkScenario:
    signal_type: str
    thought_template: str
    want_template: str
    feel: str
    mood_template: str
    goal_template: str
    beliefs_template: str
    recent_thoughts_template: str
    # Drive requirements
    min_drives: Optional[dict] = None  # e.g., {"hunger": 60}

def generate_drives(scenario: Optional[ThinkScenario] = None):
    """Generate drive values. If scenario has min_drives, enforce them."""
    drives = {
        "energy": random.randint(15, 95),
        "hunger": random.randint(10, 95),
        "social": random.randint(10, 95),
        "safety": random.randint(30, 95),
    }
    if scenario and scenario.min_drives:
        for k, v in scenario.min_drives.items():
            drives[k] = random.randint(v, min(v + 15, 100))
    return drives

def format_drives(drives):
    return f"energy={drives['energy']} hunger={drives['hunger']} social={drives['social']} safety={drives['safety']}"

def generate_mood(feel, being):
    """Generate mood string consistent with the feeling."""
    mood_map = {
        "calm": "calm 0.{v}",
        "content": "contentment 0.{v}",
        "happy": "happiness 0.{v}",
        "joyful": "joy 0.{v}",
        "excited": "excitement 0.{v}",
        "eager": "eagerness 0.{v}",
        "hopeful": "hope 0.{v}",
        "proud": "pride 0.{v}",
        "satisfied": "satisfaction 0.{v}",
        "grateful": "gratitude 0.{v}",
        "warm": "warmth 0.{v}",
        "friendly": "friendliness 0.{v}",
        "amused": "amusement 0.{v}",
        "curious": "curiosity 0.{v}",
        "focused": "focus 0.{v}",
        "determined": "determination 0.{v}",
        "resolute": "resolve 0.{v}",
        "alert": "alertness 0.{v}",
        "vigilant": "vigilance 0.{v}",
        "wary": "caution 0.{v}",
        "suspicious": "suspicion 0.{v}",
        "cautious": "caution 0.{v}",
        "nervous": "nervousness 0.{v}",
        "anxious": "anxiety 0.{v}",
        "afraid": "fear 0.{v}",
        "terrified": "fear 0.{v}, panic 0.{v2}",
        "panicked": "panic 0.{v}",
        "uneasy": "unease 0.{v}",
        "angry": "anger 0.{v}",
        "furious": "rage 0.{v}",
        "frustrated": "frustration 0.{v}",
        "annoyed": "irritation 0.{v}",
        "irritated": "irritation 0.{v}",
        "indignant": "indignation 0.{v}",
        "sad": "sadness 0.{v}",
        "lonely": "loneliness 0.{v}",
        "melancholy": "sorrow 0.{v}",
        "grieving": "grief 0.{v}",
        "despairing": "despair 0.{v}",
        "mournful": "mourning 0.{v}",
        "tired": "fatigue 0.{v}",
        "exhausted": "fatigue 0.{v}, weariness 0.{v2}",
        "weary": "weariness 0.{v}",
        "bored": "boredom 0.{v}",
        "restless": "restlessness 0.{v}",
        "drained": "fatigue 0.{v}",
        "worried": "worry 0.{v}",
        "concerned": "concern 0.{v}",
        "alarmed": "alarm 0.{v}",
        "desperate": "desperation 0.{v}",
        "peaceful": "peace 0.{v}",
        "serene": "serenity 0.{v}",
        "relaxed": "calm 0.{v}",
        "drowsy": "drowsiness 0.{v}",
        "nostalgic": "nostalgia 0.{v}",
        "reflective": "calm 0.{v}",
        "embarrassed": "embarrassment 0.{v}",
        "ashamed": "shame 0.{v}",
        "guilty": "guilt 0.{v}",
        "confused": "confusion 0.{v}",
        "surprised": "surprise 0.{v}",
        "neutral": "none",
        "indifferent": "calm 0.{v}",
    }
    v = random.randint(3, 6)
    v2 = random.randint(2, 4)
    template = mood_map.get(feel, "calm 0.{v}")
    if being.category == "mythical" and being.name == "stone golem":
        return "none"
    return template.format(v=v, v2=v2)

# ─── Think example generation with templates ─────────────────────────────────

# Pre-built scenarios for high-quality variation
THINK_SCENARIOS = [
    # === Mundane / Nothing Notable (want: "nothing") ===
    {
        "beings": ["innkeeper", "baker", "farmer", "herbalist", "blacksmith", "guard", "courier", "gossip"],
        "signal": "nothing_notable",
        "thoughts": [
            ("Nothing happening. Just another quiet {time_of_day}.", "calm"),
            ("Same routine, same work. Not complaining.", "content"),
            ("Peaceful today. No complaints.", "calm"),
            ("Just keeping at it. Steady work.", "focused"),
            ("Quiet day. Nothing demanding my attention.", "calm"),
        ],
        "want": "nothing",
    },
    {
        "beings": ["wolf", "dog", "cat", "horse", "crow", "rat"],
        "signal": "nothing_notable",
        "thoughts": [
            ("Quiet. Safe. Rest.", "calm"),
            ("Nothing moving. Wait.", "calm"),
            ("Warm. Good spot. Stay.", "content"),
            ("No threats. Relax.", "relaxed"),
        ],
        "want": "nothing",
    },
    {
        "beings": ["forest spirit", "stone golem", "ghost", "water elemental"],
        "signal": "nothing_notable",
        "thoughts": [
            ("All is as it should be. Continue.", "serene"),
            ("No change. Hold.", "neutral"),
            ("Stillness. Nothing stirs.", "peaceful"),
        ],
        "want": "nothing",
    },
    # === Entity appeared — friendly ===
    {
        "beings": ["innkeeper", "baker", "farmer", "herbalist", "blacksmith", "gossip"],
        "signal": "entity_appeared_friendly",
        "thoughts": [
            ("{entity} is here. Good to see a friendly face.", "warm"),
            ("Oh, {entity} is coming this way. I should say hello.", "friendly"),
            ("{entity} again. We always get along well.", "pleased"),
        ],
        "want_templates": [
            "go to {location} to greet {entity}",
            "nothing",
        ],
    },
    # === Entity appeared — threatening ===
    {
        "beings": ["guard", "innkeeper", "farmer", "courier"],
        "signal": "entity_appeared_threat",
        "thoughts": [
            ("Armed {entity} approaching. This doesn't look good.", "wary"),
            ("{entity} heading this way. They look hostile. Stay alert.", "alert"),
            ("Trouble approaching. I should be ready.", "nervous"),
        ],
        "want_templates": [
            "go to {location} to prepare for the threat",
            "go to guard_post to alert the other guards",
            "nothing",
        ],
    },
    # === Drive critical — hunger ===
    {
        "beings": ["innkeeper", "baker", "farmer", "guard", "courier", "blacksmith", "herbalist", "gossip"],
        "signal": "drive_critical_hunger",
        "thoughts": [
            ("Stomach is growling. Need to eat something soon.", "hungry"),
            ("Can't focus with this hunger. Need food.", "distracted"),
            ("Starving. Should have eaten hours ago.", "miserable"),
        ],
        "want_templates": [
            "go to inn to eat",
            "go to market to find food",
            "go to home to eat",
        ],
        "min_drives": {"hunger": 60},
    },
    {
        "beings": ["wolf", "dog", "cat", "crow", "rat"],
        "signal": "drive_critical_hunger",
        "thoughts": [
            ("Hungry. Need food. Search.", "desperate"),
            ("Belly empty. Must find something.", "hungry"),
            ("Food smell somewhere. Find it.", "eager"),
        ],
        "want_templates": [
            "go to {location} to hunt for food",
            "go to {location} to search for scraps",
        ],
        "min_drives": {"hunger": 65},
    },
    # === Drive critical — energy ===
    {
        "beings": ["innkeeper", "baker", "farmer", "guard", "courier", "blacksmith", "herbalist"],
        "signal": "drive_critical_energy",
        "thoughts": [
            ("Can barely keep going. Need to rest.", "exhausted"),
            ("Legs are heavy. Eyes won't stay open.", "drained"),
            ("I've been pushing too hard. Need sleep.", "weary"),
        ],
        "want_templates": [
            "go to home to sleep",
            "nothing",
        ],
        "min_drives": {"energy": 10, "energy_max": 30},
    },
    # === Drive critical — social ===
    {
        "beings": ["innkeeper", "baker", "herbalist", "gossip", "farmer", "blacksmith", "courier"],
        "signal": "drive_critical_social",
        "thoughts": [
            ("Haven't talked to anyone in too long. Need some company.", "lonely"),
            ("Feeling isolated. Should find someone to talk to.", "restless"),
            ("Can't stand this silence anymore. Need people.", "lonely"),
        ],
        "want_templates": [
            "go to inn to find company",
            "go to market to see who's around",
            "go to well to see if anyone is there",
            "go to town_square to find someone to talk to",
        ],
        "min_drives": {"social": 70},
    },
    # === Sound heard ===
    {
        "beings": ["guard", "innkeeper", "farmer", "herbalist", "courier"],
        "signal": "sound_heard",
        "thoughts": [
            ("What was that? Sounded like {sound}. Should check.", "alert"),
            ("{sound_desc} — can't ignore that. Need to investigate.", "concerned"),
            ("I heard {sound}. Could be trouble.", "wary"),
        ],
        "want_templates": [
            "go to {location} to investigate the noise",
            "nothing",
        ],
    },
    {
        "beings": ["wolf", "dog", "cat"],
        "signal": "sound_heard_animal",
        "thoughts": [
            ("Noise! What? Listen. Danger?", "alert"),
            ("Sound. Ears up. Watch.", "wary"),
            ("Loud. Scary. Stay low.", "frightened"),
        ],
        "want_templates": [
            "nothing",
            "go to {location} to investigate",
        ],
    },
    # === Object state changed ===
    {
        "beings": ["farmer", "innkeeper", "blacksmith", "herbalist", "baker", "guard"],
        "signal": "object_state_changed",
        "thoughts": [
            ("Something's changed. {change_desc}. Need to deal with it.", "concerned"),
            ("{change_desc}. This needs attention right away.", "worried"),
            ("Not good. {change_desc}. Have to act.", "anxious"),
        ],
        "want_templates": [
            "go to {location} to deal with the problem",
            "nothing",
        ],
    },
    # === Memory recalled ===
    {
        "beings": ["innkeeper", "baker", "farmer", "herbalist", "blacksmith", "gossip", "guard", "courier"],
        "signal": "memory_recalled",
        "thoughts": [
            ("I just remembered — {memory_desc}. I should do something about it.", "thoughtful"),
            ("{memory_desc}. That was a while ago but it still matters.", "nostalgic"),
            ("Wait, I nearly forgot — {memory_desc}.", "surprised"),
        ],
        "want_templates": [
            "go to {location} to act on the memory",
            "nothing",
        ],
    },
    {
        "beings": ["ghost"],
        "signal": "memory_recalled",
        "thoughts": [
            ("I remember when {memory_desc}. That feels like another life.", "melancholy"),
            ("{memory_desc}. The past is all I have now.", "wistful"),
        ],
        "want": "nothing",
    },
    # === Time passed ===
    {
        "beings": ["innkeeper", "baker", "farmer", "guard", "courier", "herbalist", "blacksmith", "gossip"],
        "signal": "time_passed",
        "thoughts": [
            ("{time} already. Time moves fast when you're busy.", "surprised"),
            ("{time}. Time to change what I'm doing.", "calm"),
        ],
        "want_templates": [
            "go to {location} to {activity}",
            "nothing",
        ],
    },
]


def generate_think_example():
    """Generate a single think mode training example."""
    # Pick a being
    being = random.choice(BEINGS)

    # Pick a scenario appropriate for this being
    applicable = [s for s in THINK_SCENARIOS if being.name in s.get("beings", [])]
    if not applicable:
        applicable = [THINK_SCENARIOS[0]]  # fallback to mundane
    scenario = random.choice(applicable)

    # Generate drives
    drives = generate_drives()
    if "min_drives" in scenario:
        for k, v in scenario["min_drives"].items():
            if k.endswith("_max"):
                base_k = k.replace("_max", "")
                drives[base_k] = random.randint(scenario["min_drives"].get(base_k, 10), v)
            else:
                drives[k] = random.randint(v, min(v + 20, 100))

    # Pick location
    location = random.choice(being.locations)
    activity = random.choice(being.activities)

    # Generate signal
    sig_type = scenario["signal"]
    if sig_type == "nothing_notable":
        signal = "nothing_notable"
    elif sig_type == "entity_appeared_friendly":
        entity = random.choice(ENTITY_NAMES[:9])  # named entities
        dist = random.choice(DISTANCES[:4])
        direction = random.choice(DIRECTIONS)
        signal = f"entity_appeared — {entity}, {dist} tiles {direction}"
    elif sig_type == "entity_appeared_threat":
        entity = random.choice(["armed strangers", "a hooded figure", "unfamiliar men", "a suspicious person"])
        dist = random.choice(DISTANCES[2:])
        direction = random.choice(DIRECTIONS)
        behavior = random.choice(["approaching quickly", "armed", "looking around suspiciously"])
        signal = f"entity_appeared — {entity}, {dist} tiles {direction}, {behavior}"
    elif sig_type in ("drive_critical_hunger", "drive_critical_energy", "drive_critical_social"):
        drive_name = sig_type.split("_")[-1]
        signal = f"drive_critical — {drive_name} at {drives.get(drive_name, 70)}"
    elif sig_type == "sound_heard":
        sound = random.choice(SOUNDS)
        direction = random.choice(DIRECTIONS)
        signal = f"sound_heard — {sound}, from the {direction}"
    elif sig_type == "sound_heard_animal":
        sound = random.choice(["loud bang", "rustling", "footsteps", "howling", "barking", "hissing"])
        direction = random.choice(DIRECTIONS)
        signal = f"sound_heard — {sound}, from the {direction}"
    elif sig_type == "object_state_changed":
        change = random.choice(CHANGES)
        signal = f"object_state_changed — {change}"
    elif sig_type == "memory_recalled":
        memory = random.choice(MEMORIES)
        signal = f"memory_recalled — {memory}"
    elif sig_type == "time_passed":
        time = random.choice(TIMES)
        signal = f"time_passed — {time}"
    else:
        signal = "nothing_notable"

    # Generate thought and feel
    thought_options = scenario.get("thoughts", [("Nothing notable.", "calm")])
    thought_template, feel = random.choice(thought_options)

    # Simple template filling
    entity = random.choice(ENTITY_NAMES[:9])
    time_of_day = random.choice(["morning", "afternoon", "evening", "day"])
    sound = random.choice(SOUNDS)
    change = random.choice(CHANGES)
    memory = random.choice(MEMORIES)
    time = random.choice(TIMES)

    thought = thought_template.format(
        entity=entity, time_of_day=time_of_day, sound=sound,
        sound_desc=f"That sounded like {sound}",
        change_desc=change, memory_desc=memory, time=time,
    )

    # Adjust thought style for being type
    if being.thought_style == "terse":
        # Shorten to fragments
        words = thought.split()
        if len(words) > 8:
            thought = " ".join(words[:8]) + "."
    elif being.thought_style == "sparse":
        words = thought.split()
        if len(words) > 10:
            thought = " ".join(words[:10]) + "."

    # Generate want
    if "want" in scenario:
        want = scenario["want"]
    elif "want_templates" in scenario:
        want_template = random.choice(scenario["want_templates"])
        target_loc = random.choice([l for l in LOCATIONS if l != location] or [location])
        want = want_template.format(
            location=target_loc,
            entity=entity,
            activity=random.choice(["check on things", "see what happened", "help out"]),
        )
    else:
        want = "nothing"

    # Generate mood
    mood = generate_mood(feel, being)

    # Generate beliefs and goals
    goal = random.choice(["none", activity, f"finish {activity}"])
    beliefs = random.choice(["none", "none", "none",
                              f"{entity} is trustworthy (0.6)",
                              f"the market is busy at this hour (0.5)"])
    recent = random.choice(["none", "none", f"Quiet {time_of_day} so far."])

    # Build the user message
    user_content = f"""<think>
BEING: {being.name}
DRIVES: {format_drives(drives)}
MOOD: {mood}
LOCATION: {location}
DOING: {activity}

SIGNAL: {signal}
GOAL: {goal}
BELIEFS: {beliefs}
RECENT_THOUGHTS: {recent}"""

    # Build assistant response
    assistant_content = json.dumps({
        "thought": thought,
        "want": want,
        "feel": feel,
    })

    return {
        "messages": [
            {"role": "system", "content": SYSTEM_MSG},
            {"role": "user", "content": user_content},
            {"role": "assistant", "content": assistant_content},
        ]
    }


def generate_infer_example():
    """Generate a single infer mode training example."""
    being = random.choice([b for b in BEINGS if b.category == "human"])
    observed_entity = random.choice(ENTITY_NAMES)

    drives = generate_drives()
    location = random.choice(being.locations)
    activity = random.choice(being.activities)
    mood = random.choice(["calm 0.4", "curiosity 0.3", "alertness 0.4", "suspicion 0.3"])
    trust = round(random.uniform(0.1, 0.9), 1)

    observations = [
        (f"walked in quickly, looking around", "looking for someone or something", "curious", "They might need help or be searching for someone."),
        (f"sat down quietly in the corner", "wants to be left alone", "withdrawn", "They don't seem to want company right now."),
        (f"asked about prices at the stall", "looking to buy something", "neutral", "Possible customer — nothing unusual."),
        (f"was arguing with another merchant", "disputes over trade", "angry", "Could escalate if not settled — stay clear or mediate."),
        (f"handed a sealed letter to {random.choice(ENTITY_NAMES[:5])}", "delivering a private message", "secretive", "Something is being communicated that they don't want overheard."),
        (f"left abruptly without paying", "trying to avoid paying", "guilty", "They owe money and don't intend to pay — I should be wary."),
        (f"smiled and waved", "friendly greeting", "happy", "They seem in good spirits — no cause for concern."),
        (f"was whispering with {random.choice(ENTITY_NAMES[:5])}", "sharing a secret", "conspiratorial", "Something private is being discussed — could affect me."),
        (f"offered to help carry supplies", "being genuinely helpful", "kind", "This is a good sign — they want to build goodwill."),
        (f"was pacing back and forth near the gate", "nervous about something", "anxious", "Something has them worried — might be worth asking."),
        (f"said 'Have you seen {random.choice(ENTITY_NAMES[:5])}?'", "looking for {entity}".format(entity=random.choice(ENTITY_NAMES[:5])), "concerned", "They're trying to find someone — might be urgent."),
        (f"bought a large amount of supplies", "preparing for something", "determined", "Either a long journey or they're stocking up for trouble."),
        (f"was staring at me from across the square", "watching me for some reason", "unclear", "Hard to read — could be curiosity or suspicion."),
        (f"dropped coins on the ground and didn't pick them up", "distracted or wealthy", "distracted", "Their mind is elsewhere — something must be weighing on them."),
    ]

    obs_tuple = random.choice(observations)
    observed, intent, emotion, implication = obs_tuple

    # Trust modulation
    if trust < 0.3:
        # Low trust — more suspicious interpretation
        if emotion == "neutral":
            emotion = "suspicious"
        if "nothing unusual" in implication:
            implication = "I should watch them carefully."

    history_options = [
        "first encounter",
        "we've spoken a few times — pleasant",
        f"last time they came, they caused trouble",
        f"they helped me once before",
        "I've seen them around but never spoken",
        "they owe me a favor",
    ]
    history = random.choice(history_options)

    user_content = f"""<infer>
BEING: {being.name}
DRIVES: {format_drives(drives)}
MOOD: {mood}
LOCATION: {location}
DOING: {activity}

ENTITY: {observed_entity}
OBSERVED: {observed}
HISTORY: {history}
TRUST: {trust}"""

    assistant_content = json.dumps({
        "intent": intent,
        "emotion": emotion,
        "implication": implication,
    })

    return {
        "messages": [
            {"role": "system", "content": SYSTEM_MSG},
            {"role": "user", "content": user_content},
            {"role": "assistant", "content": assistant_content},
        ]
    }


def generate_appraise_example():
    """Generate a single appraise mode training example."""
    being = random.choice(BEINGS)
    drives = generate_drives()

    # Thought + appropriate emotional response
    appraisals = [
        # Threatening
        ("I heard something in the dark. Could be dangerous.",
         {"fear": 0.3, "alertness": 0.2}, "potential threat perceived"),
        ("Armed strangers are approaching. This could get ugly.",
         {"fear": 0.4, "anxiety": 0.3}, "direct threat approaching"),
        ("The wolves are getting closer to town.",
         {"fear": 0.3, "worry": 0.2}, "growing danger to community"),
        # Loss
        ("The crops are ruined. Months of work, gone.",
         {"sadness": 0.5, "despair": 0.3}, "significant loss"),
        ("My friend moved away and won't come back.",
         {"sadness": 0.4, "loneliness": 0.3}, "social loss"),
        ("The old tree was felled. It stood for centuries.",
         {"grief": 0.4, "anger": 0.2}, "irreplaceable loss"),
        # Social connection
        ("A friend came to visit. It's been too long.",
         {"joy": 0.3, "warmth": 0.2}, "social need being met"),
        ("The townspeople thanked me for my help.",
         {"pride": 0.3, "satisfaction": 0.2}, "social validation"),
        ("Someone remembered my name after all this time.",
         {"surprise": 0.2, "warmth": 0.3}, "unexpected social connection"),
        # Accomplishment
        ("I finished the blade. Best work I've done.",
         {"pride": 0.4, "satisfaction": 0.3}, "task mastery"),
        ("The harvest came in strong this year.",
         {"satisfaction": 0.3, "relief": 0.2}, "effort rewarded"),
        ("The remedy worked. The patient is recovering.",
         {"relief": 0.4, "pride": 0.2}, "professional success"),
        # Mundane (minimal change)
        ("Just another quiet afternoon.",
         {}, "nothing to react to"),
        ("The bread is in the oven. Same as always.",
         {}, "routine task — no emotional weight"),
        ("Walking the usual route. Nothing new.",
         {}, "nothing to react to"),
        ("The sun is going down. Time passes.",
         {}, "neutral observation"),
        ("Same old counter. Same old glasses.",
         {}, "nothing to react to"),
        # Conflict/moral
        ("I could steal the bread but the baker has always been kind.",
         {"guilt": 0.3, "conflict": 0.2}, "moral tension"),
        ("They need my help but I'm too tired to move.",
         {"guilt": 0.2, "frustration": 0.2}, "conflicting obligations"),
        # Fear
        ("I'm alone on the road at night.",
         {"fear": 0.3, "anxiety": 0.2}, "vulnerability"),
        # Surprise
        ("The merchant offered double the usual price.",
         {"surprise": 0.3, "suspicion": 0.1}, "unexpected good fortune"),
    ]

    thought, emotions, reason = random.choice(appraisals)

    # Scale emotions slightly randomly
    scaled_emotions = {}
    for k, v in emotions.items():
        scaled = round(v + random.uniform(-0.1, 0.1), 2)
        scaled = max(-1.0, min(1.0, scaled))
        if abs(scaled) > 0.05:
            scaled_emotions[k] = scaled

    current_mood = generate_mood(random.choice(["calm", "content", "worried", "alert"]), being)
    mood = current_mood

    user_content = f"""<appraise>
BEING: {being.name}
DRIVES: {format_drives(drives)}
MOOD: {mood}

THOUGHT: {thought}
CURRENT_MOOD: {current_mood}"""

    assistant_content = json.dumps({
        "emotions": scaled_emotions,
        "reason": reason,
    })

    return {
        "messages": [
            {"role": "system", "content": SYSTEM_MSG},
            {"role": "user", "content": user_content},
            {"role": "assistant", "content": assistant_content},
        ]
    }


def generate_speak_example():
    """Generate a single speak mode training example."""
    being = random.choice(BEINGS)
    drives = generate_drives()
    location = random.choice(being.locations)
    activity = random.choice(being.activities)
    mood = generate_mood(random.choice(["calm", "happy", "worried", "angry", "tired"]), being)

    speaking_to = random.choice(ENTITY_NAMES[:9])
    trust = round(random.uniform(0.3, 0.9), 1)

    # Thought-to-utterance pairs
    if being.can_speak:
        scenarios = [
            # Greetings
            (f"Good to see {speaking_to}. Been a while.",
             f"trust: {trust}, acquaintance", "they walked up to me",
             f"Haven't seen you around lately. How've you been?"),
            (f"{speaking_to} is here. I need their help.",
             f"trust: {trust}, professional relationship", "I need to ask for something",
             f"Glad I caught you. I could use a hand with something."),
            # Warnings
            (f"Something dangerous is out there. {speaking_to} should know.",
             f"trust: {trust}, neighbor", f"heard about a threat",
             f"Watch yourself out there. I heard there's trouble on the road."),
            (f"Wolves have been spotted near town. People need to be careful.",
             f"trust: {trust}, fellow townsperson", "wolves sighted",
             f"Stay close to town after dark. Wolves have been seen nearby."),
            # Commerce
            (f"This is good quality work. Fair price.",
             f"trust: {trust}, customer", f"{speaking_to} is buying goods",
             f"That'll be two silver. Fair price for good work."),
            (f"The usual order, nothing fancy.",
             f"trust: {trust}, regular customer", f"regular transaction",
             f"The usual? Coming right up."),
            # Gossip
            (f"I just heard something interesting about the merchant.",
             f"trust: {trust}, friend", f"ran into {speaking_to}",
             f"You won't believe what I heard about the merchant at the market."),
            # Concern
            (f"{speaking_to} looks unwell. I should ask.",
             f"trust: {trust}, friend", f"{speaking_to} appears sick",
             f"You don't look well. Are you feeling alright?"),
            # Anger
            (f"{speaking_to} hasn't paid their debt. I've had enough.",
             f"trust: {trust}, debtor", f"confrontation over unpaid debt",
             f"You still owe me for last month. I need that payment."),
            # Simple exchange
            (f"Morning. Nothing much to report.",
             f"trust: {trust}, colleague", f"morning greeting",
             f"Morning. Quiet one so far."),
        ]
    else:
        # Animal behavioral descriptions
        scenarios = [
            (f"Happy to see this person.",
             f"trust: {trust}", f"{speaking_to} approached",
             f"*wags tail vigorously, circles {speaking_to}'s legs*"),
            (f"Stranger approaching. Warning.",
             f"trust: {trust}", f"unknown person near",
             f"*growls low, hackles raised, positions between {speaking_to} and the stranger*"),
            (f"Food nearby. Want it.",
             f"trust: {trust}", f"{speaking_to} has food",
             f"*sits upright, stares at {speaking_to}'s hand, whimpers softly*"),
            (f"Danger sensed. Alert the pack.",
             f"trust: {trust}", f"threat detected",
             f"*howls sharply, turns toward the treeline, ears pinned back*"),
            (f"This person is safe. Approach cautiously.",
             f"trust: {trust}", f"{speaking_to} is sitting quietly",
             f"*approaches slowly, sniffs cautiously, rubs against {speaking_to}'s leg*"),
            (f"Threatened. Back away.",
             f"trust: {trust}", f"{speaking_to} moved suddenly",
             f"*hisses, arches back, retreats to a safe distance*"),
        ]

    thought, relationship, context, utterance = random.choice(scenarios)

    user_content = f"""<speak>
BEING: {being.name}
DRIVES: {format_drives(drives)}
MOOD: {mood}
LOCATION: {location}
DOING: {activity}

THOUGHT: "{thought}"
SPEAKING_TO: {speaking_to}
RELATIONSHIP: {relationship}
CONTEXT: {context}"""

    assistant_content = json.dumps({
        "utterance": utterance,
    })

    return {
        "messages": [
            {"role": "system", "content": SYSTEM_MSG},
            {"role": "user", "content": user_content},
            {"role": "assistant", "content": assistant_content},
        ]
    }


def generate_batch(mode, count, output_file):
    """Generate a batch of training examples."""
    generators = {
        "think": generate_think_example,
        "infer": generate_infer_example,
        "appraise": generate_appraise_example,
        "speak": generate_speak_example,
    }

    gen = generators[mode]
    examples = []

    for _ in range(count):
        example = gen()
        examples.append(json.dumps(example))

    with open(output_file, "w") as f:
        f.write("\n".join(examples) + "\n")

    print(f"Generated {count} {mode} examples → {output_file}")
    return count


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python generate_training.py <mode> <count> <output_file>")
        print("  mode: think, infer, appraise, speak")
        print("  count: number of examples")
        print("  output_file: path to output JSONL file")
        sys.exit(1)

    mode = sys.argv[1]
    count = int(sys.argv[2])
    output_file = sys.argv[3]

    generate_batch(mode, count, output_file)
