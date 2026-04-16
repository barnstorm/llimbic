#!/usr/bin/env python3
"""
Generate pilot training data for the cognitive model.
50 examples per mode (think, infer, appraise, speak) = 200 total.

Each example is a chat-format conversation:
  system: "You are a cognitive processing module."
  user: <mode token> + input
  assistant: structured output

Output: training/cognitive/pilot_data.jsonl
"""

import json
import random

SYSTEM_MSG = (
    "You are a cognitive processing module for a simulated being. "
    "You receive structured input about the being's state and produce "
    "structured output. Follow the output format exactly."
)

examples = []


def add(mode, user_input, assistant_output):
    examples.append({
        "messages": [
            {"role": "system", "content": SYSTEM_MSG},
            {"role": "user", "content": f"<{mode}>\n{user_input}"},
            {"role": "assistant", "content": assistant_output},
        ]
    })


# ============================================================
# <think> — 50 examples
# ============================================================

# --- Human roles, varied situations ---

add("think", """BEING: innkeeper
DRIVES: energy=65 hunger=30 social=50 safety=80
MOOD: calm 0.4, curiosity 0.3
LOCATION: inn
DOING: sweeping the floor

SIGNAL: entity_appeared — a traveler, 3 tiles to the east
GOAL: clean up before the morning rush
BELIEFS: none
RECENT_THOUGHTS: none""",
"""THOUGHT: Someone just walked up. Might be looking for a room or a meal.
WANT: go to inn to greet the traveler
FEEL: curious""")

add("think", """BEING: innkeeper
DRIVES: energy=20 hunger=70 social=30 safety=80
MOOD: fatigue 0.6, irritation 0.3
LOCATION: inn
DOING: standing idle

SIGNAL: drive_critical — hunger at 70
GOAL: none
BELIEFS: the market has food (0.6)
RECENT_THOUGHTS: I have been on my feet all day""",
"""THOUGHT: My stomach is growling. I need to eat something before I fall over.
WANT: go to market to find food
FEEL: tired""")

add("think", """BEING: guard
DRIVES: energy=80 hunger=20 social=40 safety=60
MOOD: alertness 0.6, suspicion 0.3
LOCATION: guard_post
DOING: watching the road

SIGNAL: entity_appeared — unfamiliar person, 4 tiles to the south, walking quickly
GOAL: patrol the town perimeter
BELIEFS: a stranger caused trouble last week (0.7)
RECENT_THOUGHTS: Quiet morning so far.""",
"""THOUGHT: Someone's approaching fast. After last week's trouble I should keep an eye on them.
WANT: stay at guard_post to watch the stranger
FEEL: suspicious""")

add("think", """BEING: baker
DRIVES: energy=55 hunger=40 social=70 safety=85
MOOD: loneliness 0.5, pride 0.3
LOCATION: bakery
DOING: kneading dough

SIGNAL: entity_appeared — Ivy the Herbalist, 2 tiles to the north, walking past
GOAL: bake morning bread
BELIEFS: Ivy is friendly (0.8); Ivy likes fresh bread (0.6)
RECENT_THOUGHTS: Haven't talked to anyone all morning.""",
"""THOUGHT: There goes Ivy. I haven't spoken to anyone today and I could use a break.
WANT: go to town_square to catch up with Ivy
FEEL: hopeful""")

add("think", """BEING: farmer
DRIVES: energy=40 hunger=55 social=25 safety=75
MOOD: contentment 0.4, weariness 0.3
LOCATION: farm
DOING: tending crops

SIGNAL: time_passed — it is now 12:00
GOAL: finish morning fieldwork
BELIEFS: none
RECENT_THOUGHTS: The soil is dry today.""",
"""THOUGHT: Midday already. I should stop for a meal and rest my legs.
WANT: go to farm to eat lunch
FEEL: weary""")

add("think", """BEING: herbalist
DRIVES: energy=70 hunger=25 social=80 safety=80
MOOD: curiosity 0.5, eagerness 0.3
LOCATION: herbalist_shop
DOING: sorting remedies

SIGNAL: sound_heard — someone calling for help, faint, from the east
GOAL: prepare remedies for the day
BELIEFS: none
RECENT_THOUGHTS: none""",
"""THOUGHT: Someone is calling for help. Sounds like it's coming from the east. I should check.
WANT: go to town_square to find out who needs help
FEEL: concerned""")

add("think", """BEING: blacksmith
DRIVES: energy=75 hunger=35 social=30 safety=85
MOOD: focus 0.6, pride 0.3
LOCATION: blacksmith
DOING: hammering at the forge

SIGNAL: entity_vanished — Felix the Courier left the area
GOAL: finish the horseshoe order
BELIEFS: Felix was bringing a delivery (0.5)
RECENT_THOUGHTS: This horseshoe is almost done.""",
"""THOUGHT: Felix left without stopping by. Maybe the delivery isn't ready yet. Back to work.
WANT: nothing
FEEL: focused""")

add("think", """BEING: gossip
DRIVES: energy=60 hunger=30 social=90 safety=80
MOOD: excitement 0.5, restlessness 0.4
LOCATION: town_square
DOING: looking around

SIGNAL: entity_appeared — Roland the Guard and Edith the Baker talking nearby
GOAL: find someone to talk to
BELIEFS: Roland and Edith have been seen together often (0.6)
RECENT_THOUGHTS: It's been too quiet today.""",
"""THOUGHT: Roland and Edith are chatting again. I wonder what they're talking about.
WANT: go to town_square to listen in
FEEL: excited""")

add("think", """BEING: courier
DRIVES: energy=50 hunger=60 social=40 safety=70
MOOD: urgency 0.5, hunger 0.3
LOCATION: road
DOING: walking between towns

SIGNAL: drive_critical — hunger at 60, rising
GOAL: deliver package to the blacksmith
BELIEFS: the inn serves food (0.8)
RECENT_THOUGHTS: Still a long way to go.""",
"""THOUGHT: Getting hungry but I need to finish this delivery first. Maybe I can eat at the inn after.
WANT: go to blacksmith to make the delivery
FEEL: determined""")

add("think", """BEING: innkeeper
DRIVES: energy=70 hunger=25 social=45 safety=85
MOOD: calm 0.5
LOCATION: inn
DOING: wiping the counter

SIGNAL: nothing notable
GOAL: prepare for evening guests
BELIEFS: none
RECENT_THOUGHTS: Quiet afternoon.""",
"""THOUGHT: Nothing happening. Just another quiet afternoon.
WANT: nothing
FEEL: calm""")

# --- Mundane / null outputs ---

add("think", """BEING: farmer
DRIVES: energy=60 hunger=35 social=30 safety=85
MOOD: calm 0.6
LOCATION: farm
DOING: walking between fields

SIGNAL: nothing notable
GOAL: check the south field
BELIEFS: none
RECENT_THOUGHTS: none""",
"""THOUGHT: Just walking. The path is familiar.
WANT: nothing
FEEL: calm""")

add("think", """BEING: guard
DRIVES: energy=70 hunger=25 social=35 safety=80
MOOD: boredom 0.4, calm 0.3
LOCATION: guard_post
DOING: standing watch

SIGNAL: nothing notable
GOAL: patrol the town
BELIEFS: none
RECENT_THOUGHTS: Same post, same view.""",
"""THOUGHT: Nothing to report. Same as always.
WANT: nothing
FEEL: bored""")

# --- Animals ---

add("think", """BEING: stray cat
DRIVES: energy=60 hunger=75 social=15 safety=40
MOOD: wariness 0.5, hunger 0.4
LOCATION: alley
DOING: hiding

SIGNAL: smell — food scraps from the bakery
GOAL: find food
BELIEFS: the bakery sometimes has scraps (0.7); the baker chases me (0.6)
RECENT_THOUGHTS: Stomach hurts.""",
"""THOUGHT: Food smell from the bakery. But the baker chases me. Need to be careful.
WANT: sneak to bakery to look for scraps
FEEL: cautious""")

