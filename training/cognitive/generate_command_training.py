#!/usr/bin/env python3
"""
Training data generator for adventure-command cognitive model.
Generates JSONL training examples with <think>...</think> + COMMAND format.

Each example has grounded perception (visible entities, objects, locations)
and the command MUST only reference nouns present in the perception context.
"""

import json
import random
import sys
from dataclasses import dataclass, field

random.seed(42)

SYSTEM_MSG = (
    "You are the mind of a simulated being. You receive your state and "
    "perceptions, think about your situation, then choose one action. "
    "Think inside <think></think> tags, then output exactly one command."
)

# ─── World data ─────────────────────────────────────────────────────────────

LOCATIONS = [
    "bakery", "guard_post", "herbalist_shop", "courier_office",
    "blacksmith", "town_square", "market", "farm", "inn",
    "home_north", "home_east", "home_south", "home_west",
    "well", "road_east", "road_south",
]

# Location associations for drive-motivated movement
FOOD_LOCATIONS = ["inn", "bakery", "market", "farm"]
REST_LOCATIONS = ["home_north", "home_east", "home_south", "home_west", "inn"]
SOCIAL_LOCATIONS = ["inn", "market", "town_square", "well"]

OBJECTS = {
    "bakery": [("Brick Oven", "working"), ("Flour Sacks", "full"), ("Bread Basket", "full")],
    "guard_post": [("Weapon Rack", "working"), ("Guard Lantern", "working")],
    "herbalist_shop": [("Herb Drying Rack", "working"), ("Mortar and Pestle", "working"), ("Remedy Shelf", "full")],
    "blacksmith": [("Anvil", "working"), ("Forge", "working"), ("Metal Ingots", "full")],
    "inn": [("Pantry", "full"), ("Guest Ledger", "working"), ("Ale Barrel", "full")],
    "farm": [("Plow", "working"), ("Seed Storage", "full"), ("Water Trough", "full")],
    "market": [("Market Stall", "working"), ("Trade Goods", "full")],
    "town_square": [("Well Bucket", "working"), ("Notice Board", "working")],
}

OBJECT_STATES_BROKEN = ["broken", "empty", "locked"]

NPC_NAMES = {
    "Edith": "baker",
    "Roland": "guard",
    "Ivy": "herbalist",
    "Felix": "courier",
    "Greta": "gossip",
    "Mabel": "innkeeper",
    "Aldric": "blacksmith",
    "Hugo": "farmer",
}

DIRECTIONS = ["north", "south", "east", "west", "northeast", "northwest", "southeast", "southwest"]
DISTANCES = [1, 2, 3, 4, 5, 6, 7, 8]

# ─── Being definitions ──────────────────────────────────────────────────────

@dataclass
class Being:
    name: str
    category: str  # human, animal, mythical
    work_locations: list
    activities: list
    home: str = "home_north"
    can_speak: bool = True
    thought_style: str = "full"  # full, terse, sparse


