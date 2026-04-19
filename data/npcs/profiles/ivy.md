# Ivy — Herbalist

**Role in Story:** Herbalist  
**Persona source:** `data/npcs/ivy.json`

---

## Snapshot

Ivy is the only NPC whose neural bias references sensory input rather than a drive or task state: `sense_loc_familiarity → action_observe (+0.02)`. She pays more attention to places she knows. This inverts the usual novelty-seeking pattern — familiar territory makes her more present, not less. Combined with the lowest social need (30) alongside Edith and Greta, and an emotion baseline of caring (0.4) and curiosity (0.3), she is a quiet, attentive NPC who processes her environment deeply but does not broadcast what she notices. She came from outside the town and her relationships are sparse but selectively deep.

---

## Behavioral Patterns

- **Familiarity → observe (+0.02):** When Ivy is at a location she has visited before (place_familiarity in her Layer1 dict), the observe tendency gains a small but consistent bonus. She looks more carefully in familiar spaces — her shop, the farm she visits daily. This is distinct from curiosity-driven exploration; she is attentive to *change* in known environments, not novelty.
- **Safety at 85:** Second-highest safety default in the cast after Roland (90). She is rarely in threat state. Combined with reclusive trait and low social drive, she has almost no reason to leave her comfort zone unless a drive or schedule chunk demands it.
- **Energy at 80, hunger at 20:** Typical mid-range values. No unusual drive pressures. Her day will rarely be disrupted by override conditions.
- **Social at 30 (override threshold 85):** Low. She schedules a town_square social window (2h, 0.4) as her only mid-day social outlet. Like Edith, this is the first chunk to yield under interruption. She does not drift toward people.
- **Schedule cross-location:** herbalist_shop → farm → town_square → herbalist_shop. The farm visit (2h, 0.6) creates a regular Aldric proximity event — they share the same space during a window when Aldric is also farming. Their relationship (0.6) likely formed through repeated proximity + shared domain (plants/soil).
- **Two object-targeted chunks:** `herb_mortar_01` (use) and `herb_remedy_shelf_01` (examine). When remedy_shelf is empty or mortar is broken, she injects concern chunks with priority. She will notice supply depletion before it affects anyone else.
- **Starting inventory: remedy.** She begins each day with at least one remedy item — she is the town's medical supply node. No mechanic for restocking is specified in the persona.

---

## Voice Markers

Soft-spoken and measured. Nature analogies. She speaks in complete sentences but keeps them short. Questions are genuinely curious, not rhetorical.

- **"Need a remedy? I have fresh stock."** — Offer without preamble, practical. The word "fresh" echoes Edith's bread vocabulary but carries a different weight: freshness here means potency, not warmth.
- **"Careful — I'm measuring a tincture."** — Her busy signal is a safety warning, not a dismissal. She is concerned about the work, not about the interruption.
- **"The farmer's herbs are coming in strong this year."** — Her gossip is observational and environmental, not personal. She talks about what plants are doing, not what people are doing.

