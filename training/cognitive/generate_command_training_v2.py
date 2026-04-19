#!/usr/bin/env python3
"""
Adventure-command training data generator v2 — setting-agnostic.

Goals vs v1:
  * Cover all 23 verbs (incl. TOUCH, INTERACT WITH, WATCH, LISTEN TO,
    FOLLOW, POINT AT, OFFER, SHOW, REST, HIDE).
  * Use somatic-tag prompt format matching production (chest:tight,
    gut:hollow, body:settled — not raw drive floats).
  * Inventory-aware: every example carries a Carrying / Available here
    block so OFFER / SHOW / TAKE / CONSUME ground correctly.
  * Setting-agnostic: large diverse pools of names, locations, objects,
    items so the model learns the verbs, not a specific world.

Output: OpenAI-style messages JSONL, same schema the existing trainer
consumes. Shuffle separately if needed.
"""

import json
import random
import re
import sys

random.seed(7)

SYSTEM_MSG = (
    "You are the mind of a simulated being. You receive your state and "
    "perceptions, think about your situation, then choose one action. "
    "Think inside <think></think> tags, then output exactly one command."
)

# ─── Diverse pools (no single setting) ──────────────────────────────────────

# 60+ generic-feeling locations spanning indoor/outdoor/social/wilderness.
LOCATION_POOL = [
    # village / settlement
    "market", "town_square", "plaza", "well", "fountain", "courtyard",
    "bakery", "inn", "smithy", "stable", "mill", "chapel", "library",
    "guard_post", "watchtower", "north_gate", "south_gate", "west_gate",
    "back_alley", "lantern_row", "old_quarter",
    # interior
    "hearth_room", "great_hall", "kitchen", "loft", "cellar", "storeroom",
    "workshop", "common_room", "antechamber", "side_chamber",
    # outdoor / wild
    "forest_clearing", "riverbank", "stone_bridge", "hilltop", "cliff_edge",
    "valley_floor", "ridge_path", "old_road", "wheat_field", "orchard",
    "shoreline", "pier", "campsite", "lookout", "spring", "ford",
    "crossroads", "north_road", "east_road", "moor_edge", "bog_path",
    # interstitial / liminal
    "threshold", "porch", "balcony", "stairwell", "passage", "vestibule",
    # dwellings
    "home_one", "home_two", "home_three", "home_four", "home_five",
]

# 80+ diverse names — multicultural-feeling, no real-world demographics targeted.
ENTITY_POOL = [
    "Mara", "Theron", "Nia", "Sten", "Ilse", "Roan", "Vesna", "Cato",
    "Briar", "Halis", "Otra", "Pell", "Kai", "Rhea", "Ondo", "Lien",
    "Vance", "Yara", "Mosk", "Dela", "Ester", "Galen", "Mira", "Tovi",
    "Ash", "Bren", "Cael", "Doro", "Edda", "Finn", "Gaia", "Hess",
    "Ira", "Joss", "Kell", "Lir", "Nim", "Olen", "Pria", "Quill",
    "Roe", "Sela", "Tark", "Una", "Vey", "Wren", "Yel", "Zara",
    "Aldric", "Edith", "Felix", "Greta", "Hugo", "Ivy", "Mabel", "Roland",
    "Player", "Stranger", "Traveler", "Merchant", "Courier", "Healer",
    "Guard", "Child", "Elder", "Drifter", "Scout", "Hunter",
]

# Object templates: (name, kind, default_state, tactile, affordance_role)
# kind: tool / vessel / fixture / surface / signal / supply / instrument
# tactile: warm / cold / smooth / rough / soft / hard / dry / damp / sharp / pliant
# affordance_role: warmth / drink / read / write / cook / craft / signal / store / sit / lock
OBJECT_POOL = [
    # heat sources
    ("Brick Oven", "fixture", "lit", "warm", "warmth"),
    ("Iron Brazier", "fixture", "lit", "warm", "warmth"),
    ("Open Hearth", "fixture", "burning", "warm", "warmth"),
    ("Forge", "fixture", "hot", "warm", "craft"),
    ("Tile Stove", "fixture", "warm", "warm", "warmth"),
    ("Coal Pan", "vessel", "smouldering", "warm", "warmth"),
    # water / drink
    ("Stone Basin", "vessel", "filled", "cold", "drink"),
    ("Well Bucket", "tool", "ready", "cold", "drink"),
    ("Water Trough", "vessel", "full", "cold", "drink"),
    ("Clay Jug", "vessel", "full", "cold", "drink"),
    ("Copper Kettle", "vessel", "warm", "warm", "drink"),
    ("Reed Cistern", "vessel", "half", "cold", "drink"),
    # text / signal
    ("Guest Ledger", "instrument", "open", "smooth", "read"),
    ("Notice Board", "fixture", "posted", "rough", "read"),
    ("Wall Map", "fixture", "marked", "smooth", "read"),
    ("Tally Board", "instrument", "marked", "rough", "read"),
    ("Brass Bell", "instrument", "still", "cold", "signal"),
    ("Signal Lantern", "instrument", "lit", "warm", "signal"),
    ("Watchhorn", "instrument", "ready", "smooth", "signal"),
    # tools / craft
    ("Anvil", "fixture", "ready", "cold", "craft"),
    ("Mortar and Pestle", "tool", "ready", "cold", "craft"),
    ("Plow", "tool", "ready", "rough", "craft"),
    ("Loom", "tool", "threaded", "smooth", "craft"),
    ("Carding Comb", "tool", "ready", "rough", "craft"),
    ("Whetstone", "tool", "dry", "rough", "craft"),
    ("Drying Rack", "fixture", "loaded", "dry", "store"),
    # surfaces / sit / rest
    ("Long Bench", "surface", "empty", "smooth", "sit"),
    ("Low Stool", "surface", "empty", "smooth", "sit"),
    ("Reed Mat", "surface", "laid", "soft", "sit"),
    ("Stone Step", "surface", "cool", "cold", "sit"),
    ("Pile of Furs", "surface", "heaped", "soft", "sit"),
    # storage
    ("Flour Sacks", "supply", "full", "soft", "store"),
    ("Grain Bin", "vessel", "full", "rough", "store"),
    ("Salt Box", "vessel", "half", "dry", "store"),
    ("Herb Shelf", "fixture", "stocked", "dry", "store"),
    ("Trade Crate", "vessel", "sealed", "rough", "store"),
    ("Ale Barrel", "vessel", "tapped", "damp", "store"),
    ("Pantry", "fixture", "stocked", "smooth", "store"),
    # signals/atmosphere
    ("Wind Chime", "instrument", "still", "cold", "signal"),
    ("Stone Idol", "fixture", "weathered", "cold", "signal"),
    ("Carved Post", "fixture", "marked", "rough", "signal"),
    # tactile-rich
    ("Velvet Cloak", "supply", "folded", "soft", "store"),
    ("Iron Chain", "supply", "coiled", "cold", "lock"),
    ("Leather Strap", "supply", "supple", "soft", "craft"),
    ("Glass Lantern", "instrument", "lit", "warm", "warmth"),
    ("Bronze Mirror", "fixture", "polished", "cold", "read"),
    ("Wooden Trunk", "vessel", "closed", "smooth", "store"),
]

