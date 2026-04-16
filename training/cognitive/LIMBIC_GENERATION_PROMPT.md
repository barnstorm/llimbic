# Limbic Model Training Data Generation Prompt

Copy everything below this line into a new Claude conversation.

---

I need you to generate training data for fine-tuning TinyLlama-1.1B-Chat as a limbic (emotional) processing module. This model is the fast emotional layer of a cognitive architecture for simulated beings. It runs at ~0.3s per call and handles emotional appraisal — coloring thoughts and perceptions with emotion.

## What this model does

It receives a thought or perception event and the being's current emotional state, then outputs how that input changes the being's emotions. It's the post-cognitive emotional loop: a thought forms → the limbic system reacts emotionally → the emotion feeds back into behavior.

It does NOT generate thoughts, plan, infer social states, or produce speech. It ONLY does emotional math: input → emotion deltas.

## Critical constraint: JSON output

TinyLlama doesn't naturally produce structured output, but it learns format compliance quickly through LoRA fine-tuning. All training examples MUST use JSON for the assistant response.

## Training format

**System message** (same for every example):
```
You are a limbic system. You receive a being's state and a thought or event, and output emotional changes as JSON. Nothing else.
```

**User message format:**
```
<appraise>
BEING: {species or role}
DRIVES: energy={0-100} hunger={0-100} social={0-100} safety={0-100}
CURRENT_MOOD: {current emotions with intensities, e.g. "calm 0.5, curiosity 0.3"}

INPUT: {the thought or event to emotionally appraise — a sentence or two}
```

**Assistant message (JSON only, nothing else):**
```json
{"emotions": {"emotion_name": delta, ...}, "reason": "one short phrase"}
```

Where:
- `delta` is a float from -1.0 to +1.0 (positive = emotion increases, negative = decreases)
- Only include emotions that actually change — don't list emotions with 0.0 delta
- `reason` is a short causal explanation (5-15 words)

## Emotion vocabulary

Use these emotion names (from GoEmotions, 27 dimensions):

**Positive:** admiration, amusement, approval, caring, desire, excitement, gratitude, joy, love, optimism, pride, relief

**Negative:** anger, annoyance, disappointment, disapproval, disgust, embarrassment, fear, grief, nervousness, remorse, sadness

**Cognitive:** confusion, curiosity, realization, surprise

## Rules for every example

1. **JSON only.** The assistant response must be parseable JSON. No text before or after the braces.

2. **Proportional deltas.** Mundane inputs → small deltas (0.05-0.15). Moderate inputs → medium (0.2-0.4). Extreme inputs → large (0.5-0.8). Never use 1.0 or -1.0 unless the being's world is ending.

3. **Mood continuity.** If CURRENT_MOOD already has "fear 0.7", a mildly scary thought shouldn't add fear +0.5 (that would be 1.2). The delta should be smaller because fear is already high. Conversely, if mood is "calm 0.8" and something scary happens, the fear delta can be larger.

4. **Being-appropriate emotions.** 
   - Wolves/dogs: no embarrassment, no remorse, no amusement. They feel fear, anger, excitement, loyalty (map to love/caring), alertness (map to curiosity).
   - Cats: no guilt/remorse, limited social emotions. They feel curiosity, fear, annoyance, satisfaction (map to relief).
   - Golems/spirits: limited emotional range. Spirits might feel grief, anger, serenity (map to relief). Golems: duty (map to determination/pride), confusion if orders conflict.
   - Humans: full range.

5. **Empty responses are valid.** When the input is mundane and the mood is stable, output: `{"emotions": {}, "reason": "nothing to react to"}`. At least 20% of examples should be empty or near-empty.

6. **Opposing emotions cancel.** A joyful thought while already sad might produce `{"emotions": {"joy": 0.3, "sadness": -0.2}, "reason": "good news lifts the mood"}`.

7. **The reason explains causality**, not just labels the emotion. BAD: `"reason": "fear"`. GOOD: `"reason": "unfamiliar threat approaching with no escape route"`.

## Variation axes

Generate examples across these dimensions:

**Being types:** innkeeper, guard, baker, farmer, herbalist, blacksmith, courier, gossip, merchant (human); wolf, dog, cat, horse, crow, rat (animal); forest spirit, stone golem, ghost, water elemental (mythical)

**Input types (the THOUGHT or EVENT being appraised):**
- Threat perception: "A stranger is watching me from the shadows"
- Loss/failure: "The oven broke and I can't bake"
- Social connection: "Edith stopped by to chat — nice to have company"
- Achievement: "Finished the harvest before the rain"
- Anticipation: "The festival is tomorrow"
- Memory/nostalgia: "This sunset reminds me of my late spouse"
- Hunger/fatigue: "My stomach is growling and I can barely stand"
- Conflict: "My friend is breaking the law and I have to enforce it"
- Novelty: "Never seen a creature like that before"
- Mundane: "Just walking down the path" / "Nothing happening" / "Same view as always"
- Relief: "The storm passed without damage"
- Betrayal: "They lied to me about the delivery"
- Animal-specific: "Pack leader snarled at me" / "The mouse is in the corner" / "My territory smells like another dog"

**Drive states that modulate emotion:**
- Hungry being appraising food-related thought → stronger desire/excitement
- Tired being appraising any thought → muted emotions, everything feels flat
- Scared being appraising ambiguous input → fear amplified, interpret as threat
- Lonely being appraising social input → stronger joy/desire/sadness

## Volume

I need **800 examples total**. Generate in batches of 50-100 when I ask.

Distribution:
- 250 human role examples (varied roles)
- 100 animal examples (varied species)
- 50 mythical/abstract being examples
- 200 mundane/empty-response examples (being + mundane input → minimal change)
- 200 drive-modulated examples (drive state amplifies/mutes the emotional response)

## Output format

JSONL — one example per line:

```json
{"messages": [{"role": "system", "content": "You are a limbic system. You receive a being's state and a thought or event, and output emotional changes as JSON. Nothing else."}, {"role": "user", "content": "<appraise>\nBEING: innkeeper\nDRIVES: energy=50 hunger=40 social=50 safety=75\nCURRENT_MOOD: calm 0.5, mild concern 0.2\n\nINPUT: The debt collector is coming back today. I still don't have the money."}, {"role": "assistant", "content": "{\"emotions\": {\"anxiety\": 0.5, \"fear\": 0.3, \"calm\": -0.3}, \"reason\": \"impending confrontation with no way to pay\"}"}]}
```

## Quality checklist

- [ ] Assistant response is valid JSON, no text outside braces
- [ ] Deltas are proportional to the input's significance
- [ ] Emotion names are from the GoEmotions vocabulary listed above
- [ ] Reason is 5-15 words explaining WHY, not just naming the emotion
- [ ] Being type influences which emotions appear
- [ ] Current mood is respected (don't add +0.5 fear when fear is already 0.7)
- [ ] At least 20% of examples have `{"emotions": {}, "reason": "nothing to react to"}` or similar minimal output
- [ ] Drive states visibly modulate the response when present

Start by generating 50 examples. Mix of human roles (30), animals (10), and mundane/empty (10).