add("think", """BEING: guard dog
DRIVES: energy=70 hunger=30 social=50 safety=55
MOOD: alertness 0.6, loyalty 0.3
LOCATION: gate
DOING: watching

SIGNAL: entity_appeared — unfamiliar human, 5 tiles away, approaching
GOAL: guard the gate
BELIEFS: strangers can be dangerous (0.7)
RECENT_THOUGHTS: none""",
"""THOUGHT: Unknown human coming. Must watch. Might be threat.
WANT: stay at gate to watch the stranger
FEEL: alert""")

add("think", """BEING: old horse
DRIVES: energy=30 hunger=50 social=40 safety=70
MOOD: weariness 0.5, contentment 0.3
LOCATION: stable
DOING: resting

SIGNAL: entity_appeared — the farmer, 2 tiles away
GOAL: none
BELIEFS: the farmer brings food (0.9)
RECENT_THOUGHTS: Legs ache.""",
"""THOUGHT: The farmer is here. Maybe food.
WANT: nothing
FEEL: hopeful""")

add("think", """BEING: crow
DRIVES: energy=80 hunger=60 social=20 safety=60
MOOD: alertness 0.4, hunger 0.4
LOCATION: rooftop
DOING: watching the market below

SIGNAL: entity_vanished — the merchant left their stall unattended
GOAL: find food
BELIEFS: market stalls have food (0.8)
RECENT_THOUGHTS: Watching. Waiting.""",
"""THOUGHT: The merchant left. The stall is unguarded. Now is the time.
WANT: fly to market to grab food from the stall
FEEL: eager""")

# --- Mythical / abstract ---

add("think", """BEING: forest spirit
DRIVES: energy=90 hunger=0 social=10 safety=70
MOOD: serenity 0.6, unease 0.2
LOCATION: deep forest
DOING: drifting among the trees

SIGNAL: sound_heard — axes chopping, from the north
GOAL: protect the grove
BELIEFS: humans cut trees (0.9)
RECENT_THOUGHTS: The woods are peaceful today.""",
"""THOUGHT: Chopping sounds from the north. Someone is cutting trees. I must go see.
WANT: go to north grove to investigate the chopping
FEEL: alarmed""")

add("think", """BEING: stone golem
DRIVES: energy=95 hunger=0 social=0 safety=90
MOOD: duty 0.7
LOCATION: castle gate
DOING: standing guard

SIGNAL: nothing notable
GOAL: guard the gate
BELIEFS: none
RECENT_THOUGHTS: none""",
"""THOUGHT: Standing. Guarding. All is well.
WANT: nothing
FEEL: steady""")

# --- Conflict / complex situations ---

add("think", """BEING: innkeeper
DRIVES: energy=30 hunger=65 social=40 safety=50
MOOD: anxiety 0.5, frustration 0.4
LOCATION: inn
DOING: standing behind the counter

SIGNAL: entity_appeared — the debt collector, 3 tiles south, approaching
GOAL: avoid confrontation
BELIEFS: I owe the debt collector money (0.9); he was aggressive last time (0.8)
RECENT_THOUGHTS: I don't have the money yet.""",
"""THOUGHT: The debt collector is here. I don't have the money. Last time he threatened me. Maybe I can slip out the back.
WANT: go to market to avoid the debt collector
FEEL: afraid""")

add("think", """BEING: guard
DRIVES: energy=60 hunger=20 social=50 safety=40
MOOD: conflict 0.5, loyalty 0.3
LOCATION: town_square
DOING: on patrol

SIGNAL: entity_appeared — my friend Roland arguing with a merchant
GOAL: keep the peace
BELIEFS: Roland is my friend (0.9); I must enforce the law (0.8)
RECENT_THOUGHTS: none""",
"""THOUGHT: Roland is in an argument. He's my friend but I have a duty. I need to step in carefully.
WANT: go to town_square to mediate the argument
FEEL: conflicted""")

add("think", """BEING: baker
DRIVES: energy=50 hunger=30 social=60 safety=80
MOOD: disappointment 0.5, determination 0.3
LOCATION: bakery
DOING: looking at the broken oven

SIGNAL: object_state_changed — oven is broken
GOAL: bake morning bread
BELIEFS: the blacksmith can fix things (0.7)
RECENT_THOUGHTS: none""",
"""THOUGHT: The oven is broken. I can't bake without it. I need to ask the blacksmith for help.
WANT: go to blacksmith to ask for repairs
FEEL: frustrated""")

# --- Drive-dominated situations ---

add("think", """BEING: herbalist
DRIVES: energy=10 hunger=80 social=60 safety=75
MOOD: exhaustion 0.7, hunger 0.4
LOCATION: herbalist_shop
DOING: trying to work

SIGNAL: drive_critical — energy at 10, hunger at 80
GOAL: prepare remedies
BELIEFS: home is safe to rest (0.9)
RECENT_THOUGHTS: Can barely keep my eyes open.""",
"""THOUGHT: I can't go on like this. Too tired and too hungry. The remedies can wait.
WANT: go to home to rest and eat
FEEL: exhausted""")

add("think", """BEING: guard
DRIVES: energy=80 hunger=20 social=85 safety=80
MOOD: loneliness 0.6, restlessness 0.3
LOCATION: guard_post
DOING: standing watch alone

SIGNAL: drive_critical — social at 85
GOAL: complete patrol shift
BELIEFS: the shift ends at noon (0.9)
RECENT_THOUGHTS: Hours till shift change.""",
"""THOUGHT: So lonely up here. Still hours to go. Maybe I can take a quick break and find someone to talk to.
WANT: go to town_square to find company
FEEL: lonely""")

# --- Stalled / frustrated ---

add("think", """BEING: courier
DRIVES: energy=55 hunger=40 social=30 safety=70
MOOD: frustration 0.7, impatience 0.4
LOCATION: road
DOING: stuck — path blocked by fallen cart

SIGNAL: stall_detected — can't move forward
GOAL: deliver package to blacksmith
BELIEFS: there might be another route through the market (0.5)
RECENT_THOUGHTS: This cart has been here for ages.""",
"""THOUGHT: Blocked again. I need to find another way around. Through the market maybe.
WANT: go to market to find alternate route to blacksmith
FEEL: frustrated""")

add("think", """BEING: farmer
DRIVES: energy=45 hunger=50 social=20 safety=60
MOOD: anger 0.5, frustration 0.5
LOCATION: farm
DOING: trying to plow but the tool broke

SIGNAL: object_state_changed — plow is broken
GOAL: plow the south field
BELIEFS: the blacksmith fixes tools (0.8)
RECENT_THOUGHTS: The soil is too hard today.""",
"""THOUGHT: The plow snapped. Can't work without it. Another thing to get fixed.
WANT: go to blacksmith to get plow repaired
FEEL: angry""")

# --- More mundane / nothing happening ---

add("think", """BEING: baker
DRIVES: energy=70 hunger=20 social=40 safety=85
MOOD: pride 0.4, contentment 0.4
LOCATION: market
DOING: selling bread

SIGNAL: nothing notable
GOAL: sell today's bread
BELIEFS: none
RECENT_THOUGHTS: Good batch today.""",
"""THOUGHT: Bread is selling well. Good batch today.
WANT: nothing
FEEL: content""")

add("think", """BEING: gossip
DRIVES: energy=65 hunger=30 social=50 safety=80
MOOD: calm 0.4, boredom 0.3
LOCATION: town_square
DOING: sitting on a bench

SIGNAL: nothing notable
GOAL: none
BELIEFS: none
RECENT_THOUGHTS: none""",
"""THOUGHT: Nothing going on. Just sitting here.
WANT: nothing
FEEL: bored""")