# Carryable item templates: (name, category, tactile, drive_effect_when_consumed)
ITEM_POOL = [
    ("Bread", "food", "warm", "hunger:-30,energy:+5"),
    ("Apple", "food", "cool", "hunger:-20,energy:+5"),
    ("Cheese", "food", "cool", "hunger:-25,energy:+8"),
    ("Salted Meat", "food", "dry", "hunger:-35,energy:+10"),
    ("Hard Tack", "food", "dry", "hunger:-15,energy:+3"),
    ("Honey Cake", "food", "soft", "hunger:-25,energy:+10"),
    ("Pottage", "food", "warm", "hunger:-30,energy:+8"),
    ("Stew Bowl", "food", "warm", "hunger:-30,energy:+10"),

    ("Ale", "drink", "cool", "hunger:-10,energy:+12"),
    ("Spring Water", "drink", "cold", "hunger:-5,energy:+10"),
    ("Tea", "drink", "warm", "hunger:-5,energy:+12"),
    ("Wine", "drink", "cool", "hunger:-8,energy:+10"),

    ("Herbal Remedy", "medicine", "cool", "energy:+25,safety:+10"),
    ("Salve", "medicine", "soft", "energy:+15,safety:+10"),
    ("Bitter Tonic", "medicine", "cool", "energy:+20,safety:+5"),

    ("Coin Purse", "valuable", "cold", ""),
    ("Brass Key", "tool", "cold", ""),
    ("Folded Letter", "tool", "smooth", ""),
    ("Wax Tablet", "tool", "smooth", ""),
    ("Small Knife", "tool", "cold", ""),
    ("Tinder Box", "tool", "rough", ""),
    ("Carved Token", "valuable", "smooth", ""),
    ("Wool Scarf", "supply", "soft", ""),
    ("Spare Bowl", "supply", "smooth", ""),
]

# Roles — abstract, not tied to a single setting
ROLE_POOL = [
    "wanderer", "watcher", "trader", "tracker", "messenger", "tender",
    "healer", "smith", "baker", "scribe", "guard", "drifter", "scout",
    "innkeeper", "farmer", "courier", "herbalist", "novice", "elder",
    "child", "hunter", "fisher", "weaver", "carter", "boatwright",
]

# Activities — neutral verbs, fits any role
ACTIVITY_POOL = [
    "tending the hearth", "checking supplies", "watching the road",
    "thinking", "stretching", "pacing", "looking around", "wiping a counter",
    "winding a strap", "counting coins", "scanning the horizon", "listening",
    "drawing breath", "shaking off sleep", "warming hands", "looking out",
    "settling in", "fidgeting", "brushing dirt off", "gathering thoughts",
    "rolling shoulders", "rubbing eyes", "stepping carefully", "making tea",
]

DIRECTIONS = ["north", "south", "east", "west",
              "northeast", "northwest", "southeast", "southwest"]

# ─── Drives → somatic tags ──────────────────────────────────────────────────

def rand_drives(overrides=None):
    d = {
        "energy": random.randint(20, 90),
        "hunger": random.randint(10, 90),
        "social": random.randint(15, 90),
        "safety": random.randint(35, 95),
    }
    if overrides:
        d.update(overrides)
    return d