BEINGS = [
    Being("innkeeper", "human", ["inn"],
          ["wiping the counter", "serving drinks", "sweeping the floor", "counting coins",
           "restocking shelves", "preparing a room"], home="home_south"),
    Being("guard", "human", ["guard_post", "town_square"],
          ["standing watch", "walking patrol", "sharpening sword", "checking papers",
           "leaning against the wall", "scanning the road"], home="home_north"),
    Being("baker", "human", ["bakery", "market"],
          ["kneading dough", "pulling bread from the oven", "measuring flour",
           "setting out fresh bread", "cleaning the oven"], home="home_east"),
    Being("farmer", "human", ["farm", "market"],
          ["tending crops", "pulling weeds", "feeding chickens", "mending the fence",
           "planting seeds", "loading produce"], home="home_west"),
    Being("herbalist", "human", ["herbalist_shop"],
          ["sorting remedies", "grinding herbs", "brewing tea", "labeling jars",
           "examining a plant", "mixing a remedy"], home="home_south"),
    Being("blacksmith", "human", ["blacksmith"],
          ["hammering at the forge", "examining a blade", "organizing tools",
           "cooling metal", "tempering a blade"], home="home_north"),
    Being("courier", "human", ["road_east", "town_square", "inn"],
          ["walking", "picking up a package", "reading a notice board",
           "eating a meal", "searching for an address"], home="home_east"),
    Being("gossip", "human", ["market", "well", "town_square", "inn"],
          ["chatting with neighbors", "drawing water", "looking around",
           "buying vegetables", "mending clothes"], home="home_west"),
    Being("merchant", "human", ["market", "inn"],
          ["arranging goods", "counting inventory", "haggling", "loading a cart"],
          home="home_east"),
    # Animals
    Being("wolf", "animal", ["road_east", "road_south"],
          ["prowling", "resting", "sniffing the air", "watching", "marking territory"],
          can_speak=False, thought_style="terse"),
    Being("dog", "animal", ["farm", "inn", "town_square", "market"],
          ["lying in the sun", "sitting by the gate", "sniffing around",
           "watching", "chasing tail"], can_speak=False, thought_style="terse"),
    Being("cat", "animal", ["bakery", "inn", "market", "herbalist_shop"],
          ["sitting on a windowsill", "sleeping", "grooming", "watching from the rafters",
           "skulking between stalls"], can_speak=False, thought_style="terse"),
    Being("horse", "animal", ["farm", "road_east"],
          ["standing idle", "grazing", "stamping feet", "eating oats"],
          can_speak=False, thought_style="terse"),
    Being("crow", "animal", ["town_square", "farm", "market"],
          ["perched on a roof", "circling above", "sitting on a signpost"],
          can_speak=False, thought_style="terse"),
    Being("rat", "animal", ["inn", "market", "bakery"],
          ["hiding under a stall", "sneaking toward food", "nibbling on grain"],
          can_speak=False, thought_style="terse"),
    # Mythical
    Being("forest spirit", "mythical", ["road_east", "road_south"],
          ["drifting among the trees", "watching the treeline", "sensing vibrations"],
          can_speak=False, thought_style="sparse"),
    Being("stone golem", "mythical", ["guard_post"],
          ["standing guard", "scanning the perimeter", "blocking the entrance"],
          thought_style="sparse"),
    Being("ghost", "mythical", ["inn", "town_square"],
          ["drifting", "hovering", "watching the living"],
          can_speak=False, thought_style="sparse"),
]

EMOTIONS_BY_VALENCE = {
    "positive": ["calm", "content", "happy", "joyful", "excited", "proud",
                 "satisfied", "grateful", "warm", "friendly", "amused", "peaceful"],
    "negative": ["worried", "anxious", "afraid", "angry", "frustrated", "sad",
                 "lonely", "tired", "exhausted", "nervous", "suspicious", "uneasy"],
    "cognitive": ["curious", "focused", "alert", "determined", "confused", "surprised"],
}


# ─── Helpers ────────────────────────────────────────────────────────────────

def rand_drives(overrides=None):
    d = {"energy": random.randint(20, 90), "hunger": random.randint(10, 90),
         "social": random.randint(15, 90), "safety": random.randint(40, 95)}
    if overrides:
        d.update(overrides)
    return d


def fmt_drives(d):
    return f"energy={d['energy']} hunger={d['hunger']} social={d['social']} safety={d['safety']}"


def rand_mood(valence="positive"):
    emo = random.choice(EMOTIONS_BY_VALENCE[valence])
    intensity = round(random.uniform(0.2, 0.7), 1)
    # Sometimes add a second emotion
    if random.random() < 0.4:
        if valence == "positive":
            second_valence = random.choice(["positive", "cognitive"])
        else:
            second_valence = random.choice(["negative", "cognitive"])
        emo2 = random.choice(EMOTIONS_BY_VALENCE[second_valence])
        i2 = round(random.uniform(0.1, 0.4), 1)
        return f"{emo} {intensity}, {emo2} {i2}"
    return f"{emo} {intensity}"