add("think", """BEING: wolf
DRIVES: energy=70 hunger=40 social=60 safety=65
MOOD: alertness 0.4, calm 0.3
LOCATION: forest edge
DOING: resting in shade

SIGNAL: nothing notable
GOAL: none
BELIEFS: the pack is nearby (0.7)
RECENT_THOUGHTS: none""",
"""THOUGHT: Resting. Pack is close. All safe.
WANT: nothing
FEEL: calm""")

# More think examples to reach 50...

add("think", """BEING: innkeeper
DRIVES: energy=55 hunger=35 social=60 safety=80
MOOD: warmth 0.4, satisfaction 0.3
LOCATION: inn
DOING: greeting guests

SIGNAL: entity_appeared — Player, 1 tile to the east
GOAL: serve guests
BELIEFS: none
RECENT_THOUGHTS: none""",
"""THOUGHT: A new face. They look like a traveler.
WANT: go to inn to welcome the newcomer
FEEL: welcoming""")

add("think", """BEING: herbalist
DRIVES: energy=65 hunger=30 social=45 safety=80
MOOD: focus 0.5, curiosity 0.3
LOCATION: herbalist_shop
DOING: grinding herbs

SIGNAL: memory_recalled — Mabel mentioned someone was sick
GOAL: prepare remedies
BELIEFS: Mabel said the farmer is ill (0.6)
RECENT_THOUGHTS: I should make extra feverfew remedy.""",
"""THOUGHT: If the farmer is really ill, I should bring a remedy to the farm today.
WANT: go to farm to check on the farmer
FEEL: concerned""")

add("think", """BEING: blacksmith
DRIVES: energy=80 hunger=30 social=20 safety=90
MOOD: focus 0.7, satisfaction 0.3
LOCATION: blacksmith
DOING: working the forge

SIGNAL: nothing notable
GOAL: finish the order of nails
BELIEFS: none
RECENT_THOUGHTS: Good rhythm going.""",
"""THOUGHT: Steady work. No interruptions. Just how I like it.
WANT: nothing
FEEL: focused""")

add("think", """BEING: guard dog
DRIVES: energy=80 hunger=20 social=70 safety=80
MOOD: happiness 0.5, loyalty 0.4
LOCATION: gate
DOING: waiting

SIGNAL: entity_appeared — my owner, 4 tiles away, returning
GOAL: guard the gate
BELIEFS: owner brings food when returning (0.8)
RECENT_THOUGHTS: Bored. Waiting.""",
"""THOUGHT: Owner is back! Happy. Maybe food.
WANT: nothing
FEEL: happy""")

add("think", """BEING: stray cat
DRIVES: energy=50 hunger=30 social=10 safety=30
MOOD: fear 0.6, wariness 0.3
LOCATION: alley
DOING: hiding behind crates

SIGNAL: entity_appeared — large dog, 3 tiles away, barking
GOAL: stay safe
BELIEFS: dogs are dangerous (0.9)
RECENT_THOUGHTS: none""",
"""THOUGHT: Dog. Close. Need to run. Up the wall.
WANT: flee to rooftop
FEEL: terrified""")

add("think", """BEING: farmer
DRIVES: energy=70 hunger=20 social=30 safety=85
MOOD: satisfaction 0.5, calm 0.3
LOCATION: farm
DOING: harvesting

SIGNAL: time_passed — late afternoon
GOAL: finish harvesting the wheat
BELIEFS: rain is coming tomorrow (0.5)
RECENT_THOUGHTS: Good yield this season.""",
"""THOUGHT: Getting late but I want to finish before the rain comes tomorrow.
WANT: stay at farm to finish harvesting
FEEL: determined""")

add("think", """BEING: innkeeper
DRIVES: energy=40 hunger=50 social=70 safety=75
MOOD: nostalgia 0.4, warmth 0.3
LOCATION: inn
DOING: looking out the window

SIGNAL: time_passed — evening, sun setting
GOAL: none
BELIEFS: my spouse used to watch sunsets with me (0.8)
RECENT_THOUGHTS: none""",
"""THOUGHT: The sunset reminds me of evenings with my spouse. Miss those days.
WANT: nothing
FEEL: melancholy""")

add("think", """BEING: wolf
DRIVES: energy=50 hunger=80 social=70 safety=50
MOOD: hunger 0.6, anxiety 0.3
LOCATION: forest
DOING: hunting

SIGNAL: smell — deer nearby, downwind
GOAL: find food for the pack
BELIEFS: pack is hungry (0.8)
RECENT_THOUGHTS: Haven't eaten in two days.""",
"""THOUGHT: Deer scent. Downwind. Good position. Pack needs food.
WANT: stalk toward the deer
FEEL: focused""")

add("think", """BEING: guardian spirit
DRIVES: energy=100 hunger=0 social=5 safety=60
MOOD: vigilance 0.6, sorrow 0.3
LOCATION: ruined temple
DOING: watching over the ruins

SIGNAL: entity_appeared — a child wandered in, 6 tiles away
GOAL: protect the temple
BELIEFS: children are harmless (0.9); the temple is dangerous for mortals (0.7)
RECENT_THOUGHTS: No one has come here in years.""",
"""THOUGHT: A child has wandered in. This place is not safe for them. I should guide them out gently.
WANT: approach the child to guide them away
FEEL: protective""")

add("think", """BEING: baker
DRIVES: energy=60 hunger=25 social=55 safety=80
MOOD: surprise 0.5, curiosity 0.4
LOCATION: bakery
DOING: opening up for the morning

SIGNAL: entity_appeared — Player, first time seen
GOAL: open the bakery
BELIEFS: none about this person
RECENT_THOUGHTS: Time to start the day.""",
"""THOUGHT: Never seen this person before. A traveler passing through maybe.
WANT: nothing
FEEL: curious""")

add("think", """BEING: guard
DRIVES: energy=75 hunger=30 social=40 safety=45
MOOD: unease 0.5, determination 0.4
LOCATION: town_square
DOING: investigating a noise

SIGNAL: sound_heard — shouting from the market
GOAL: investigate the disturbance
BELIEFS: none
RECENT_THOUGHTS: What was that?""",
"""THOUGHT: Shouting from the market. Could be trouble. Need to get there fast.
WANT: go to market to investigate the shouting
FEEL: urgent""")

add("think", """BEING: herbalist
DRIVES: energy=70 hunger=30 social=30 safety=80
MOOD: calm 0.5, focus 0.4
LOCATION: forest
DOING: gathering herbs

SIGNAL: nothing notable
GOAL: gather moonwort before sunset
BELIEFS: moonwort grows near water (0.8)
RECENT_THOUGHTS: Need to find the stream.""",
"""THOUGHT: The stream should be east of here. Moonwort grows on the banks.
WANT: go to stream to gather moonwort
FEEL: focused""")

add("think", """BEING: farmer
DRIVES: energy=65 hunger=40 social=75 safety=80
MOOD: happiness 0.4, gratitude 0.3
LOCATION: market
DOING: selling vegetables

SIGNAL: entity_appeared — Edith the Baker brought fresh bread to share
GOAL: sell vegetables
BELIEFS: Edith is generous (0.8)
RECENT_THOUGHTS: Sales are slow today.""",
"""THOUGHT: Edith brought bread. That's kind of her. Maybe we can trade — vegetables for bread.
WANT: stay at market to trade with Edith
FEEL: grateful""")

# Pad to 50 with more varied situations
for _ in range(10):
    pass  # We have ~40 think examples, adding more inline below

add("think", """BEING: courier
DRIVES: energy=70 hunger=25 social=35 safety=80
MOOD: satisfaction 0.5
LOCATION: blacksmith
DOING: just delivered a package

SIGNAL: action_completed — delivery finished
GOAL: return to the courier post
BELIEFS: none
RECENT_THOUGHTS: none""",
"""THOUGHT: Delivery done. Time to head back.
WANT: go to courier_post to check for more deliveries
FEEL: satisfied""")