def somatic_tags_from_drives(d):
    """Synthesize plausible somatic tag swarm from drive floats.

    Goal is realism, not ground-truth — the actual Hebbian network
    will produce richer, more individuated tags. Training just needs
    co-activation patterns the model can read."""
    e, h, s, sf = d["energy"], d["hunger"], d["social"], d["safety"]
    tags: list[str] = []

    # Energy
    if e < 25:
        tags += ["muscles:heavy", "head:foggy", "body:sluggish"]
    elif e < 45:
        tags += ["muscles:heavy"]
    elif e > 75:
        tags += ["head:clear", "body:light"]

    # Hunger
    if h > 80:
        tags += ["gut:gnawing", "gut:hollow", "throat:dry"]
    elif h > 60:
        tags += ["gut:hollow"]
    elif h < 25:
        tags += ["gut:settled"]

    # Social
    if s > 75:
        tags += ["chest:hollow", "body:yearning"]
    elif s > 55:
        tags += ["chest:hollow"]
    elif s < 25:
        tags += ["chest:warm"]

    # Safety / threat
    if sf < 30:
        tags += ["chest:tight", "skin:prickling", "throat:tight",
                 "muscles:coiled", "head:pounding"]
    elif sf < 45:
        tags += ["chest:tight", "skin:prickling"]
    elif sf > 80:
        tags += ["chest:open", "body:settled"]

    if not tags:
        tags = ["body:settled"]

    # De-dup, preserve order
    seen, out = set(), []
    for t in tags:
        if t not in seen:
            seen.add(t)
            out.append(t)

    # Cap length
    return out[:6]


# ─── Perception assembly ────────────────────────────────────────────────────

def pick_n(pool, n):
    return random.sample(pool, min(n, len(pool)))


def maybe_pick_entities(self_name, n_min=0, n_max=3):
    n = random.randint(n_min, n_max)
    if n == 0:
        return []
    candidates = [e for e in ENTITY_POOL if e != self_name]
    chosen = random.sample(candidates, min(n, len(candidates)))
    activities = [
        "walking", "standing", "sitting", "working", "talking", "looking around",
        "leaning on a wall", "writing", "watching", "carrying something",
        "moving slowly", "standing still",
    ]
    out = []
    for name in chosen:
        out.append({
            "name": name,
            "distance": random.randint(1, 8),
            "direction": random.choice(DIRECTIONS),
            "activity": random.choice(activities),
        })
    return out


def maybe_pick_objects(n_min=0, n_max=3):
    n = random.randint(n_min, n_max)
    if n == 0:
        return []
    chosen = random.sample(OBJECT_POOL, n)
    out = []
    for tpl in chosen:
        name, kind, default_state, tactile, role = tpl
        # 80% default state, 20% non-default ("broken", "empty", "shut")
        state = default_state
        if random.random() < 0.2:
            state = random.choice(["empty", "broken", "shut", "still", "low"])
        out.append({
            "name": name, "kind": kind, "state": state,
            "tactile": tactile, "role": role,
        })
    return out


def maybe_pick_carrying(n_min=0, n_max=4, ensure=None):
    n = random.randint(n_min, n_max)
    items = []
    if ensure:
        items.append(ensure)
        n -= 1
    pool = [t for t in ITEM_POOL if not ensure or t[0] != ensure[0]]
    if n > 0:
        items += random.sample(pool, min(n, len(pool)))
    return items


def maybe_pick_available_here(location_kind, n_min=0, n_max=3, ensure=None):
    """Items lying here at this location (not in inventory)."""
    n = random.randint(n_min, n_max)
    items = []
    if ensure:
        items.append(ensure)
        n -= 1
    pool = [t for t in ITEM_POOL if not ensure or t[0] != ensure[0]]
    if n > 0:
        items += random.sample(pool, min(n, len(pool)))
    return items


def pick_known_locations(current, n_min=4, n_max=8):
    n = random.randint(n_min, n_max)
    others = [l for l in LOCATION_POOL if l != current]
    return [current] + random.sample(others, min(n - 1, len(others)))


def pick_glimpsed(n_min=0, n_max=2):
    n = random.randint(n_min, n_max)
    if n == 0:
        return []
    out = []
    for _ in range(n):
        out.append({
            "direction": random.choice(["north", "south", "east", "west"]),
            "distance_tiles": random.randint(6, 14),
        })
    return out


def pick_heard(n_min=0, n_max=2):
    n = random.randint(n_min, n_max)
    if n == 0:
        return []
    snippets = [
        "Have you seen them?", "Quiet today.", "Watch the gate.",
        "It's late.", "Footsteps over there.", "Smells like smoke.",
        "Help — over here!", "Step lightly.", "Did you hear that?",
        "Cold tonight.", "*muttering*", "*footsteps*",
        "*soft humming*", "*a low laugh*", "*coughing*",
    ]
    out = []
    for _ in range(n):
        out.append({
            "source": random.choice(ENTITY_POOL + ["someone", "a voice"]),
            "text": random.choice(snippets),
            "distance": random.randint(2, 7),
            "direction": random.choice(DIRECTIONS),
        })
    return out


def pick_recent_events(entities, objects, n_min=0, n_max=3):
    n = random.randint(n_min, n_max)
    if n == 0:
        return []
    pool = [
        "Quiet stretch — nothing notable.",
        "Heard a distant sound, then silence.",
        "Felt the wind shift.",
        "Walked past the threshold.",
        "Noticed the light changing.",
    ]
    if entities:
        e = random.choice(entities)["name"]
        pool += [
            f"Crossed paths with {e}.",
            f"Saw {e} earlier.",
            f"Heard {e}'s voice.",
        ]
    if objects:
        o = random.choice(objects)["name"]
        pool += [
            f"Glanced at the {o}.",
            f"The {o} is on my mind.",
        ]
    return random.sample(pool, min(n, len(pool)))


# ─── Prompt formatting ──────────────────────────────────────────────────────