def pick_visible_entities(being_name, location, count=None):
    """Pick 0-3 random visible entities from NPCs at plausible locations."""
    if count is None:
        count = random.choices([0, 1, 2, 3], weights=[25, 40, 25, 10])[0]
    candidates = []
    for name, role in NPC_NAMES.items():
        if name == being_name:
            continue
        candidates.append(name)
    if random.random() < 0.3:
        candidates.append("Player")
    random.shuffle(candidates)
    result = []
    for name in candidates[:count]:
        dist = random.choice(DISTANCES[:6])
        direction = random.choice(DIRECTIONS)
        activities = ["walking", "standing", "sitting", "working", "talking", "looking around"]
        activity = random.choice(activities)
        result.append({"name": name, "distance": dist, "direction": direction, "activity": activity})
    return result


def pick_visible_objects(location):
    """Pick 0-3 objects visible at this location."""
    available = OBJECTS.get(location, [])
    if not available:
        return []
    count = random.choices([0, 1, 2], weights=[30, 40, 30])[0]
    count = min(count, len(available))
    picked = random.sample(available, count)
    result = []
    for name, default_state in picked:
        # Occasionally make objects broken/empty
        state = default_state if random.random() < 0.8 else random.choice(OBJECT_STATES_BROKEN)
        result.append({"name": name, "state": state})
    return result


def pick_heard(entities_visible):
    """Generate 0-1 heard events."""
    if random.random() < 0.75:
        return []
    sources = list(NPC_NAMES.keys()) + ["someone"]
    source = random.choice(sources)
    texts = [
        "Have you seen Roland?",
        "The market is busy today.",
        "Watch out near the road.",
        "Fresh bread!",
        "Did you hear about the merchant?",
        "Help! Someone help!",
        "Good morning!",
        "The forge is running hot today.",
        "I need to find Ivy.",
        "Quiet night so far.",
    ]
    dist = random.randint(2, 6)
    direction = random.choice(DIRECTIONS)
    return [{"source": source, "text": random.choice(texts), "distance": dist, "direction": direction}]


def pick_available_locations(current, being):
    """Pick 5-8 locations the being knows about (always includes current + work + home)."""
    known = set([current] + being.work_locations + [being.home])
    # Add some random public locations
    public = ["town_square", "market", "well", "inn", "road_east"]
    for loc in public:
        if random.random() < 0.6:
            known.add(loc)
    # Pad to at least 5
    while len(known) < 5:
        known.add(random.choice(LOCATIONS))
    return sorted(known)


def pick_recent_events():
    """Pick 0-2 recent events."""
    events = [
        "Saw Player earlier near the gate.",
        "Finished the morning tasks.",
        "Heard shouting from the market.",
        "Roland walked past without a word.",
        "The weather has been fair.",
        "Someone left a package at the door.",
        "Had a good conversation with Mabel.",
        "The bread sold out quickly today.",
        "Noticed the Flour Sacks are running low.",
        "Ivy mentioned something about rare herbs.",
        "",  # empty = no recent events
        "",
        "",
    ]
    count = random.choices([0, 1, 2], weights=[40, 40, 20])[0]
    picked = random.sample([e for e in events if e], min(count, len([e for e in events if e])))
    return picked


def fmt_perception(entities, objects, heard, recent_events, available_locs, goal, beliefs, last_thought):
    """Format the perception block of the user message."""
    lines = []

    # Visible entities
    lines.append("You see:")
    if entities:
        for e in entities:
            lines.append(f"  {e['name']} -- {e['distance']} tiles {e['direction']}, {e['activity']}")
    else:
        lines.append("  (no one)")

    # Heard
    lines.append("You hear:")
    if heard:
        for h in heard:
            lines.append(f"  {h['source']}: \"{h['text']}\" ({h['distance']} tiles {h['direction']})")
    else:
        lines.append("  (nothing)")

    # Objects
    lines.append("Nearby objects:")
    if objects:
        for o in objects:
            lines.append(f"  {o['name']} ({o['state']})")
    else:
        lines.append("  (none)")

    lines.append("")

    # Recent events
    if recent_events:
        lines.append("Recent: " + " ".join(recent_events))
    else:
        lines.append("Recent: Nothing notable.")

    lines.append(f"Goal: {goal}")
    lines.append(f"Beliefs: {beliefs}")
    lines.append(f"Last thought: {last_thought}")

    lines.append("")
    lines.append(f"Available places: {', '.join(available_locs)}")
    lines.append("")
    lines.append("Think about your situation, then choose ONE action.")

    return "\n".join(lines)