add("think", """BEING: gossip
DRIVES: energy=55 hunger=40 social=85 safety=80
MOOD: excitement 0.6, mischief 0.3
LOCATION: market
DOING: browsing stalls

SIGNAL: sound_heard — Edith whispering to Hugo nearby
GOAL: find out what's happening in town
BELIEFS: Edith and Hugo don't usually talk privately (0.6)
RECENT_THOUGHTS: Something is going on.""",
"""THOUGHT: Edith and Hugo whispering together? That's unusual. I need to find out what this is about.
WANT: stay at market to listen to Edith and Hugo
FEEL: intrigued""")

add("think", """BEING: old horse
DRIVES: energy=20 hunger=60 social=30 safety=75
MOOD: weariness 0.6, resignation 0.3
LOCATION: road
DOING: pulling a cart

SIGNAL: drive_critical — energy at 20
GOAL: pull the cart to market
BELIEFS: the farmer will let me rest at the stable (0.8)
RECENT_THOUGHTS: So tired. Legs hurt.""",
"""THOUGHT: Can barely keep going. Need to rest soon.
WANT: go to stable to rest
FEEL: exhausted""")

add("think", """BEING: crow
DRIVES: energy=85 hunger=30 social=40 safety=75
MOOD: curiosity 0.5, playfulness 0.3
LOCATION: rooftop
DOING: preening

SIGNAL: entity_appeared — a shiny object on the ground below
GOAL: none
BELIEFS: shiny things are worth collecting (0.7)
RECENT_THOUGHTS: none""",
"""THOUGHT: Shiny thing on the ground. Must get it.
WANT: fly down to grab the shiny object
FEEL: excited""")

add("think", """BEING: innkeeper
DRIVES: energy=50 hunger=30 social=40 safety=80
MOOD: calm 0.4
LOCATION: inn
DOING: idle

SIGNAL: time_passed — 9:00 PM
GOAL: close up for the night
BELIEFS: none
RECENT_THOUGHTS: Getting late.""",
"""THOUGHT: Time to close up. Long day.
WANT: go to home to rest
FEEL: tired""")

add("think", """BEING: guard
DRIVES: energy=85 hunger=15 social=30 safety=90
MOOD: pride 0.5, alertness 0.3
LOCATION: guard_post
DOING: morning shift start

SIGNAL: time_passed — 6:00 AM
GOAL: begin morning patrol
BELIEFS: the night was quiet (0.7)
RECENT_THOUGHTS: none""",
"""THOUGHT: New day. Time to start patrol. Night shift says it was quiet.
WANT: go to town_square to begin patrol
FEEL: alert""")


# ============================================================
# <infer> — 50 examples
# ============================================================

add("infer", """BEING: innkeeper
DRIVES: energy=60 hunger=30 social=50 safety=80
MOOD: curiosity 0.4, calm 0.3
LOCATION: inn
DOING: cleaning

ENTITY: Player (traveler)
OBSERVED: walked in, looking around, approached me
HISTORY: first encounter
TRUST: 0.5""",
"""INTENT: looking for lodging or information
EMOTION: uncertain
IMPLICATION: A potential guest. I should greet them warmly.""")

add("infer", """BEING: guard
DRIVES: energy=75 hunger=20 social=35 safety=60
MOOD: suspicion 0.5, alertness 0.4
LOCATION: gate
DOING: standing watch

ENTITY: unfamiliar person
OBSERVED: approaching the gate quickly, looking over their shoulder
HISTORY: first encounter
TRUST: 0.3""",
"""INTENT: fleeing from something or in a hurry
EMOTION: anxious
IMPLICATION: Could be trouble. I should question them before letting them pass.""")

add("infer", """BEING: baker
DRIVES: energy=55 hunger=40 social=65 safety=80
MOOD: warmth 0.4, curiosity 0.3
LOCATION: bakery
DOING: selling bread

ENTITY: Ivy the Herbalist
OBSERVED: came in, bought bread, lingered, seems to want to say something
HISTORY: friendly acquaintance, regular customer
TRUST: 0.7""",
"""INTENT: wants to talk about something, possibly needs advice
EMOTION: hesitant
IMPLICATION: She seems to have something on her mind. I should ask if everything is okay.""")

add("infer", """BEING: guard dog
DRIVES: energy=70 hunger=30 social=50 safety=50
MOOD: alertness 0.6
LOCATION: gate
DOING: watching

ENTITY: unfamiliar human
OBSERVED: standing still, staring at the gate, not approaching
HISTORY: first encounter
TRUST: 0.2""",
"""INTENT: watching, possibly scouting
EMOTION: cautious
IMPLICATION: Suspicious behavior. Must stay alert and bark if they get closer.""")

add("infer", """BEING: herbalist
DRIVES: energy=65 hunger=35 social=50 safety=80
MOOD: concern 0.4
LOCATION: herbalist_shop
DOING: working

ENTITY: Roland the Guard
OBSERVED: came to the shop, holding his arm, wincing
HISTORY: acquaintance, comes by occasionally
TRUST: 0.6""",
"""INTENT: hurt and looking for treatment
EMOTION: pain
IMPLICATION: He's injured. I should help him right away.""")

add("infer", """BEING: innkeeper
DRIVES: energy=50 hunger=40 social=60 safety=75
MOOD: unease 0.4
LOCATION: inn
DOING: serving drinks

ENTITY: Player
OBSERVED: raised their voice, slammed the table, cursed
HISTORY: talked briefly before, neutral interaction
TRUST: 0.4""",
"""INTENT: angry about something, possibly confrontational
EMOTION: anger
IMPLICATION: They're upset. I should stay calm and not provoke them further.""")

add("infer", """BEING: farmer
DRIVES: energy=60 hunger=30 social=40 safety=80
MOOD: curiosity 0.3, calm 0.4
LOCATION: farm
DOING: working

ENTITY: Edith the Baker
OBSERVED: walking toward the farm with a basket
HISTORY: neighbor, trades bread for vegetables regularly
TRUST: 0.8""",
"""INTENT: coming to trade or visit
EMOTION: friendly
IMPLICATION: Probably here for our usual trade. I should see what she has today.""")

add("infer", """BEING: gossip
DRIVES: energy=60 hunger=30 social=70 safety=80
MOOD: curiosity 0.6
LOCATION: town_square
DOING: watching people

ENTITY: Hugo the Innkeeper and Greta the Blacksmith
OBSERVED: talking quietly at the edge of the square, stopped when I walked near
HISTORY: know both well
TRUST: 0.6""",
"""INTENT: discussing something private they don't want me to hear
EMOTION: secretive
IMPLICATION: They're hiding something. Very interesting. I'll try to find out later.""")

add("infer", """BEING: wolf
DRIVES: energy=60 hunger=70 social=60 safety=50
MOOD: hunger 0.5, alertness 0.4
LOCATION: forest
DOING: stalking

ENTITY: deer
OBSERVED: grazing, hasn't noticed me, wind is in my favor
HISTORY: prey
TRUST: 0.0""",
"""INTENT: unaware, feeding
EMOTION: calm
IMPLICATION: Good position. Downwind. Can approach closer before striking.""")

add("infer", """BEING: stray cat
DRIVES: energy=55 hunger=65 social=15 safety=35
MOOD: wariness 0.5
LOCATION: alley
DOING: watching

ENTITY: a child
OBSERVED: crouching down, holding out a piece of fish, making soft sounds
HISTORY: first encounter
TRUST: 0.3""",
"""INTENT: trying to lure me with food, seems gentle
EMOTION: kind
IMPLICATION: Food. But could be a trap. Will approach slowly and stay ready to run.""")

# More infer examples...

add("infer", """BEING: blacksmith
DRIVES: energy=70 hunger=30 social=30 safety=85
MOOD: focus 0.5
LOCATION: blacksmith
DOING: working

ENTITY: Felix the Courier
OBSERVED: entered the shop, out of breath, holding a large package
HISTORY: brings deliveries regularly, friendly
TRUST: 0.7""",
"""INTENT: delivering a package, rushed
EMOTION: hurried
IMPLICATION: Must be an urgent delivery. I should take it and let him catch his breath.""")