Avoid: dramatic language, conspiratorial framing (Mabel's domain), direct confrontation. She redirects tension toward botanical context. When distressed she becomes more precise in her language, not less.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Aldric | 0.6 | Shared domain (plants, soil, growing things). She gathers from his farm; he quotes her as an authority on botanical signs. Probably the most reciprocal trust pair in the cast. |
| Mabel | 0.4 | Mabel's relationship list includes Ivy at 0.4. Ivy reciprocates at exactly that value. They are acquaintances who have found each other useful but not close. Mabel collects Ivy's observations as data; Ivy finds Mabel's social network useful for passive information gathering. Tension exists: Ivy guards her observations, Mabel wants to broadcast them. |

No other relationships specified. Hugo, Roland, Felix, Edith, Greta are at trust baseline. Ivy is the most relationally isolated NPC in the cast — two specified bonds, both at mid-range, no strong anchors.

---

## Emotional Fingerprint

Baseline: `caring 0.4, curiosity 0.3`. The same caring level as Edith, but paired with curiosity instead of joy. This produces a different modulation profile: where Edith's joy maps to high task_momentum, Ivy's curiosity maps to high exploration_bias. She is not task-locked; she is environment-attentive.

L2 behavior: curiosity→exploration_bias (higher) means she is more likely to pursue OBSERVE actions when off-task than Edith would be. Her caring baseline → help action tendency — when nearby NPCs are in distress, her help tendency receives a continuous low boost. She is likely to respond to social propagation events even without being directly addressed, if she's close enough to perceive the distress.

The absence of negative emotion in her baseline means her L2 engine rarely fires downward spikes unless she hits a specific trigger keyword. Her most likely spike triggers: "dying" (from botanical observation about herbs), "empty" (remedy shelf), "discovered" (curiosity spike).

---

## Schedule Logic

Four chunks, three locations. The farm detour (2h) is her most exposed schedule element — she leaves her high-familiarity shop and enters a different terrain type. Her observe bias activates at the farm once she has visited it several times, but initial visits will be lower-observe until familiarity accumulates.

The afternoon return to herbalist_shop with a different object (`herb_remedy_shelf_01`, examine vs morning's `herb_mortar_01`, use) suggests a workflow progression: prepare remedies in the morning, check supply status in the afternoon. If the shelf is depleted, she will inject a concern chunk. This makes her afternoon chunk the most narratively volatile.

Expected interruption pattern: low-to-moderate. Her priority 0.4 town_square slot makes her interruptible mid-day. Drive overrides are unlikely due to stable drive defaults. She will yield her social slot readily but defend her shop-work chunks.

---

## Stress Signature

Novelty neurons are Ivy's most likely neurogenesis specialization. Her low social drive means she spends less time in familiar social contexts and more time in low-familiarity observation states — the farm changes with seasons and weather, the east road sometimes delivers unfamiliar stimulus. Sustained low-familiarity (sensory novelty) is one of the neurogenesis triggers.

Reward neurons are her second likely specialization: when she successfully restocks the remedy shelf or completes a treatment object-action, drive recovery fires — reinforcing the shelf-examine pathway.

Stress neurons are unlikely unless she is repeatedly blocked from her shop (path obstruction, external locking during conflict). Her reclusive trait means being unable to reach her familiar, safe space is her highest stress scenario. Object `herb_remedy_shelf_01` is her primary concern trigger; `herb_mortar_01` is secondary.

---

## Open Questions / Gaps

- **No `sensor_profile` field.** Ivy as an observer of fine botanical detail would plausibly have sharper close-range vision — a narrower arc but better sensitivity within range. Alternatively, her time in the eastern woods suggests wide peripheral awareness. Needs decision.
- **No somatic fingerprint.** Somatic tags: `[calm, focused, attentive]` while working; `[uneasy, exposed]` during farm gather. The farm visit is her most out-of-comfort-zone moment and should have distinct somatic expression.
- **No vagal gate thresholds.** Her high safety default suggests a well-regulated vagal gate, but her reclusive trait implies she actively manages her arousal state. She should be quick to return to baseline but careful about entering high-arousal states.
- **Remedy restock mechanics undefined.** She starts with one remedy but no source of additional remedies is specified in the persona.
- **Mabel relationship asymmetry check.** Mabel lists Ivy at 0.4; Ivy lists Mabel at 0.4. Symmetric — but Mabel actively visits Ivy's social territory (bakery) and town_square simultaneously. The social propagation system will keep these two in proximity. Document whether Ivy is comfortable with this or treats it as mild intrusion.
- **Cognitive adventure-command interface alignment.** Ivy's `think` and `intend` commands from the SmolLM3 loop should lean heavily on observation and remediation — what she notices about plant states, NPC health, environmental changes. Her dialogue command output should avoid social drama framing.

---

## Thematic Weight

Ivy is the town's diagnostic layer — she notices things that others don't, and she interprets them through a longer timescale (seasonal, botanical). Her observation of Aldric's herbs dying is the only gossip line in the cast that reads as an omen rather than news. She carries the weight of slow knowledge: things that are wrong before anyone else knows they're wrong. Emergent story potential is highest when her quiet observations collide with Roland's surveillance data — two independent observers noticing the same slow degradation from different angles.