def style_thought(thought, being):
    """Adjust thought text for being type."""
    if being.thought_style == "terse":
        # Animals: short fragments
        words = thought.split()
        if len(words) > 10:
            thought = " ".join(words[:10]) + "."
    elif being.thought_style == "sparse":
        words = thought.split()
        if len(words) > 12:
            thought = " ".join(words[:12]) + "."
    return thought


# ─── Scenario generators ────────────────────────────────────────────────────
# Each returns (think_text, command, drives_override, mood_valence)

def scenario_mundane_wait(being, loc, entities, objects, heard, avail_locs):
    """Calm, nothing to do → WAIT"""
    thoughts = [
        "Nothing demanding my attention. Just a quiet moment.",
        "Peaceful. No rush.",
        "Same as always. Nothing to do right now.",
        "Taking a breath. All is calm.",
        "Quiet moment. Could use this.",
    ]
    if being.thought_style == "terse":
        thoughts = ["Quiet. Safe. Rest.", "Nothing. Wait.", "Still. Good.", "No threat. Rest."]
    elif being.thought_style == "sparse":
        thoughts = ["Stillness. All is as it should be.", "No change. Hold.", "The moment passes."]
    return style_thought(random.choice(thoughts), being), "WAIT", None, "positive"


def scenario_mundane_wander(being, loc, entities, objects, heard, avail_locs):
    """Idle, restless → WANDER or WANDER AT"""
    thoughts = [
        "Nothing pressing. Might as well stretch my legs.",
        "Feeling restless. Should walk around a bit.",
        "Could use a change of scenery.",
        "Time to move. Been standing too long.",
    ]
    if being.thought_style == "terse":
        thoughts = ["Restless. Move.", "Walk. Stretch.", "Bored. Go."]
    elif being.thought_style == "sparse":
        thoughts = ["Movement calls.", "Time to drift."]

    # 50/50: wander here vs wander at a nearby location
    if random.random() < 0.5 and len(avail_locs) > 1:
        target = random.choice([l for l in avail_locs if l != loc])
        cmd = f"WANDER AT {target}"
    else:
        cmd = "WANDER"
    return style_thought(random.choice(thoughts), being), cmd, None, "positive"


def scenario_hunger_go(being, loc, entities, objects, heard, avail_locs):
    """Hungry → GO TO food location"""
    food_locs = [l for l in FOOD_LOCATIONS if l in avail_locs and l != loc]
    if not food_locs:
        food_locs = [l for l in avail_locs if l != loc]
    target = random.choice(food_locs) if food_locs else loc

    thoughts = [
        "My stomach is growling. Need to find something to eat.",
        "Can't focus with this hunger. Should head somewhere with food.",
        "Getting hungry. Time to eat.",
        "Haven't eaten in too long. Need food.",
    ]
    if being.thought_style == "terse":
        thoughts = ["Hungry. Need food. Go.", "Belly empty. Find food.", "Smell food. Go."]
    return (style_thought(random.choice(thoughts), being),
            f"GO TO {target}", {"hunger": random.randint(65, 95)}, "negative")


def scenario_tired_go(being, loc, entities, objects, heard, avail_locs):
    """Exhausted → GO TO home/rest location"""
    rest_locs = [l for l in REST_LOCATIONS if l in avail_locs and l != loc]
    if not rest_locs:
        rest_locs = [l for l in avail_locs if l != loc]
    target = random.choice(rest_locs) if rest_locs else being.home

    thoughts = [
        "Can barely keep my eyes open. Need to rest.",
        "Too tired to keep going. Time to head home.",
        "Exhausted. Everything can wait until tomorrow.",
    ]
    if being.thought_style == "terse":
        thoughts = ["Tired. Sleep. Home.", "Can't... rest.", "Heavy. Need den."]
    return (style_thought(random.choice(thoughts), being),
            f"GO TO {target}", {"energy": random.randint(10, 25)}, "negative")


