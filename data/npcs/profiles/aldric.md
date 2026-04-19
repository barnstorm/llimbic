# Aldric — Farmer

**Role in Story:** Farmer  
**Persona source:** `data/npcs/aldric.json`

---

## Snapshot

Aldric is the only NPC whose neural bias directly depletes a drive: `sense_at_work → drive_energy (-0.01)`. Being at work costs him energy. He starts at 85 energy but it drains faster when he is actively farming than during any other NPC's work cycle. He is the NPC most vulnerable to the energy-override condition (energy<20) if his schedule runs long or his farm chunks extend without rest. His emotion baseline (relief 0.3, optimism 0.3) describes a man who expects difficulty and is glad when it doesn't arrive. The blight two years ago is not backstory decoration — it is the structural origin of his caution and his trust architecture. He trusts Ivy (0.6) and Edith (0.55) but has no direct relationship with Roland or Greta.

---

## Behavioral Patterns

- **sense_at_work → energy (-0.01):** Every tick at the farm location, energy decreases beyond the normal baseline drift. The cumulative effect of two 6-hour and 4-hour farm chunks in a day is measurable energy depletion. This is the only NPC whose work location actively costs them. It reflects physical labor. If the inn meal slot (1.5h, 0.4) is skipped due to interruption, his energy may approach override territory by late afternoon.
- **Energy at 85 at start but degrading:** He begins near the top but is on a downward arc throughout the day. His energy recovery depends on the inn meal slot completing successfully. This makes him the most schedule-dependent NPC for basic resource maintenance.
- **Social at 30:** Low, consistent with solitary farm work. He does not seek social interaction and won't hit the social override threshold in normal conditions.
- **Safety at 80:** High but carries a trauma-shaped logic. The blight created a catastrophic safety failure; his current 80 represents rebuilt confidence. A second crop failure or unusual environmental event would likely generate a disproportionate safety-drive spike.
- **Two farm object targets:** `farm_plow_01` (use, morning) and `farm_trough_01` (examine, afternoon). These are different action types — "use" for active work, "examine" for checking status. The trough examination suggests he monitors livestock water levels. If the trough is empty or in a problem state, he injects a concern.
- **Emotion baseline (relief 0.3, optimism 0.3):** Relief is reactive — it requires a prior threat or expectation of failure to make sense. His low-level chronic relief suggests he is always marginally expecting something to go wrong. Optimism softens this into functional patience rather than paralysis.

---

## Voice Markers

Slow, deliberate. Weather and season references in almost every statement. He does not rush to a conclusion — he establishes conditions first. His sentences have a conditional or temporal structure: "when X happens, then Y."

- **"Good weather for crops today."** — His greeting evaluates atmospheric conditions before acknowledging the person. The world's physical state comes before social protocol.
- **"Soil's been dry. Need rain soon."** — Two declarative sentences. First: observation. Second: implication stated as need. He does not say "I hope it rains" — he says rain is needed, as if this is a fact the world should attend to.
- **"Ivy says the herbs near the creek are dying. Bad sign."** — He quotes his highest-trust contact as authority. "Bad sign" is his superstitious framing — not "this means X mechanically" but "this is an omen." He treats environmental signals as predictive but not fully explicable.

Avoid: urgency, excitement, complex social maneuvering. He speaks at the pace of growth: slow, grounded, sometimes ominous. He is not gloomy — he is careful.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Ivy | 0.6 | Highest trust in his roster. She gathers herbs from his farm; he treats her environmental knowledge as authoritative. They share a domain (growing things, soil, seasons) and a pace. Probably the most natural friendship in the cast. |
| Edith | 0.55 | Supply relationship. His produce goes to her bakery. Trust built through reliable transactions. Not close, but stable. |
| Hugo | 0.5 | The inn is his midday meal stop. Functional trust. He likely shares harvest information at the inn counter; Hugo files it as market intelligence. |

Unspecified: Roland (no relationship). The guard and the farmer share no relationship value despite both being concerned with environmental threats (east road, crop health). This is a gap — Roland's night observations and Aldric's crop concerns could be productive shared-belief territory if trust were established. Currently, this connection can only form through a third party (Hugo at 0.5 to both, or Ivy at 0.6 to Aldric).

---

## Emotional Fingerprint