def fmt_perception(*, role, location, activity, somatic_tags, carrying,
                   available_here, entities, objects, heard, recent_events,
                   known_locations, glimpsed, last_thought, goal, beliefs):
    """Match production prompt format from server/command_model.py.

    Production merges entities + objects into a single 'You see:' bulleted
    list, uses 'You are in:' / 'You are:' / 'You are carrying:' / 'Within
    reach:' wording, and uses 'silence' / 'nothing of note' as natural-language
    fallbacks. Keep this aligned or training won't transfer.
    """
    feel_str = ", ".join(somatic_tags) if somatic_tags else "body:settled"
    carry_str = ", ".join(t[0] for t in carrying) if carrying else "(nothing)"
    avail_str = ", ".join(t[0] for t in available_here) if available_here else ""

    # Merged sight list — entities lead, then objects with "a <name>" prose
    see_lines = []
    for v in entities[:6]:
        see_lines.append(
            f"  - {v['name']}, {v['distance']} tiles {v['direction']}, {v['activity']}"
        )
    for o in objects[:4]:
        s = f" ({o['state']})" if o.get("state") else ""
        # Approximate distance for objects (production uses real distance — we
        # synthesise a plausible one for training)
        dist = random.randint(1, 6)
        see_lines.append(f"  - a {o['name']}{s}, {dist} tiles away")
    see_str = "\n".join(see_lines) if see_lines else "  - nothing of note"

    hear_lines = []
    for h in heard[:3]:
        hear_lines.append(
            f"  - {h['source']}: \"{h['text']}\" ({h['distance']} tiles {h['direction']})"
        )
    hear_str = "\n".join(hear_lines) if hear_lines else "  - silence"

    events_str = "; ".join(recent_events) if recent_events else "Nothing notable."
    places_str = ", ".join(known_locations) if known_locations else "(nowhere yet)"

    glimpse_parts = []
    for g in glimpsed:
        dist_label = "close" if g["distance_tiles"] < 8 else "far"
        glimpse_parts.append(f"building ({g['direction']}, {dist_label})")
    glimpse_str = ", ".join(glimpse_parts) if glimpse_parts else ""

    has_carried = len(carrying) > 0
    has_available = len(available_here) > 0
    has_entities = len(entities) > 0
    has_objects = len(objects) > 0

    cmd_line = (
        "Commands: GO TO place, LOOK AT target, SAY \"words\" TO target, "
        "APPROACH target, FLEE FROM target, EXAMINE object, WANDER, WAIT, "
        "REST, HIDE"
    )
    if has_entities:
        cmd_line += ", WATCH person, FOLLOW person, LISTEN TO person"
    if has_objects or has_entities:
        cmd_line += ", TOUCH target, INTERACT WITH object, POINT AT target"
    if has_carried or has_available:
        cmd_line += ", TAKE item, CONSUME item, DROP item"
    if has_carried and has_entities:
        cmd_line += ", GIVE item TO person, OFFER item TO person, SHOW item TO person"

    return (
        f"BEING: {role}\n"
        f"You are in: {location}\n"
        f"You are: {activity}\n"
        f"\n"
        f"You feel: {feel_str}\n"
        f"You are carrying: {carry_str}\n"
        f"{f'Within reach: {avail_str}' + chr(10) if avail_str else ''}"
        f"\n"
        f"You see:\n{see_str}\n"
        f"You hear:\n{hear_str}\n"
        f"\n"
        f"Recent: {events_str}\n"
        f"Goal: {goal}\n"
        f"Beliefs: {beliefs}\n"
        f"Last thought: {last_thought}\n"
        f"\n"
        f"Known places: {places_str}\n"
        f"{f'You can see: {glimpse_str}' + chr(10) if glimpse_str else ''}"
        f"\n"
        f"{cmd_line}\n"
        f"\n"
        f"TOUCH grounds the body — felt warmth, cold, texture. INTERACT engages "
        f"an object's purpose (well, oven, ledger). OFFER presents an item; the "
        f"other can accept or refuse. SHOW displays without giving. REST recovers "
        f"energy but lowers guard. HIDE breaks visibility.\n"
        f"\n"
        f"Think about your situation, then choose ONE action."
    )


# ─── Scenario primitives ────────────────────────────────────────────────────
# Each scenario returns dict: {think, command, drives, entities, objects,
#                              carrying, available_here, location, activity, role}

def _base_context(*, drive_overrides=None, want_entities=False, want_objects=False,
                  ensure_carrying=None, ensure_available=None, want_threat=False,
                  want_safety=False):
    role = random.choice(ROLE_POOL)
    location = random.choice(LOCATION_POOL)
    activity = random.choice(ACTIVITY_POOL)

    # Pre-pick known_locations so scenarios can reuse the same set when they
    # need a target name that must appear in the perception block.
    known = pick_known_locations(location, 4, 8)

    drives = rand_drives(drive_overrides)
    if want_threat and drives["safety"] > 40:
        drives["safety"] = random.randint(15, 40)
    if want_safety and drives["safety"] < 70:
        drives["safety"] = random.randint(75, 95)

    entity_min = 1 if want_entities else 0
    object_min = 1 if want_objects else 0
    entities = maybe_pick_entities(role, n_min=entity_min, n_max=3)
    objects = maybe_pick_objects(n_min=object_min, n_max=3)
    carrying = maybe_pick_carrying(n_min=0, n_max=3, ensure=ensure_carrying)
    available_here = maybe_pick_available_here(
        location, n_min=0, n_max=2, ensure=ensure_available
    )

    return {
        "role": role, "location": location, "activity": activity,
        "drives": drives, "entities": entities, "objects": objects,
        "carrying": carrying, "available_here": available_here,
        "known_locations": known,
    }