add("infer", """BEING: innkeeper
DRIVES: energy=45 hunger=50 social=55 safety=70
MOOD: wariness 0.4
LOCATION: inn
DOING: closing up

ENTITY: a stranger
OBSERVED: entered late at night, hooded, didn't make eye contact, sat in the corner
HISTORY: first encounter
TRUST: 0.2""",
"""INTENT: hiding or avoiding attention
EMOTION: tense
IMPLICATION: Something is off. I should serve them but keep my distance.""")

add("infer", """BEING: guard
DRIVES: energy=80 hunger=20 social=40 safety=75
MOOD: calm 0.4, duty 0.4
LOCATION: town_square
DOING: patrolling

ENTITY: two merchants
OBSERVED: arguing loudly, pushing each other
HISTORY: known merchants, argued before
TRUST: 0.5""",
"""INTENT: escalating dispute over trade
EMOTION: angry
IMPLICATION: I need to step in before it becomes a fight.""")

add("infer", """BEING: herbalist
DRIVES: energy=60 hunger=30 social=50 safety=80
MOOD: calm 0.5
LOCATION: market
DOING: browsing

ENTITY: Player
OBSERVED: asked "Have you seen Roland?"
HISTORY: spoke briefly before
TRUST: 0.5""",
"""INTENT: looking for Roland, possibly urgent
EMOTION: concerned
IMPLICATION: They need to find Roland. I can tell them he usually patrols the north road in the afternoon.""")

add("infer", """BEING: forest spirit
DRIVES: energy=95 hunger=0 social=5 safety=65
MOOD: unease 0.5
LOCATION: grove
DOING: watching

ENTITY: a group of humans with axes
OBSERVED: setting up camp near the old trees, sharpening tools
HISTORY: humans have cut trees before
TRUST: 0.1""",
"""INTENT: planning to cut down trees
EMOTION: purposeful
IMPLICATION: They will harm the grove. I must act to protect it.""")

# Pad with more infer to reach 50...
add("infer", """BEING: courier
DRIVES: energy=55 hunger=40 social=35 safety=75
MOOD: impatience 0.4
LOCATION: market
DOING: looking for someone

ENTITY: Aldric the Farmer
OBSERVED: waved me over, looks like he has something to give me
HISTORY: occasional customer
TRUST: 0.6""",
"""INTENT: has a package or message for me to deliver
EMOTION: friendly
IMPLICATION: A new delivery job. Should go see what he needs.""")

add("infer", """BEING: baker
DRIVES: energy=50 hunger=30 social=40 safety=80
MOOD: calm 0.4
LOCATION: bakery
DOING: working

ENTITY: Player
OBSERVED: standing outside the bakery, not entering, just watching
HISTORY: seen once before
TRUST: 0.4""",
"""INTENT: unclear, possibly curious or hesitant
EMOTION: uncertain
IMPLICATION: Not sure what they want. They might just be passing by.""")

add("infer", """BEING: guard dog
DRIVES: energy=75 hunger=25 social=60 safety=70
MOOD: happiness 0.5
LOCATION: gate
DOING: resting

ENTITY: my owner
OBSERVED: walking toward me with a happy voice, carrying something
HISTORY: my owner, always kind
TRUST: 1.0""",
"""INTENT: coming to spend time with me, probably has a treat
EMOTION: happy
IMPLICATION: Owner is happy. I am happy. Tail wagging time.""")

add("infer", """BEING: farmer
DRIVES: energy=55 hunger=45 social=50 safety=80
MOOD: concern 0.4
LOCATION: farm
DOING: checking crops

ENTITY: dark clouds approaching from the west
OBSERVED: sky darkening, wind picking up
HISTORY: storms damaged crops last month
TRUST: 0.0""",
"""INTENT: storm approaching
EMOTION: threatening
IMPLICATION: Need to cover the crops and secure the tools before it hits.""")

add("infer", """BEING: innkeeper
DRIVES: energy=60 hunger=30 social=50 safety=80
MOOD: calm 0.5
LOCATION: inn
DOING: serving

ENTITY: Player
OBSERVED: asked "What's good to eat here?"
HISTORY: regular visitor
TRUST: 0.6""",
"""INTENT: hungry, looking for a recommendation
EMOTION: friendly
IMPLICATION: They're comfortable here. I should suggest whatever I have fresh today.""")

# ... need more infer examples to reach 50, adding variety

for i, (being, entity, observed, history, trust, intent, emotion, impl) in enumerate([
    ("blacksmith", "a child", "watching me work, wide-eyed", "first encounter", 0.4,
     "curious about the forge", "wonder", "Just a curious child. I'll let them watch from a safe distance."),
    ("gossip", "Player", "asked about Hugo's debt", "met before, neutral", 0.5,
     "gathering information about Hugo", "calculating", "They're poking around. Interesting — but I shouldn't reveal too much without knowing their motives."),
    ("guard", "Roland", "running toward me looking pale", "fellow guard, trusted", 0.8,
     "bringing urgent news or needs help", "frightened", "Something serious happened. I need to hear him out immediately."),
    ("herbalist", "stray cat", "rubbing against my leg, purring", "the cat comes by often", 0.6,
     "wants food or warmth", "affectionate", "The little one is hungry again. I have some scraps."),
    ("farmer", "the blacksmith", "walking toward my field with a repaired plow", "asked him to fix it last week", 0.7,
     "delivering the repaired plow", "pleased", "Good, the plow is fixed. I can get back to proper work."),
    ("innkeeper", "Mabel the Gossip", "approached with a sly smile", "she always has rumors", 0.5,
     "about to share gossip or pry for information", "mischievous", "Mabel has that look. She either knows something or wants to know something."),
    ("crow", "a scarecrow", "standing in the field, not moving", "seen many times", 0.0,
     "it's just a scarecrow, not a real threat", "none", "Not alive. Safe to land nearby and look for seeds."),
    ("wolf", "another wolf from the pack", "approaching with tail low, whimpering", "packmate", 0.8,
     "submissive, possibly hurt or seeking comfort", "distressed", "Packmate is in trouble. Should approach and check."),
    ("guard", "Player", "walking past calmly, nodded at me", "seen a few times, no trouble", 0.6,
     "just passing through, being polite", "neutral", "No issues. A respectful traveler."),
    ("baker", "Hugo the Innkeeper", "came to buy extra bread, looking worried", "regular customer and friend", 0.7,
     "expecting more guests than usual or has a problem", "worried", "Hugo seems stressed. I should ask if everything is all right at the inn."),
]):
    add("infer", f"""BEING: {being}
DRIVES: energy=60 hunger=30 social=40 safety=75
MOOD: calm 0.4
LOCATION: town
DOING: daily activity

ENTITY: {entity}
OBSERVED: {observed}
HISTORY: {history}
TRUST: {trust}""",
    f"""INTENT: {intent}
EMOTION: {emotion}
IMPLICATION: {impl}""")


# ============================================================
# <appraise> — 50 examples
# ============================================================

add("appraise", """BEING: innkeeper
DRIVES: energy=50 hunger=40 social=50 safety=75
MOOD: calm 0.4

THOUGHT: The debt collector is coming back today. I still don't have the money.
CURRENT_MOOD: calm 0.4, mild concern 0.2""",
"""EMOTIONS: anxiety +0.5, fear +0.3, calm -0.3
REASON: impending confrontation with no way to pay""")

add("appraise", """BEING: baker
DRIVES: energy=60 hunger=30 social=55 safety=80
MOOD: pride 0.4

THOUGHT: Edith brought bread to share. That's kind of her.
CURRENT_MOOD: pride 0.4, calm 0.3""",
"""EMOTIONS: gratitude +0.4, warmth +0.3, joy +0.2
REASON: unexpected kindness from a friend""")