def scenario_social_approach(being, loc, entities, objects, heard, avail_locs):
    """Social need + visible entity → APPROACH"""
    if not entities:
        return scenario_social_go(being, loc, entities, objects, heard, avail_locs)
    target = random.choice(entities)

    thoughts = [
        f"{target['name']} is nearby. Could use some company.",
        f"Haven't talked to anyone in a while. {target['name']} is right there.",
        f"Feeling lonely. Maybe {target['name']} has a moment to chat.",
    ]
    if being.thought_style == "terse":
        thoughts = [f"{target['name']}. Friend? Go closer.", f"Lonely. {target['name']} there. Approach."]
    return (style_thought(random.choice(thoughts), being),
            f"APPROACH {target['name']}", {"social": random.randint(65, 90)}, "negative")


def scenario_social_go(being, loc, entities, objects, heard, avail_locs):
    """Social need, no one visible → GO TO social location"""
    social_locs = [l for l in SOCIAL_LOCATIONS if l in avail_locs and l != loc]
    if not social_locs:
        social_locs = [l for l in avail_locs if l != loc]
    target = random.choice(social_locs) if social_locs else "inn"

    thoughts = [
        "Haven't spoken to anyone in too long. Should find some company.",
        "Lonely. Need to be around people.",
        "This silence is getting to me. Time to go where people gather.",
    ]
    if being.thought_style == "terse":
        thoughts = ["Alone. Find pack.", "Need others. Go."]
    return (style_thought(random.choice(thoughts), being),
            f"GO TO {target}", {"social": random.randint(70, 95)}, "negative")


def scenario_curiosity_look(being, loc, entities, objects, heard, avail_locs):
    """Curiosity + visible entity → LOOK AT"""
    if not entities:
        if objects:
            return scenario_examine(being, loc, entities, objects, heard, avail_locs)
        return scenario_mundane_wait(being, loc, entities, objects, heard, avail_locs)
    target = random.choice(entities)

    thoughts = [
        f"{target['name']} is {target['activity']} over there. Wonder what they're up to.",
        f"Who's that? {target['name']}, {target['distance']} tiles away. Let me watch.",
        f"Something about {target['name']} caught my eye.",
        f"Haven't seen {target['name']} around here before at this hour.",
    ]
    if being.thought_style == "terse":
        thoughts = [
            f"{target['name']}. Watch. What doing?",
            f"Movement. {target['name']}. Look.",
        ]
    return (style_thought(random.choice(thoughts), being),
            f"LOOK AT {target['name']}", None, "cognitive")


def scenario_examine(being, loc, entities, objects, heard, avail_locs):
    """Object visible → EXAMINE"""
    if not objects:
        return scenario_mundane_wait(being, loc, entities, objects, heard, avail_locs)
    target = random.choice(objects)

    thoughts = [
        f"The {target['name']} looks {target['state']}. Should take a closer look.",
        f"Need to check on the {target['name']}.",
        f"Haven't inspected the {target['name']} in a while.",
    ]
    if target["state"] in OBJECT_STATES_BROKEN:
        thoughts = [
            f"The {target['name']} is {target['state']}. That's a problem.",
            f"Something's wrong with the {target['name']}. Need to check it.",
        ]
    if being.thought_style == "terse":
        thoughts = [f"{target['name']}. Sniff. Check.", f"Object. Interesting. Look."]
    return (style_thought(random.choice(thoughts), being),
            f"EXAMINE {target['name']}", None, "cognitive")


def scenario_threat_flee(being, loc, entities, objects, heard, avail_locs):
    """Threat → FLEE FROM entity"""
    if not entities:
        return scenario_mundane_wait(being, loc, entities, objects, heard, avail_locs)
    # Pick the "scariest" entity (prefer Player or distant ones)
    target = random.choice(entities)

    thoughts = [
        f"{target['name']} looks dangerous. I need to get out of here.",
        f"Something about {target['name']} feels wrong. Not safe.",
        f"Don't like this. {target['name']} is too close. Run.",
    ]
    if being.thought_style == "terse":
        thoughts = [
            f"Danger! {target['name']}! Run!",
            f"{target['name']}. Threat. Flee!",
        ]
    elif being.thought_style == "sparse":
        thoughts = [f"The presence... {target['name']}... danger. Withdraw."]
    return (style_thought(random.choice(thoughts), being),
            f"FLEE FROM {target['name']}", {"safety": random.randint(20, 40)}, "negative")