def _build_example(ctx, think, command):
    drives = ctx["drives"]
    somatic = somatic_tags_from_drives(drives)
    entities = ctx["entities"]
    objects = ctx["objects"]

    user = fmt_perception(
        role=ctx["role"], location=ctx["location"], activity=ctx["activity"],
        somatic_tags=somatic, carrying=ctx["carrying"],
        available_here=ctx["available_here"], entities=entities, objects=objects,
        heard=pick_heard(0, 2),
        recent_events=pick_recent_events(entities, objects, 0, 2),
        known_locations=ctx["known_locations"],
        glimpsed=pick_glimpsed(0, 2),
        last_thought=random.choice([
            "none", "none", "Quiet so far.", "Need to keep moving.",
            "Something doesn't sit right.", "Stay alert.",
            "Could rest if it stays this calm.",
        ]),
        goal=random.choice(["none", "none", ctx["activity"], f"finish {ctx['activity']}"]),
        beliefs="none",
    )
    asst = f"<think>\n{think}\n</think>\n{command}"

    return {"messages": [
        {"role": "system", "content": SYSTEM_MSG},
        {"role": "user", "content": user},
        {"role": "assistant", "content": asst},
    ]}


# ─── Verb scenarios ─────────────────────────────────────────────────────────

# === EXISTING VERBS ===

def s_wait(_):
    ctx = _base_context()
    thoughts = [
        "Nothing pressing. Hold the moment.",
        "All quiet. Just be.",
        "Nothing demands a move. Wait.",
        "Settling. No need to act.",
    ]
    return _build_example(ctx, random.choice(thoughts), "WAIT")


def s_wander(_):
    ctx = _base_context()
    thoughts = [
        "Restless. Move a little.",
        "Could use a turn around.",
        "Need to stretch the legs.",
    ]
    options = [l for l in ctx["known_locations"] if l != ctx["location"]]
    if random.random() < 0.5 and options:
        target = random.choice(options)
        cmd = f"WANDER AT {target}"
    else:
        cmd = "WANDER"
    return _build_example(ctx, random.choice(thoughts), cmd)