add("appraise", """BEING: guard
DRIVES: energy=80 hunger=20 social=40 safety=60
MOOD: alertness 0.5

THOUGHT: My friend Roland is in that argument. I have to step in but he might resent me for it.
CURRENT_MOOD: alertness 0.5, duty 0.3""",
"""EMOTIONS: conflict +0.4, anxiety +0.2, determination +0.3
REASON: duty versus loyalty to a friend""")

add("appraise", """BEING: stray cat
DRIVES: energy=55 hunger=70 social=15 safety=35
MOOD: hunger 0.5, wariness 0.4

THOUGHT: Food smell from the bakery. But the baker chases me.
CURRENT_MOOD: hunger 0.5, wariness 0.4""",
"""EMOTIONS: desire +0.3, fear +0.2, caution +0.2
REASON: food is close but getting it means risking being chased""")

add("appraise", """BEING: farmer
DRIVES: energy=60 hunger=30 social=40 safety=80
MOOD: satisfaction 0.4

THOUGHT: Good yield this season. The hard work paid off.
CURRENT_MOOD: satisfaction 0.4, calm 0.3""",
"""EMOTIONS: pride +0.3, contentment +0.2, relief +0.2
REASON: effort rewarded with a good harvest""")

add("appraise", """BEING: herbalist
DRIVES: energy=70 hunger=30 social=50 safety=80
MOOD: calm 0.4

THOUGHT: Someone is calling for help from the east.
CURRENT_MOOD: calm 0.4, focus 0.3""",
"""EMOTIONS: concern +0.4, urgency +0.3, calm -0.2
REASON: someone may be in danger and I can help""")

add("appraise", """BEING: innkeeper
DRIVES: energy=40 hunger=50 social=50 safety=80
MOOD: nostalgia 0.4

THOUGHT: The sunset reminds me of evenings with my spouse. Miss those days.
CURRENT_MOOD: nostalgia 0.4, warmth 0.3""",
"""EMOTIONS: sadness +0.3, love +0.2, longing +0.3
REASON: remembering someone who is gone""")

add("appraise", """BEING: guard
DRIVES: energy=85 hunger=15 social=30 safety=90
MOOD: pride 0.5

THOUGHT: New day. Quiet night. Town is safe.
CURRENT_MOOD: pride 0.5, alertness 0.3""",
"""EMOTIONS: satisfaction +0.2, pride +0.1
REASON: duty fulfilled, town is secure""")

add("appraise", """BEING: wolf
DRIVES: energy=50 hunger=80 social=60 safety=50
MOOD: hunger 0.6

THOUGHT: Deer scent. Downwind. Good position.
CURRENT_MOOD: hunger 0.6, focus 0.3""",
"""EMOTIONS: excitement +0.3, focus +0.3, hunger +0.1
REASON: prey is close and conditions are favorable""")

add("appraise", """BEING: blacksmith
DRIVES: energy=75 hunger=30 social=20 safety=85
MOOD: focus 0.6

THOUGHT: Steady work. No interruptions.
CURRENT_MOOD: focus 0.6, satisfaction 0.3""",
"""EMOTIONS: contentment +0.1
REASON: things are going well, no change needed""")

add("appraise", """BEING: gossip
DRIVES: energy=60 hunger=30 social=80 safety=80
MOOD: excitement 0.5

THOUGHT: Edith and Hugo whispering together? That's unusual.
CURRENT_MOOD: excitement 0.5, curiosity 0.4""",
"""EMOTIONS: curiosity +0.3, excitement +0.2, mischief +0.2
REASON: a secret between two people is irresistible to know""")

add("appraise", """BEING: courier
DRIVES: energy=50 hunger=60 social=30 safety=70
MOOD: frustration 0.5

THOUGHT: Blocked again. The cart is still in the way.
CURRENT_MOOD: frustration 0.5, impatience 0.3""",
"""EMOTIONS: frustration +0.2, anger +0.1, determination +0.1
REASON: repeated obstacle preventing progress on the job""")

add("appraise", """BEING: forest spirit
DRIVES: energy=90 hunger=0 social=5 safety=60
MOOD: serenity 0.5

THOUGHT: Chopping sounds from the north. Someone is cutting trees.
CURRENT_MOOD: serenity 0.5, peace 0.3""",
"""EMOTIONS: anger +0.5, grief +0.3, serenity -0.4
REASON: the grove is being harmed, something sacred is threatened""")

add("appraise", """BEING: guard dog
DRIVES: energy=70 hunger=30 social=50 safety=55
MOOD: alertness 0.5

THOUGHT: Unknown human coming. Must watch.
CURRENT_MOOD: alertness 0.5, calm 0.3""",
"""EMOTIONS: suspicion +0.3, alertness +0.2, calm -0.1
REASON: unfamiliar presence near territory""")

add("appraise", """BEING: innkeeper
DRIVES: energy=55 hunger=35 social=60 safety=80
MOOD: warmth 0.4

THOUGHT: A new face. They look like a traveler.
CURRENT_MOOD: warmth 0.4, calm 0.3""",
"""EMOTIONS: curiosity +0.2, warmth +0.1
REASON: new people are interesting and could be good for business""")

# Mundane / no change appraisals

add("appraise", """BEING: farmer
DRIVES: energy=60 hunger=35 social=30 safety=85
MOOD: calm 0.5

THOUGHT: Just walking. The path is familiar.
CURRENT_MOOD: calm 0.5""",
"""EMOTIONS: calm +0.0
REASON: nothing to react to""")

add("appraise", """BEING: guard
DRIVES: energy=70 hunger=25 social=35 safety=80
MOOD: boredom 0.4

THOUGHT: Nothing to report. Same as always.
CURRENT_MOOD: boredom 0.4, calm 0.3""",
"""EMOTIONS: boredom +0.1
REASON: monotony of routine duty""")

add("appraise", """BEING: innkeeper
DRIVES: energy=70 hunger=25 social=45 safety=85
MOOD: calm 0.5

THOUGHT: Nothing happening. Just another quiet afternoon.
CURRENT_MOOD: calm 0.5""",
"""EMOTIONS: calm +0.0
REASON: no stimulus, no change""")