def scenario_say_general(being, loc, entities, objects, heard, avail_locs):
    """Say something (no target)"""
    if not being.can_speak:
        # Animals: behavioral expression
        expressions = [
            "*growls softly*", "*whimpers*", "*purrs contentedly*",
            "*howls*", "*chirps*", "*squeaks nervously*",
            "*wags tail*", "*hisses*", "*stamps hoof*",
        ]
        thoughts = ["Express.", "Feel something. Show.", "Sound."]
        return (style_thought(random.choice(thoughts), being),
                f'SAY "{random.choice(expressions)}"', None, "positive")

    utterances = [
        "Hmm, quiet day.", "Nice weather for once.", "Back to work.",
        "Wonder what time it is.", "Could use a drink.",
        "Another day, another coin.", "Hope the road stays clear.",
    ]
    thoughts = [
        "Thinking out loud. Just a passing thought.",
        "Something on my mind.",
        "Can't help but mutter.",
    ]
    return (style_thought(random.choice(thoughts), being),
            f'SAY "{random.choice(utterances)}"', None, "positive")


def scenario_say_to(being, loc, entities, objects, heard, avail_locs):
    """Say something TO a visible entity"""
    if not entities:
        return scenario_say_general(being, loc, entities, objects, heard, avail_locs)
    target = random.choice(entities)

    if not being.can_speak:
        expressions = [
            f"*approaches {target['name']} cautiously, sniffs*",
            f"*wags tail at {target['name']}*",
            f"*growls at {target['name']}, baring teeth*",
            f"*purrs and rubs against {target['name']}'s leg*",
        ]
        thoughts = [f"{target['name']}. React.", f"Show {target['name']}."]
        return (style_thought(random.choice(thoughts), being),
                f'SAY "{random.choice(expressions)}" TO {target["name"]}', None, "positive")

    utterances = [
        f"Morning, {target['name']}.",
        f"Good to see you, {target['name']}.",
        f"Everything alright, {target['name']}?",
        f"Need anything, {target['name']}?",
        f"Watch yourself out there.",
        f"Have you been to the market today?",
        f"I've been meaning to ask you something.",
        f"Busy day?",
    ]
    thoughts = [
        f"{target['name']} is right there. Should say hello.",
        f"Want to check in with {target['name']}.",
        f"Haven't greeted {target['name']} yet today.",
    ]
    return (style_thought(random.choice(thoughts), being),
            f'SAY "{random.choice(utterances)}" TO {target["name"]}',
            {"social": random.randint(40, 75)}, "positive")


def scenario_go_to_entity(being, loc, entities, objects, heard, avail_locs):
    """Move toward a specific visible entity"""
    if not entities:
        return scenario_social_go(being, loc, entities, objects, heard, avail_locs)
    target = random.choice(entities)

    thoughts = [
        f"I need to talk to {target['name']}. They're over there.",
        f"{target['name']} might know something. Should go find out.",
        f"Been looking for {target['name']}. There they are.",
    ]
    if being.thought_style == "terse":
        thoughts = [f"{target['name']}. Need. Go to.", f"Find {target['name']}. Important."]
    return (style_thought(random.choice(thoughts), being),
            f"GO TO {target['name']}", None, "cognitive")


def scenario_look_at_object(being, loc, entities, objects, heard, avail_locs):
    """Look at a visible object"""
    if not objects:
        return scenario_mundane_wait(being, loc, entities, objects, heard, avail_locs)
    target = random.choice(objects)

    thoughts = [
        f"The {target['name']} catches my eye. What's its condition?",
        f"Should keep an eye on the {target['name']}.",
        f"Glancing at the {target['name']}. Looks {target['state']}.",
    ]
    if being.thought_style == "terse":
        thoughts = [f"{target['name']}. Look.", f"Check {target['name']}."]
    return (style_thought(random.choice(thoughts), being),
            f"LOOK AT {target['name']}", None, "cognitive")