def s_go_to(_):
    ctx = _base_context()
    options = [l for l in ctx["known_locations"] if l != ctx["location"]]
    if not options:
        # Fallback — extend known set so target is grounded
        ctx["known_locations"] = pick_known_locations(ctx["location"], 6, 10)
        options = [l for l in ctx["known_locations"] if l != ctx["location"]]
    target = random.choice(options)
    thoughts = [
        f"Need to get to {target}.",
        f"Time to head over to {target}.",
        f"{target.replace('_', ' ').title()} is where I should be.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"GO TO {target}")


def s_approach(_):
    ctx = _base_context(want_entities=True)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"{target['name']} is right there. Close the gap.",
        f"Want to get near {target['name']}.",
        f"Should step closer to {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"APPROACH {target['name']}")


def s_flee(_):
    ctx = _base_context(want_entities=True, want_threat=True)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"{target['name']} feels wrong. Get out.",
        f"Not safe. {target['name']} too close. Run.",
        f"Wrong wrong wrong — {target['name']} — leave now.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"FLEE FROM {target['name']}")


def s_look_at_entity(_):
    ctx = _base_context(want_entities=True)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"What's {target['name']} doing? Glance over.",
        f"Quick look at {target['name']}.",
        f"{target['name']} caught my eye.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"LOOK AT {target['name']}")


def s_look_at_object(_):
    ctx = _base_context(want_objects=True)
    target = random.choice(ctx["objects"])
    thoughts = [
        f"Glance at the {target['name']}.",
        f"Quick check on the {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"LOOK AT {target['name']}")


def s_examine(_):
    ctx = _base_context(want_objects=True)
    target = random.choice(ctx["objects"])
    cond = target["state"]
    thoughts = [
        f"The {target['name']} looks {cond}. Worth a closer look.",
        f"Need to study the {target['name']} carefully.",
        f"Something about the {target['name']} — examine it properly.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"EXAMINE {target['name']}")


def s_say_to(_):
    ctx = _base_context(want_entities=True,
                        drive_overrides={"social": random.randint(55, 85)})
    target = random.choice(ctx["entities"])
    utterances = [
        f"Hello, {target['name']}.",
        f"Good to see you, {target['name']}.",
        f"Quiet day, isn't it?",
        f"You alright?",
        f"What's the news?",
    ]
    thoughts = [
        f"{target['name']} is right there. Greet them.",
        f"Should say something to {target['name']}.",
    ]
    return _build_example(
        ctx, random.choice(thoughts),
        f'SAY "{random.choice(utterances)}" TO {target["name"]}',
    )


def s_say_general(_):
    ctx = _base_context()
    utterances = [
        "Quiet stretch.", "Cold today.", "Hmm.",
        "Could use a break.", "Long day.",
    ]
    thoughts = ["Thinking out loud.", "Just muttering."]
    return _build_example(
        ctx, random.choice(thoughts),
        f'SAY "{random.choice(utterances)}"',
    )


def s_explore(_):
    # Always have at least one glimpsed building so EXPLORE makes sense
    ctx = _base_context()
    direction = random.choice(["north", "south", "east", "west"])
    thoughts = [
        f"Something off to the {direction}. Worth a closer look.",
        f"Curious about that shape to the {direction}.",
    ]
    # Note: we can't easily inject glimpsed into _build_example w/o refactor;
    # the prompt will still include EXPLORE in cmd_line via has_glimpsed check
    # but for training we just teach the verb shape here.
    return _build_example(ctx, random.choice(thoughts), f"EXPLORE {direction}")


# === NEW VERBS ===

def s_touch_object(_):
    ctx = _base_context(want_objects=True)
    target = random.choice(ctx["objects"])
    tactile = target["tactile"]
    thoughts_by_tactile = {
        "warm": [f"Want to feel the {target['name']} — its warmth.",
                 f"Reach out — the {target['name']} should be warm."],
        "cold": [f"Press a hand to the {target['name']} — feel that cold.",
                 f"The {target['name']} will be cool. Touch it."],
        "smooth": [f"Run a hand along the {target['name']}.",
                   f"Feel the smooth of the {target['name']}."],
        "rough": [f"Brush the {target['name']} — feel the grain.",
                  f"Want to feel the texture of the {target['name']}."],
        "soft": [f"Press into the {target['name']}.",
                 f"The {target['name']} looks soft. Touch it."],
        "dry": [f"Touch the {target['name']} — feel the dry.",
                f"Crisp, dry — feel the {target['name']}."],
        "damp": [f"The {target['name']} looks damp. Confirm by hand."],
        "sharp": [f"Carefully — feel the edge of the {target['name']}."],
        "hard": [f"Knock the {target['name']} — feel the hardness."],
        "pliant": [f"Press the {target['name']} — feel it give."],
    }
    thoughts = thoughts_by_tactile.get(tactile, [f"Reach out, touch the {target['name']}."])
    return _build_example(ctx, random.choice(thoughts), f"TOUCH {target['name']}")


def s_touch_entity(_):
    ctx = _base_context(want_entities=True,
                        drive_overrides={"social": random.randint(55, 85)})
    target = random.choice(ctx["entities"])
    thoughts = [
        f"Reach out — touch {target['name']}'s arm. Show I'm here.",
        f"A hand on {target['name']}'s shoulder. That's the closeness I need.",
        f"Quietly — touch {target['name']}. Steady them.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"TOUCH {target['name']}")


def s_touch_item(_):
    """TOUCH an item available on the ground/surface here."""
    ensure = random.choice(ITEM_POOL)
    ctx = _base_context(ensure_available=ensure)
    target = ctx["available_here"][0]
    thoughts = [
        f"Pick up the {target[0]} — feel its weight.",
        f"The {target[0]} — lift it, feel the {target[2]}.",
        f"Reach for the {target[0]} — just to feel it.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"TOUCH {target[0]}")


def s_interact_drink(_):
    """INTERACT WITH a water/drink fixture when thirsty/hungry."""
    drink_objs = [o for o in OBJECT_POOL if o[4] == "drink"]
    chosen = random.choice(drink_objs)
    ctx = _base_context(
        drive_overrides={"hunger": random.randint(55, 85), "energy": random.randint(35, 60)},
    )
    # Force the chosen object into the visible set
    ctx["objects"] = [{
        "name": chosen[0], "kind": chosen[1], "state": chosen[2],
        "tactile": chosen[3], "role": chosen[4],
    }] + ctx["objects"][:2]
    target = ctx["objects"][0]
    thoughts = [
        f"Throat dry. Use the {target['name']} — drink.",
        f"Hungry, but water first. The {target['name']} is right there.",
        f"Need a drink. Work the {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"INTERACT WITH {target['name']}")


def s_interact_warmth(_):
    """INTERACT WITH a heat source when low energy / cold."""
    warm_objs = [o for o in OBJECT_POOL if o[4] == "warmth"]
    chosen = random.choice(warm_objs)
    ctx = _base_context(
        drive_overrides={"energy": random.randint(20, 45), "safety": random.randint(45, 70)},
    )
    ctx["objects"] = [{
        "name": chosen[0], "kind": chosen[1], "state": chosen[2],
        "tactile": chosen[3], "role": chosen[4],
    }] + ctx["objects"][:2]
    target = ctx["objects"][0]
    thoughts = [
        f"Warmth — the {target['name']}. Stand close, work the fire.",
        f"Cold seeping in. Tend the {target['name']}.",
        f"Tired. Warm by the {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"INTERACT WITH {target['name']}")


def s_interact_read(_):
    """INTERACT WITH a readable fixture when curious."""
    read_objs = [o for o in OBJECT_POOL if o[4] == "read"]
    chosen = random.choice(read_objs)
    ctx = _base_context(want_safety=True)
    ctx["objects"] = [{
        "name": chosen[0], "kind": chosen[1], "state": chosen[2],
        "tactile": chosen[3], "role": chosen[4],
    }] + ctx["objects"][:2]
    target = ctx["objects"][0]
    thoughts = [
        f"What does the {target['name']} say? Read it through.",
        f"The {target['name']} — see what's on it.",
        f"Take a moment — the {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"INTERACT WITH {target['name']}")


def s_interact_craft(_):
    """INTERACT WITH a tool/craft fixture (work-doing)."""
    craft_objs = [o for o in OBJECT_POOL if o[4] == "craft"]
    chosen = random.choice(craft_objs)
    ctx = _base_context()
    ctx["objects"] = [{
        "name": chosen[0], "kind": chosen[1], "state": chosen[2],
        "tactile": chosen[3], "role": chosen[4],
    }] + ctx["objects"][:2]
    target = ctx["objects"][0]
    thoughts = [
        f"Take up the {target['name']} — work it.",
        f"Time at the {target['name']}.",
        f"The {target['name']} needs my hands.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"INTERACT WITH {target['name']}")


def s_interact_signal(_):
    """INTERACT WITH a signal/instrument."""
    sig_objs = [o for o in OBJECT_POOL if o[4] == "signal"]
    chosen = random.choice(sig_objs)
    ctx = _base_context()
    ctx["objects"] = [{
        "name": chosen[0], "kind": chosen[1], "state": chosen[2],
        "tactile": chosen[3], "role": chosen[4],
    }] + ctx["objects"][:2]
    target = ctx["objects"][0]
    thoughts = [
        f"Strike the {target['name']} — let the sound carry.",
        f"Use the {target['name']}.",
        f"The {target['name']} — make it speak.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"INTERACT WITH {target['name']}")


def s_watch(_):
    ctx = _base_context(want_entities=True)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"{target['name']} doing something. Hold a long look.",
        f"Watch {target['name']} — see how this plays.",
        f"Lock eyes on {target['name']}. Don't look away.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"WATCH {target['name']}")


def s_listen_entity(_):
    ctx = _base_context(want_entities=True)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"{target['name']} said something. Listen close.",
        f"Tilt my ear toward {target['name']}.",
        f"Want to hear {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"LISTEN TO {target['name']}")


def s_listen_location(_):
    ctx = _base_context()
    options = [l for l in ctx["known_locations"] if l != ctx["location"]]
    if not options:
        return s_wait(None)
    target = random.choice(options)
    thoughts = [
        f"Sound coming from the {target.replace('_', ' ')}. Listen.",
        f"Quiet — listen to the {target.replace('_', ' ')}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"LISTEN TO {target}")


def s_follow(_):
    ctx = _base_context(want_entities=True)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"{target['name']} is moving. Follow.",
        f"Don't lose {target['name']} — go with them.",
        f"Where are they going? Follow {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"FOLLOW {target['name']}")


def s_point_at_object(_):
    ctx = _base_context(want_entities=True, want_objects=True)
    target = random.choice(ctx["objects"])
    thoughts = [
        f"That {target['name']} — show them. Point.",
        f"Catch their eye — point at the {target['name']}.",
        f"Direct attention to the {target['name']}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"POINT AT {target['name']}")


def s_point_at_entity(_):
    if random.random() < 0.5:
        return s_point_at_object(None)
    ctx = _base_context(want_entities=True, n_max=3)
    if len(ctx["entities"]) < 2:
        return s_point_at_object(None)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"Make the others see {target['name']}. Point at them.",
        f"Point at {target['name']} — they need to know.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"POINT AT {target['name']}")


def s_offer(_):
    ensure = random.choice(ITEM_POOL)
    ctx = _base_context(want_entities=True, ensure_carrying=ensure,
                        drive_overrides={"social": random.randint(40, 75)})
    item = ctx["carrying"][0]
    target = random.choice(ctx["entities"])
    thoughts = [
        f"Hold out the {item[0]} to {target['name']}. Their choice.",
        f"Offer the {item[0]} — they can take it or not.",
        f"{target['name']} might want this {item[0]}. Offer it.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"OFFER {item[0]} TO {target['name']}")


def s_show(_):
    ensure = random.choice(ITEM_POOL)
    ctx = _base_context(want_entities=True, ensure_carrying=ensure)
    item = ctx["carrying"][0]
    target = random.choice(ctx["entities"])
    thoughts = [
        f"Hold up the {item[0]} so {target['name']} can see.",
        f"Show {target['name']} the {item[0]} — without giving it.",
        f"Lift the {item[0]} — let {target['name']} look.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"SHOW {item[0]} TO {target['name']}")


def s_give(_):
    ensure = random.choice(ITEM_POOL)
    ctx = _base_context(want_entities=True, ensure_carrying=ensure)
    item = ctx["carrying"][0]
    target = random.choice(ctx["entities"])
    thoughts = [
        f"Hand the {item[0]} to {target['name']}.",
        f"{target['name']} should have this {item[0]}.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"GIVE {item[0]} TO {target['name']}")


def s_take(_):
    ensure = random.choice(ITEM_POOL)
    ctx = _base_context(ensure_available=ensure,
                        drive_overrides={"hunger": random.randint(50, 80)} if ensure[1] in ("food", "drink") else None)
    item = ctx["available_here"][0]
    thoughts = [
        f"Pick up the {item[0]}.",
        f"The {item[0]} — take it.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"TAKE {item[0]}")


def s_consume(_):
    food = [t for t in ITEM_POOL if t[1] in ("food", "drink", "medicine")]
    ensure = random.choice(food)
    drive_o = {}
    if ensure[1] == "food":
        drive_o["hunger"] = random.randint(60, 90)
    elif ensure[1] == "drink":
        drive_o["hunger"] = random.randint(30, 60)
        drive_o["energy"] = random.randint(30, 55)
    elif ensure[1] == "medicine":
        drive_o["energy"] = random.randint(20, 45)
        drive_o["safety"] = random.randint(35, 60)
    ctx = _base_context(ensure_carrying=ensure, drive_overrides=drive_o)
    item = ctx["carrying"][0]
    thoughts = [
        f"Eat the {item[0]}." if item[1] == "food" else
        f"Drink the {item[0]}." if item[1] == "drink" else
        f"Take the {item[0]}.",
        f"The {item[0]} — now.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"CONSUME {item[0]}")


def s_drop(_):
    ensure = random.choice(ITEM_POOL)
    ctx = _base_context(ensure_carrying=ensure)
    item = ctx["carrying"][0]
    thoughts = [
        f"Set the {item[0]} down.",
        f"Don't need the {item[0]} now. Drop it.",
    ]
    return _build_example(ctx, random.choice(thoughts), f"DROP {item[0]}")


def s_rest(_):
    ctx = _base_context(
        drive_overrides={"energy": random.randint(15, 35), "safety": random.randint(65, 90)},
        want_safety=True,
    )
    thoughts = [
        "Tired through. Settle here. Rest.",
        "Body is heavy. Need to stop.",
        "Safe enough — rest a moment.",
        "Pause. Let the heaviness pass.",
    ]
    return _build_example(ctx, random.choice(thoughts), "REST")


def s_hide(_):
    ctx = _base_context(want_entities=True, want_threat=True)
    target = random.choice(ctx["entities"])
    thoughts = [
        f"Don't let {target['name']} see me. Hide.",
        f"Get out of sight before {target['name']} turns.",
        f"Hold still, hidden — {target['name']} can't see me.",
    ]
    return _build_example(ctx, random.choice(thoughts), "HIDE")


# ─── Scenario weights ───────────────────────────────────────────────────────
# Aim for new verbs at 4-7% each, existing locomotion still dominant.

SCENARIOS = [
    # existing — locomotion + perception + speech (≈55%)
    (s_wait,                7),
    (s_wander,              7),
    (s_go_to,              10),
    (s_approach,            5),
    (s_flee,                4),
    (s_look_at_entity,      4),
    (s_look_at_object,      3),
    (s_examine,             5),
    (s_say_to,              7),
    (s_say_general,         3),
    (s_explore,             3),

    # new — TOUCH + INTERACT (highest somatic-grounding leverage)
    (s_touch_object,        5),
    (s_touch_entity,        2),
    (s_touch_item,          2),
    # INTERACT subscenarios share weight to keep total ≈ 6%
    (s_interact_drink,      2),
    (s_interact_warmth,     2),
    (s_interact_read,       1),
    (s_interact_craft,      1),
    (s_interact_signal,     1),

    # new — attention
    (s_watch,               4),
    (s_listen_entity,       3),
    (s_listen_location,     2),
    (s_follow,              3),
    (s_point_at_object,     2),
    (s_point_at_entity,     2),

    # inventory (existing CONSUME/TAKE got near-zero coverage in v1)
    (s_take,                3),
    (s_consume,             4),
    (s_drop,                1),
    (s_give,                2),
    (s_offer,               3),
    (s_show,                2),

    # body autonomy
    (s_rest,                4),
    (s_hide,                3),
]

SCENARIO_FNS = [s for s, _ in SCENARIOS]
SCENARIO_W = [w for _, w in SCENARIOS]


# ─── Validation ─────────────────────────────────────────────────────────────

NOUN_PATTERNS = [
    (re.compile(r"^GO TO (.+)$"), "location"),
    (re.compile(r"^LOOK AT (.+)$"), "either"),
    (re.compile(r"^LISTEN TO (.+)$"), "either"),
    (re.compile(r"^EXAMINE (.+)$"), "object"),
    (re.compile(r"^INTERACT WITH (.+)$"), "object"),
    (re.compile(r"^TOUCH (.+)$"), "either"),
    (re.compile(r"^POINT AT (.+)$"), "either"),
    (re.compile(r"^WATCH (.+)$"), "entity"),
    (re.compile(r"^FOLLOW (.+)$"), "entity"),
    (re.compile(r"^FLEE FROM (.+)$"), "entity"),
    (re.compile(r"^APPROACH (.+)$"), "entity"),
    (re.compile(r"^EXPLORE (.+)$"), "direction"),
    (re.compile(r"^WANDER AT (.+)$"), "location"),
    (re.compile(r"^TAKE (.+)$"), "item"),
    (re.compile(r"^CONSUME (.+)$"), "item"),
    (re.compile(r"^DROP (.+)$"), "item"),
    (re.compile(r"^GIVE (.+) TO (.+)$"), "item+entity"),
    (re.compile(r"^OFFER (.+) TO (.+)$"), "item+entity"),
    (re.compile(r"^SHOW (.+) TO (.+)$"), "item+entity"),
    (re.compile(r'^SAY ".*?" TO (.+)$'), "entity"),
]


def validate(example):
    user = example["messages"][1]["content"]
    asst = example["messages"][2]["content"]
    m = re.search(r"</think>\n(.+)", asst)
    if not m:
        return True
    cmd = m.group(1).strip()

    for pat, kind in NOUN_PATTERNS:
        match = pat.match(cmd)
        if not match:
            continue
        if kind == "item+entity":
            item, entity = match.group(1).strip(), match.group(2).strip()
            return item in user and entity in user
        noun = match.group(1).strip()
        return noun in user
    # Verbs without nouns: WAIT, WANDER, REST, HIDE, SAY "x"
    return True


# ─── Generation entry ───────────────────────────────────────────────────────

def generate(count, output_path):
    examples = []
    discarded = 0
    while len(examples) < count and discarded < count * 4:
        fn = random.choices(SCENARIO_FNS, weights=SCENARIO_W, k=1)[0]
        try:
            ex = fn(None)
        except Exception as e:
            discarded += 1
            continue
        if validate(ex):
            examples.append(ex)
        else:
            discarded += 1

    with open(output_path, "w") as f:
        for ex in examples:
            f.write(json.dumps(ex) + "\n")

    print(f"Generated {len(examples)} examples → {output_path}")
    print(f"  ({discarded} discarded for grounding/exception)")

    # Verb distribution
    counts = {}
    for ex in examples:
        m = re.search(r"</think>\n(.+)", ex["messages"][2]["content"])
        if m:
            cmd = m.group(1).strip()
            verb = cmd.split()[0]
            for v_long in ("GO TO", "LOOK AT", "LISTEN TO", "FLEE FROM",
                           "INTERACT WITH", "POINT AT", "WANDER AT"):
                if cmd.startswith(v_long):
                    verb = v_long
                    break
            counts[verb] = counts.get(verb, 0) + 1

    print("\n  Verb distribution:")
    for verb, n in sorted(counts.items(), key=lambda x: -x[1]):
        pct = n / len(examples) * 100
        print(f"    {verb:18s} {n:5d}  ({pct:5.2f}%)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python generate_command_training_v2.py <count> <output>")
        sys.exit(1)
    count = int(sys.argv[1])
    out = sys.argv[2]
    generate(count, out)
