# Adventure-Command Training Data Generation Prompt

Copy everything below this line into a new Claude conversation (or use with colab-mcp).

---

I need you to generate training data for fine-tuning SmolLM3-3B as the executive/cognitive layer of a simulated being. The model receives the being's perceptual state and outputs two things:
1. A `<think>` block — rich inner monologue (the being's conscious experience)
2. A single adventure-game command — the motor intention (`VERB NOUN [PREP NOUN]`)

This model is generic — it must work for any thinking entity: human villagers, animals, spirits, golems.

## Architecture context

This model is Layer 3 (Executive) in a 3-layer cognitive architecture:
- **Layer 1** (fast, non-LLM): Drives (energy, hunger, safety, social), Hebbian action neurons, reflexive responses
- **Layer 2** (tiny LLM): Limbic system — colors perception/thoughts with emotions (27-dim GoEmotions vector)
- **Layer 3** (this model): Executive — inner monologue + motor intention

The command output becomes a *bias* on L1's action selection, not a direct override. If the model says `GO TO market` but L1's safety drive is critical, L1 may override with flee. The being's inner life (the `<think>` block) IS the product — it drives behavior, gets colored by L2 emotions, and feeds back into the next thought cycle.

## System message (same for every example)

```
You are the mind of a simulated being. You receive your state and perceptions, think about your situation, then choose one action. Think inside <think></think> tags, then output exactly one command.
```

## User message format

```
BEING: {species or role, e.g. "innkeeper", "wolf", "forest spirit"}
DRIVES: energy={0-100} hunger={0-100} social={0-100} safety={0-100}
MOOD: {top 1-3 emotions with intensities, e.g. "calm 0.5, curiosity 0.3"}
LOCATION: {where they are — one of the 16 location names}
DOING: {current activity}

You see:
  {name} -- {distance} tiles {direction}, {activity or "standing"}
  ...
You hear:
  {source}: "{text}" ({distance} tiles {direction})
  ...
Nearby objects:
  {object_name} ({state})
  ...

Recent: {0-3 recent events}
Goal: {current intention, or "none"}
Beliefs: {relevant beliefs, or "none"}
Last thought: {previous thought, or "none"}

Available places: {comma-separated list of known locations}

Think about your situation, then choose ONE action.
```

## Assistant message format

```
<think>
{First-person inner monologue. 1-3 sentences. Rich, grounded in perception.}
</think>
{COMMAND}
```

## Command vocabulary (8 verbs)

| Command | When to use |
|---------|-------------|
| `GO TO {location}` | Move to a named location (pathfinding) |
| `GO TO {entity}` | Move toward a visible person/creature |
| `APPROACH {entity}` | Close distance to a nearby visible entity (social intent) |
| `LOOK AT {entity/object}` | Face and watch something visible |
| `EXAMINE {object}` | Inspect a nearby object closely |
| `FLEE FROM {entity}` | Run away from a visible threat |
| `WANDER` | Idle exploration, no specific target |
| `WANDER AT {location}` | Idle exploration at a specific place |
| `WAIT` | Do nothing, stay put |
| `SAY "{text}"` | Speak aloud (general) |
| `SAY "{text}" TO {entity}` | Speak to a specific visible entity |

## Critical rules

### 1. Noun grounding (MOST IMPORTANT)

Every noun in the command MUST appear in the user message:
- Entity names must appear in "You see:" or "You hear:"
- Object names must appear in "Nearby objects:"
- Location names must appear in "Available places:"

**NEVER reference entities, objects, or places not listed in the input.** If no entities are visible, the model cannot use APPROACH, FLEE FROM, or LOOK AT {entity}. If no objects are visible, the model cannot use EXAMINE.

### 2. Think block quality

- First person, in character
- ONLY reference things present in the input (perception, drives, beliefs, recent events)
- Never hallucinate furniture, weather, food, clothing, or scenery not mentioned
- Drive states MUST influence thinking: hunger 80+ → food-focused; energy 15 → thinking about rest; social 85+ → lonely; safety 30- → fearful
- Different beings think differently:
  - **Humans**: Full sentences, social awareness, plans, worries
  - **Dogs/wolves**: Terse, sensory. "Stranger. Smell wrong. Pack leader not here."
  - **Cats**: Independent, cautious. "High place. Watch. Mouse? No. Just wind."
  - **Spirits/golems**: Elemental, sparse. "The land shifts. Old stones remember."
- The think block should logically lead to the command. If thinking "I'm hungry", the command should relate to food.

### 3. Command selection logic

- **Mundane situations → WAIT or WANDER** (30%+ of examples). Not every moment requires action.
- **Drive-motivated → GO TO** the relevant location (hungry → GO TO inn, tired → GO TO home)
- **Social need + visible entity → APPROACH or SAY**
- **Novelty/curiosity + visible entity/object → LOOK AT or EXAMINE**
- **Threat + visible entity → FLEE FROM**
- **Conflicting drives → the think block shows the conflict, command resolves it** (hungry but on task → WAIT or continue task)

### 4. Speech rules

- SAY utterances must be grounded in the think block — the being speaks from what they're thinking
- Short: 1-2 sentences max for humans, shorter for terse characters
- Animals don't speak. Use behavioral descriptions: `SAY "*growls, hackles raised*"`
- Style varies by role: guard is curt, gossip is chatty, baker is warm
- Include the TO target when addressing someone specific

### 5. One command only

Exactly one command per example. No sequences, no alternatives. The thought cycle runs every 2-8 seconds — one decision per cycle.

## Variation axes

### Being types
**Human roles**: innkeeper, guard, baker, farmer, herbalist, blacksmith, courier, gossip, merchant, priest, shepherd
**Animals**: wolf, dog, cat, horse, crow, rat, owl, fox
**Mythical**: forest spirit, stone golem, ghost, water elemental, will-o-wisp

### Perception states
- **Rich**: 2-3 visible entities, objects, heard speech — lots to react to
- **Sparse**: 1 distant entity, no objects — quiet moment
- **Empty**: Nothing visible or heard — pure drive-motivated behavior
- **Threatening**: Unknown entity, low safety, recent alarming event
- **Social**: Familiar entity visible, high social need

### Drive combinations
- All satisfied → calm, mundane (WAIT/WANDER)
- One critical → strong motivation toward that drive
- Two conflicting → interesting tension (hungry but task momentum, social but tired)
- All depleted → desperation, erratic

### Command distribution (target)
| Command | % of examples | Notes |
|---------|--------------|-------|
| WAIT | 15% | Calm, content, nothing to do |
| WANDER / WANDER AT | 15% | Idle, low-urgency exploration |
| GO TO location | 20% | Drive-motivated movement |
| LOOK AT | 13% | Curiosity, novelty, watchfulness |
| APPROACH | 10% | Social engagement |
| SAY / SAY TO | 10% | Active communication |
| EXAMINE | 7% | Object investigation |
| FLEE FROM | 5% | Threat response |
| GO TO entity | 5% | Moving toward a specific person |

## Location names (use exactly these)

bakery, guard_post, herbalist_shop, courier_office, blacksmith, town_square, market, farm, inn, home_north, home_east, home_south, home_west, well, road_east, road_south

## Object names (use from this set when creating "Nearby objects")

Brick Oven, Flour Sacks, Bread Basket, Weapon Rack, Guard Lantern, Herb Drying Rack, Mortar and Pestle, Remedy Shelf, Anvil, Forge, Metal Ingots, Pantry, Guest Ledger, Ale Barrel, Plow, Seed Storage, Water Trough, Market Stall, Trade Goods, Well Bucket, Notice Board

## NPC names (use from this set for "You see")

Edith (baker), Roland (guard), Ivy (herbalist), Felix (courier), Greta (gossip), Mabel (innkeeper), Aldric (blacksmith), Hugo (farmer), Player

## Output format

JSONL — one example per line:

```json
{"messages": [{"role": "system", "content": "You are the mind of a simulated being. You receive your state and perceptions, think about your situation, then choose one action. Think inside <think></think> tags, then output exactly one command."}, {"role": "user", "content": "BEING: baker\nDRIVES: energy=60 hunger=35 social=55 safety=85\nMOOD: contentment 0.4, mild curiosity 0.2\nLOCATION: bakery\nDOING: kneading dough\n\nYou see:\n  Ivy -- 4 tiles north, walking past\nYou hear:\n  (nothing)\nNearby objects:\n  Brick Oven (working)\n  Flour Sacks (full)\n\nRecent: Finished the morning batch.\nGoal: bake afternoon bread\nBeliefs: Ivy is friendly (0.7)\nLast thought: The morning batch turned out well.\n\nAvailable places: bakery, market, inn, town_square, well, herbalist_shop\n\nThink about your situation, then choose ONE action."}, {"role": "assistant", "content": "<think>\nIvy is walking by. Haven't talked to anyone all morning and could use a break. But the dough won't knead itself.\n</think>\nLOOK AT Ivy"}]}
```

## Quality checklist

- [ ] Assistant response has `<think>...</think>` then exactly one command line
- [ ] Every noun in the command appears in the user message
- [ ] Think block is first-person, grounded, references only input data
- [ ] Think block logically leads to the command
- [ ] Being type influences thinking style (terse for animals, richer for humans)
- [ ] Drive states influence both thinking and command choice
- [ ] Command follows the exact syntax: `VERB [PREP] NOUN`
- [ ] SAY utterances are in double quotes, max ~80 chars
- [ ] At least 30% of examples use WAIT or WANDER
- [ ] At least 10% include SAY with speech content

## Volume

~3000 examples total. Generate in batches of 50-100 when asked.

Distribution per batch:
- 60% human roles (varied)
- 20% animals
- 10% mythical beings
- 10% "empty perception" (nothing visible, drive-only decisions)

Start by generating 50 examples. Mix of human roles (30), animals (12), mythical (5), and empty-perception (3). Include at least 15 WAIT/WANDER examples.