def scenario_go_to_work(being, loc, entities, objects, heard, avail_locs):
    """Go to work location"""
    work_locs = [l for l in being.work_locations if l in avail_locs and l != loc]
    if not work_locs:
        return scenario_mundane_wait(being, loc, entities, objects, heard, avail_locs)
    target = random.choice(work_locs)

    thoughts = [
        f"Time to get back to work. Should head to the {target}.",
        f"Enough dawdling. The {target} isn't going to run itself.",
        f"Work calls. Need to be at the {target}.",
    ]
    if being.thought_style == "terse":
        thoughts = [f"Work. Go. {target}.", f"Duty. {target}. Now."]
    return (style_thought(random.choice(thoughts), being),
            f"GO TO {target}", None, "positive")


def scenario_conflicting_drives(being, loc, entities, objects, heard, avail_locs):
    """Two drives competing → resolves one way or another"""
    # Hungry but on task
    if random.random() < 0.5:
        food_locs = [l for l in FOOD_LOCATIONS if l in avail_locs and l != loc]
        if food_locs:
            target = random.choice(food_locs)
            # Sometimes push through, sometimes give in
            if random.random() < 0.5:
                thoughts = [
                    "Hungry, but I need to finish this first. Can eat later.",
                    "Stomach is growling but this task won't finish itself.",
                ]
                return (style_thought(random.choice(thoughts), being),
                        "WAIT", {"hunger": random.randint(55, 75)}, "negative")
            else:
                thoughts = [
                    "Can't focus anymore. Too hungry. The work can wait.",
                    "Need food now. Everything else can wait.",
                ]
                return (style_thought(random.choice(thoughts), being),
                        f"GO TO {target}", {"hunger": random.randint(70, 90)}, "negative")

    # Social but tired
    social_locs = [l for l in SOCIAL_LOCATIONS if l in avail_locs and l != loc]
    if social_locs:
        if random.random() < 0.5:
            thoughts = [
                "Lonely, but too tired to go looking for company.",
                "Wish someone were here, but I can barely stand.",
            ]
            return (style_thought(random.choice(thoughts), being),
                    "WAIT", {"social": random.randint(65, 85), "energy": random.randint(15, 30)}, "negative")
        else:
            target = random.choice(social_locs)
            thoughts = [
                "Tired, but I'll go crazy alone. Need people more than sleep right now.",
            ]
            return (style_thought(random.choice(thoughts), being),
                    f"GO TO {target}",
                    {"social": random.randint(75, 90), "energy": random.randint(20, 35)}, "negative")

    return scenario_mundane_wait(being, loc, entities, objects, heard, avail_locs)


# ─── Weighted scenario selection ────────────────────────────────────────────

SCENARIO_WEIGHTS = [
    (scenario_mundane_wait,       15),
    (scenario_mundane_wander,     15),
    (scenario_hunger_go,           8),
    (scenario_tired_go,            5),
    (scenario_social_approach,     7),
    (scenario_social_go,           5),
    (scenario_curiosity_look,     10),
    (scenario_examine,             7),
    (scenario_threat_flee,         5),
    (scenario_say_general,         4),
    (scenario_say_to,              6),
    (scenario_go_to_entity,        5),
    (scenario_look_at_object,      3),
    (scenario_go_to_work,          7),
    (scenario_conflicting_drives,  5),
]

SCENARIO_FNS = [s[0] for s in SCENARIO_WEIGHTS]
SCENARIO_W = [s[1] for s in SCENARIO_WEIGHTS]


# ─── Example generator ──────────────────────────────────────────────────────