Baseline: `relief 0.3, optimism 0.3`. Relief is structurally the most interesting baseline emotion in the cast — it is the only emotion that requires a counterfactual (relief = something bad didn't happen). Aldric's steady low-level relief means his L2 engine continuously references an imagined failure scenario as baseline calibration. He is emotionally anchored to what *didn't* go wrong.

L2 modulation: optimism raises approach tendency (he will move toward the field rather than away from it). Relief has no clean modulation mapping — it may operate as a mild suppressor of fear, keeping him functional despite his superstitious baseline. When relief disappears (during actual crop problems), fear is the likely replacement, which will spike interruption_sensitivity and potentially trigger an immediate replanning event.

Spike triggers: `dry` (weather), `dying` (botanical), `blight` (historical reference in tagged events), `empty` (trough). His gossip vocabulary includes "bad sign" — an evaluation term that will tag events as high-salience in his memory system even when the raw event is minor.

---

## Schedule Logic

Four chunks, three locations. The farm dominates (10 of ~13.5 waking hours). The market slot (2h, 0.7) is his only regular off-farm commitment — he sells produce and collects information. The inn meal (1.5h, 0.4) is the shortest chunk and lowest priority, making it the first casualty of any disruption. This is dangerous given that the inn meal is his primary energy recovery window during the day.

The afternoon farm chunk uses `farm_trough_01` (examine rather than use). The difference between "use" (active exertion) and "examine" (observation) in the afternoon may reflect energy depletion: by the afternoon he is monitoring rather than physically working. This fits the energy-depletion bias — he conserves late in the day.

Interruption pattern: low during farm chunks (high priority, 0.9 and 0.8). Moderate during market. High during inn (0.4 priority, but this is also when social propagation with Hugo and other inn visitors is possible).

---

## Stress Signature

Aldric's neurogenesis will specialize toward **stress neurons** first. The `sense_at_work → energy (-0.01)` bias means he regularly approaches low-energy states — and if those states persist, frustration builds toward the neurogenesis threshold. Over time, he will develop stress neurons that inhibit frustration specifically at the farm location, which makes him seem more resilient at work than his energy level warrants. Behaviorally: he keeps working even when he looks exhausted.

Novelty neurons are plausible if weather-related events (dry soil, unusual growth) generate sustained unfamiliar object states at the farm. His `farm_plow_01` and `farm_trough_01` becoming repeatedly problematic (dry trough) would drive novelty neuron growth targeting farm-object examination.

Reward neurons will fire when the inn meal successfully restores energy after an energy override (drive recovery event). Over time, the inn-meal path becomes Hebbian-reinforced as a recovery signal.

Primary concern trigger: `farm_trough_01` (empty/dry) or crop objects in degraded state. His blight history means he will assign maximum salience to plant-health problem events — higher than other NPCs would for equivalent object degradation.

---

## Open Questions / Gaps

- **No `sensor_profile` field.** A farmer has wide-open visual field (open farmland) but is occupied with ground-level focus. Suggest: wide arc (100-120deg), moderate range, high attention to nearby ground-level objects. Hearing may be attenuated during plow use (ambient noise).
- **No somatic fingerprint.** Somatic tags: `[tired, warm, grounded]` during farm work; `[hungry, heavy]` before inn meal; `[relieved, full]` after. The energy depletion bias makes his somatic state uniquely dynamic across the day.
- **No vagal gate thresholds.** His relief/optimism baseline suggests moderate parasympathetic regulation — he is not jumpy. But the blight trauma implies a hair trigger for crop-health threat events specifically. His vagal gate should be asymmetric: resistant to social/minor threats but vulnerable to environmental/agricultural ones.
- **Energy drain bias is the only depleting-drive bias in the cast.** This creates a unique mechanical situation: Aldric actually gets tired from working, unlike Edith who works for 6 hours without a drive cost. The design question is whether this is intentional differentiation (physical labor vs. skilled craft) or an oversight. Document explicitly.
- **No Roland relationship.** Two NPCs with threat-awareness orientations (east road threats, crop health threats) with no trust channel between them. Is this intentional isolation? The only path to belief sharing is through Hugo (0.5 trust to both) — a slow, unreliable channel.
- **Apple inventory (2 apples).** He is the only NPC with food in his starting inventory who doesn't run a food business. Are these for personal consumption or trade? The hunger mechanics should clarify whether NPCs consume their own inventory items.

---

## Thematic Weight

Aldric is the town's long memory. He has been here three generations. He lost a crop and survived it. His patient, weathered presence is the town's anchor to time — he measures in harvests, not hours. His superstition is not ignorance; it is pattern recognition from decades of watching the land behave in ways that people don't always track. The emergent story potential: when Aldric says it's a bad sign, it usually is. He is the first to notice a slow catastrophe and the last anyone thinks to ask.