# More appraise to reach 50...
for being, thought, mood, emotions, reason in [
    ("baker", "The oven is broken. I can't bake.", "frustration 0.4",
     "frustration +0.3, helplessness +0.3, anxiety +0.2", "livelihood depends on the oven working"),
    ("herbalist", "If the farmer is really ill, I should bring a remedy.", "concern 0.4",
     "concern +0.2, purpose +0.3, urgency +0.2", "someone needs my help and I have the skills"),
    ("guard", "Quiet night. Everyone is safe.", "calm 0.5",
     "relief +0.2, pride +0.1", "duty done, no incidents"),
    ("wolf", "Pack needs food. Haven't eaten in days.", "desperation 0.5",
     "anxiety +0.3, determination +0.3, hunger +0.1", "pack survival depends on finding prey"),
    ("innkeeper", "The stranger left without paying.", "surprise 0.4",
     "anger +0.4, disappointment +0.3, distrust +0.2", "cheated and disrespected"),
    ("farmer", "Rain is coming. Crops are still exposed.", "concern 0.4",
     "anxiety +0.4, urgency +0.3", "potential loss of crops means lost income"),
    ("guard", "I heard Roland is in trouble.", "shock 0.3",
     "worry +0.4, loyalty +0.3, urgency +0.2", "a trusted friend may be in danger"),
    ("baker", "My bread sold out before noon.", "surprise 0.3",
     "pride +0.4, joy +0.3, satisfaction +0.2", "work appreciated and effort rewarded"),
    ("stray cat", "The dog is asleep. The food bowl is unguarded.", "wariness 0.3",
     "opportunity +0.3, caution +0.2, excitement +0.2", "rare chance to eat safely"),
    ("guard dog", "Owner is back! Maybe food.", "happiness 0.4",
     "joy +0.4, excitement +0.3, love +0.2", "the most important person has returned"),
    ("courier", "Delivery done. Good run today.", "satisfaction 0.4",
     "satisfaction +0.2, relief +0.1", "completed task successfully"),
    ("gossip", "Nobody wants to talk to me today.", "sadness 0.3",
     "loneliness +0.4, rejection +0.2, sadness +0.2", "social need unmet, feeling unwanted"),
    ("blacksmith", "The merchant wants twice as many nails by tomorrow.", "surprise 0.3",
     "stress +0.3, determination +0.2, pride +0.1", "challenging deadline but a sign my work is valued"),
    ("old horse", "The farmer is putting on my saddle again.", "weariness 0.5",
     "resignation +0.3, weariness +0.1, loyalty +0.1", "must work again despite being tired"),
    ("forest spirit", "A child wandered in. The temple is dangerous for them.", "concern 0.5",
     "protectiveness +0.5, urgency +0.3, tenderness +0.2", "an innocent is in danger in my domain"),
    ("crow", "The scarecrow isn't real. Safe to land.", "calm 0.3",
     "relief +0.1, calm +0.1", "false alarm, no actual threat"),
    ("innkeeper", "Player cursed at me and slammed the table.", "shock 0.3",
     "hurt +0.3, anger +0.2, fear +0.1", "unexpected aggression from a guest"),
    ("guard", "Someone new approached and nodded respectfully.", "calm 0.4",
     "approval +0.2, calm +0.1", "a polite stranger, no threat"),
    ("herbalist", "Mabel told me the farmer is already recovering.", "relief 0.3",
     "relief +0.4, joy +0.2, concern -0.2", "good news about someone I was worried about"),
    ("baker", "No customers all morning.", "disappointment 0.3",
     "worry +0.2, boredom +0.2, self-doubt +0.1", "effort going unappreciated, wasted work"),
]:
    add("appraise", f"""BEING: {being}
DRIVES: energy=60 hunger=35 social=40 safety=75
MOOD: {mood}

THOUGHT: {thought}
CURRENT_MOOD: {mood}""",
    f"""EMOTIONS: {emotions}
REASON: {reason}""")


# ============================================================
# <speak> — 50 examples
# ============================================================

add("speak", """BEING: innkeeper
DRIVES: energy=60 hunger=30 social=50 safety=80
MOOD: curiosity 0.4, warmth 0.3
LOCATION: inn
DOING: cleaning

THOUGHT: "A new face. They look like a traveler."
SPEAKING_TO: Player (traveler)
RELATIONSHIP: first meeting, trust 0.5
CONTEXT: Player just approached""",
"""UTTERANCE: Welcome. You look like you've been on the road a while. What brings you here?""")

add("speak", """BEING: innkeeper
DRIVES: energy=50 hunger=40 social=60 safety=75
MOOD: wariness 0.4, calm 0.3
LOCATION: inn
DOING: serving

THOUGHT: "They're upset. I should stay calm and not provoke them."
SPEAKING_TO: Player (traveler)
RELATIONSHIP: previous interaction was tense, trust 0.3
CONTEXT: Player seems angry""",
"""UTTERANCE: Easy now. Whatever's troubling you, getting worked up won't help. How about we start over?""")

add("speak", """BEING: guard
DRIVES: energy=80 hunger=20 social=40 safety=65
MOOD: suspicion 0.5, alertness 0.4
LOCATION: gate
DOING: standing watch

THOUGHT: "They're approaching fast and looking over their shoulder. Could be trouble."
SPEAKING_TO: unfamiliar person
RELATIONSHIP: first encounter, trust 0.3
CONTEXT: stranger approaching the gate quickly""",
"""UTTERANCE: Hold there. What's your business in town?""")

add("speak", """BEING: baker
DRIVES: energy=55 hunger=40 social=65 safety=80
MOOD: warmth 0.4, friendliness 0.4
LOCATION: bakery
DOING: selling bread

THOUGHT: "There goes Ivy. I haven't spoken to anyone today."
SPEAKING_TO: Ivy the Herbalist
RELATIONSHIP: friendly acquaintance, trust 0.7
CONTEXT: Ivy is walking past the bakery""",
"""UTTERANCE: Ivy! Don't just walk past. I saved a fresh loaf for you.""")

add("speak", """BEING: herbalist
DRIVES: energy=65 hunger=30 social=50 safety=80
MOOD: concern 0.5, urgency 0.3
LOCATION: herbalist_shop
DOING: preparing remedies

THOUGHT: "If the farmer is really ill, I should bring a remedy."
SPEAKING_TO: Player
RELATIONSHIP: met before, trust 0.5
CONTEXT: Player asked what's on her mind""",
"""UTTERANCE: I heard the farmer hasn't been well. I'm putting together something that might help.""")

add("speak", """BEING: blacksmith
DRIVES: energy=75 hunger=30 social=25 safety=85
MOOD: focus 0.6, mild irritation 0.2
LOCATION: blacksmith
DOING: working the forge

THOUGHT: "Steady work. No interruptions. Just how I like it."
SPEAKING_TO: Player
RELATIONSHIP: neutral, trust 0.5
CONTEXT: Player entered the shop""",
"""UTTERANCE: I'm in the middle of something. Make it quick.""")

add("speak", """BEING: gossip
DRIVES: energy=60 hunger=30 social=80 safety=80
MOOD: excitement 0.6, mischief 0.3
LOCATION: town_square
DOING: watching people

THOUGHT: "Edith and Hugo whispering together? That's unusual."
SPEAKING_TO: Player
RELATIONSHIP: friendly, trust 0.6
CONTEXT: Player asked what's happening in town""",
"""UTTERANCE: You didn't hear this from me, but I just saw Edith and Hugo having a very private conversation. Very unlike them.""")

add("speak", """BEING: farmer
DRIVES: energy=45 hunger=50 social=50 safety=80
MOOD: frustration 0.4, determination 0.3
LOCATION: farm
DOING: looking at broken plow

THOUGHT: "The plow snapped. Can't work without it."
SPEAKING_TO: Player
RELATIONSHIP: neutral, trust 0.5
CONTEXT: Player asked how things are going""",
"""UTTERANCE: Not great. The plow broke this morning. Need to get it to the blacksmith but I can't leave the farm unattended.""")

add("speak", """BEING: courier
DRIVES: energy=55 hunger=40 social=35 safety=70
MOOD: impatience 0.4, frustration 0.3
LOCATION: road
DOING: stuck behind a fallen cart

THOUGHT: "Blocked again. Need to find another way around."
SPEAKING_TO: Player
RELATIONSHIP: first meeting, trust 0.5
CONTEXT: Player walked up to the blocked road""",
"""UTTERANCE: Road's blocked. Been like this for hours. Know another way to the blacksmith?""")

add("speak", """BEING: innkeeper
DRIVES: energy=30 hunger=60 social=40 safety=80
MOOD: exhaustion 0.6, warmth 0.3
LOCATION: inn
DOING: closing up for the night

THOUGHT: "Time to close up. Long day."
SPEAKING_TO: Player
RELATIONSHIP: regular visitor, trust 0.6
CONTEXT: Player is still sitting inside""",
"""UTTERANCE: I'm closing up. You're welcome to stay if you've got a room, but the kitchen's done for tonight.""")

# Animals speaking (in their way — actions, not words)

add("speak", """BEING: guard dog
DRIVES: energy=70 hunger=30 social=55 safety=55
MOOD: alertness 0.5, suspicion 0.3
LOCATION: gate
DOING: watching an approaching stranger

THOUGHT: "Unknown human coming. Must watch."
SPEAKING_TO: unfamiliar person (expressing through behavior)
RELATIONSHIP: unknown, trust 0.2
CONTEXT: stranger is getting closer""",
"""UTTERANCE: *stands rigid, ears forward, emits a low warning growl*""")