def generate_example():
    """Generate a single adventure-command training example."""
    being = random.choice(BEINGS)
    location = random.choice(being.work_locations + [being.home])
    activity = random.choice(being.activities)

    # Build perception
    entities = pick_visible_entities(being.name if being.category == "human" else "", location)
    objects = pick_visible_objects(location)
    heard = pick_heard(entities)
    avail_locs = pick_available_locations(location, being)
    recent = pick_recent_events()

    # Pick scenario
    scenario_fn = random.choices(SCENARIO_FNS, weights=SCENARIO_W, k=1)[0]
    think_text, command, drive_overrides, mood_valence = scenario_fn(
        being, location, entities, objects, heard, avail_locs
    )

    # Generate drives
    drives = rand_drives(drive_overrides)
    mood = rand_mood(mood_valence)

    # Generate context fields
    goals = ["none", "none", activity, f"finish {activity}"]
    goal = random.choice(goals)
    belief_options = ["none", "none", "none"]
    for e in entities:
        belief_options.append(f"{e['name']} is trustworthy (0.6)")
    beliefs = random.choice(belief_options)

    last_thoughts = ["none", "none", "Quiet day so far.", "Need to stay focused.",
                     "Should check in with someone later."]
    last_thought = random.choice(last_thoughts)

    # Build user message
    header = (
        f"BEING: {being.name}\n"
        f"DRIVES: {fmt_drives(drives)}\n"
        f"MOOD: {mood}\n"
        f"LOCATION: {location}\n"
        f"DOING: {activity}\n\n"
    )
    perception = fmt_perception(
        entities, objects, heard, recent, avail_locs, goal, beliefs, last_thought
    )
    user_content = header + perception

    # Build assistant message
    assistant_content = f"<think>\n{think_text}\n</think>\n{command}"

    return {
        "messages": [
            {"role": "system", "content": SYSTEM_MSG},
            {"role": "user", "content": user_content},
            {"role": "assistant", "content": assistant_content},
        ]
    }


def validate_example(example):
    """Check that command nouns appear in the user message."""
    user = example["messages"][1]["content"]
    assistant = example["messages"][2]["content"]

    # Extract command line
    lines = assistant.split("\n")
    cmd_line = ""
    past_think = False
    for line in lines:
        if "</think>" in line:
            past_think = True
            continue
        if past_think and line.strip():
            cmd_line = line.strip()
            break

    if not cmd_line:
        return True  # no command to validate

    # Extract nouns from command
    # Simple: check that any multi-word capitalized sequences or quoted text appear in context
    # Entity/location names after TO/FROM/AT/APPROACH or in LOOK AT / EXAMINE
    import re
    # Find the noun part (after the verb phrase)
    noun_patterns = [
        r"GO TO (.+)$",
        r"LOOK AT (.+)$",
        r"EXAMINE (.+)$",
        r"FLEE FROM (.+)$",
        r"APPROACH (.+)$",
        r"WANDER AT (.+)$",
        r'SAY ".*?" TO (.+)$',
    ]
    for pat in noun_patterns:
        m = re.match(pat, cmd_line)
        if m:
            noun = m.group(1).strip()
            # Check noun appears in user message
            if noun not in user:
                return False
    return True


def generate_batch(count, output_file):
    """Generate a batch of training examples."""
    examples = []
    retries = 0
    while len(examples) < count and retries < count * 3:
        ex = generate_example()
        if validate_example(ex):
            examples.append(ex)
        else:
            retries += 1  # discard and retry

    with open(output_file, "w") as f:
        for ex in examples:
            f.write(json.dumps(ex) + "\n")

    print(f"Generated {len(examples)} examples → {output_file}")
    print(f"  ({retries} examples discarded for grounding violations)")

    # Distribution check
    import re as _re
    cmd_counts = {}
    for ex in examples:
        assistant = ex["messages"][2]["content"]
        m = _re.search(r"</think>\n(.+)", assistant)
        if m:
            cmd_line = m.group(1).strip()
            verb = cmd_line.split()[0] if cmd_line.split() else "?"
            if verb == "GO":
                verb = "GO TO"
            elif verb == "LOOK":
                verb = "LOOK AT"
            elif verb == "FLEE":
                verb = "FLEE FROM"
            elif verb == "WANDER" and "AT" in cmd_line:
                verb = "WANDER AT"
            cmd_counts[verb] = cmd_counts.get(verb, 0) + 1

    print("  Command distribution:")
    for cmd, n in sorted(cmd_counts.items(), key=lambda x: -x[1]):
        pct = n / len(examples) * 100
        print(f"    {cmd:15s} {n:4d} ({pct:.1f}%)")

    return len(examples)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python generate_command_training.py <count> <output_file>")
        print("  count: number of examples (target 3000)")
        print("  output_file: path to output JSONL file")
        sys.exit(1)

    count = int(sys.argv[1])
    output_file = sys.argv[2]
    generate_batch(count, output_file)