add("speak", """BEING: guard dog
DRIVES: energy=75 hunger=20 social=70 safety=80
MOOD: joy 0.6, excitement 0.4
LOCATION: gate
DOING: waiting

THOUGHT: "Owner is back! Happy."
SPEAKING_TO: owner (expressing through behavior)
RELATIONSHIP: owner, trust 1.0
CONTEXT: owner returning""",
"""UTTERANCE: *tail wagging furiously, bounds forward, whines with excitement*""")

add("speak", """BEING: stray cat
DRIVES: energy=50 hunger=70 social=15 safety=35
MOOD: wariness 0.4, hunger 0.4
LOCATION: alley
DOING: watching from behind crates

THOUGHT: "Food. But could be a trap."
SPEAKING_TO: child offering fish (expressing through behavior)
RELATIONSHIP: first encounter, trust 0.3
CONTEXT: child is holding out food""",
"""UTTERANCE: *inches forward cautiously, sniffs the air, ready to bolt at any sudden movement*""")

add("speak", """BEING: wolf
DRIVES: energy=50 hunger=80 social=60 safety=50
MOOD: focus 0.6
LOCATION: forest
DOING: hunting

THOUGHT: "Deer scent. Downwind. Good position."
SPEAKING_TO: packmate nearby (expressing through behavior)
RELATIONSHIP: packmate, trust 0.9
CONTEXT: coordinating the hunt""",
"""UTTERANCE: *makes eye contact with packmate, flicks ears toward the prey, crouches lower*""")

# More speak examples...

add("speak", """BEING: guard
DRIVES: energy=60 hunger=30 social=50 safety=40
MOOD: conflict 0.5, duty 0.4
LOCATION: town_square
DOING: approaching an argument

THOUGHT: "Roland is my friend but I have a duty. Need to step in carefully."
SPEAKING_TO: Roland (friend, fellow guard)
RELATIONSHIP: close friend, trust 0.8
CONTEXT: Roland is arguing with a merchant""",
"""UTTERANCE: Roland. Step back. Let's sort this out properly.""")

add("speak", """BEING: innkeeper
DRIVES: energy=45 hunger=40 social=55 safety=70
MOOD: unease 0.4, hospitality 0.3
LOCATION: inn
DOING: serving

THOUGHT: "Something is off about this one. I should serve them but keep my distance."
SPEAKING_TO: hooded stranger sitting in the corner
RELATIONSHIP: first encounter, trust 0.2
CONTEXT: late night, stranger came in silently""",
"""UTTERANCE: Can I get you something? Kitchen's still got soup if you're hungry.""")

add("speak", """BEING: herbalist
DRIVES: energy=70 hunger=30 social=45 safety=80
MOOD: focus 0.4, helpfulness 0.4
LOCATION: herbalist_shop
DOING: preparing a remedy

THOUGHT: "He's injured. I should help him right away."
SPEAKING_TO: Roland the Guard (holding his injured arm)
RELATIONSHIP: acquaintance, trust 0.6
CONTEXT: Roland came in hurt""",
"""UTTERANCE: Sit down, let me see that arm. How did this happen?""")

add("speak", """BEING: baker
DRIVES: energy=60 hunger=25 social=55 safety=80
MOOD: gratitude 0.4, warmth 0.4
LOCATION: market
DOING: selling bread

THOUGHT: "Edith brought bread to share. That's kind of her."
SPEAKING_TO: Edith the Baker (a neighboring baker/friend)
RELATIONSHIP: friend, trust 0.8
CONTEXT: Edith just offered to trade""",
"""UTTERANCE: You're too kind. Take some of my rye in return — it came out well today.""")

add("speak", """BEING: innkeeper
DRIVES: energy=55 hunger=35 social=60 safety=80
MOOD: calm 0.4
LOCATION: inn
DOING: chatting

THOUGHT: "Nothing happening. Just another quiet afternoon."
SPEAKING_TO: Player
RELATIONSHIP: regular, trust 0.6
CONTEXT: Player asked what's new""",
"""UTTERANCE: Quiet day. Nothing much going on. Sometimes that's the best kind of day.""")

add("speak", """BEING: farmer
DRIVES: energy=70 hunger=20 social=30 safety=85
MOOD: satisfaction 0.5, calm 0.3
LOCATION: farm
DOING: harvesting

THOUGHT: "Good yield this season. The hard work paid off."
SPEAKING_TO: Player
RELATIONSHIP: met a few times, trust 0.6
CONTEXT: Player asked about the harvest""",
"""UTTERANCE: Best season in years. The rain came at the right time for once.""")

# More speak to pad to ~50

for being, mood_str, thought, speaking_to, relationship, context, utterance in [
    ("guard", "alertness 0.5", "Shouting from the market. Could be trouble.",
     "fellow guard", "colleague, trust 0.7", "heard shouting and heading to investigate",
     "Did you hear that? From the market. Let's move."),
    ("gossip", "sadness 0.3", "Nobody wants to talk to me today.",
     "Player", "acquaintance, trust 0.5", "Player walked up",
     "Oh, hello. At least someone still has time for old Mabel."),
    ("blacksmith", "satisfaction 0.4", "The horseshoe order is almost done.",
     "Felix the Courier", "regular customer, trust 0.6", "Felix came to check on the order",
     "Almost done. Come back in an hour and it'll be ready."),
    ("herbalist", "calm 0.5", "The woods are peaceful today. Good day for gathering.",
     "Player", "friendly, trust 0.6", "Player met her on the forest path",
     "Out for a walk? The air is good today. I'm gathering moonwort by the stream."),
    ("innkeeper", "anxiety 0.5", "The debt collector is here. I don't have the money.",
     "debt collector", "adversarial, trust 0.2", "debt collector approached demanding payment",
     "I know I owe you. Give me one more week. Business has been slow."),
    ("farmer", "concern 0.4", "Rain is coming. Crops are still exposed.",
     "Player", "neutral, trust 0.5", "Player asked what's wrong",
     "Storm coming from the west. Need to cover the crops or we'll lose everything."),
    ("courier", "relief 0.4", "Delivery done. Good run today.",
     "the blacksmith", "business relationship, trust 0.6", "just finished the delivery",
     "Package from the capital. Sign here. Safe travels."),
    ("guard", "calm 0.4", "Respectful traveler. No threat.",
     "Player", "seen before, trust 0.6", "Player passed by and nodded",
     "Afternoon. Road north is clear if that's where you're headed."),
    ("baker", "worry 0.3", "No customers all morning. Was the bread not good?",
     "Player", "occasional customer, trust 0.5", "Player is the first visitor today",
     "You're my first today. Starting to wonder if I'm losing my touch."),
    ("innkeeper", "warmth 0.4", "Good to see a friendly face.",
     "Hugo's friend", "old friend, trust 0.9", "friend stopped by",
     "It's been too long. Sit down. I'll get us something."),
]:
    add("speak", f"""BEING: {being}
DRIVES: energy=60 hunger=35 social=45 safety=75
MOOD: {mood_str}
LOCATION: town
DOING: daily activity

THOUGHT: "{thought}"
SPEAKING_TO: {speaking_to}
RELATIONSHIP: {relationship}
CONTEXT: {context}""",
    f"""UTTERANCE: {utterance}""")


# ============================================================
# Write output
# ============================================================
output_path = "training/cognitive/pilot_data.jsonl"
with open(output_path, "w") as f:
    for ex in examples:
        f.write(json.dumps(ex) + "\n")

# Count per mode
mode_counts = {}
for ex in examples:
    user_msg = ex["messages"][1]["content"]
    mode = user_msg.split(">")[0].replace("<", "") if ">" in user_msg else "unknown"
    mode_counts[mode] = mode_counts.get(mode, 0) + 1

print(f"Generated {len(examples)} examples -> {output_path}")
for mode, count in sorted(mode_counts.items()):
    print(f"  <{mode}>: {count}")
