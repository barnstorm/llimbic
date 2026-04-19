# Roland — Guard

**Role in Story:** Guard  
**Persona source:** `data/npcs/roland.json`

---

## Snapshot

Roland is the only NPC designed to never sleep. His `go_home_hour` is 99.0 — effectively infinite — and his night override locks him into a continuous town_square patrol. His drive profile is extreme: energy at 90, safety at 90, social at 20. He is simultaneously the most physically capable and the most socially inert NPC in the cast. What makes his internal state unusual is the contradiction in his neural biases: `drive_safety → action_observe (+0.03)` and `drive_safety → action_flee (-0.03)`. High safety doesn't make Roland feel secure — it makes him watch harder and suppresses any impulse to run. He is wired to stand his ground and scan.

---

## Behavioral Patterns

- **Safety at 90 + flee bias -0.03:** Roland's flee tendency is actively suppressed by his highest drive. He will not retreat from threats that would send other NPCs running. The NPCBrain flee condition requires `trust < 0.2` AND `flee tendency > 0.5` — his negative bias makes this threshold nearly unreachable unless both his trust completely collapses and his safety drive inverts.
- **Observe bias +0.03 (strongest in cast):** Roland generates the most observe-action activations of any NPC. He will pause more frequently to examine entities and environments. Combined with his 5-chunk patrol schedule, he spends more time in OBSERVE state than anyone except possibly Mabel.
- **Energy at 90:** Highest energy default in the cast (tied roughly with Felix at 85). He will not hit energy-override conditions in normal operation. His military backstory is mechanically expressed through this reserve.
- **Social at 20:** Just above the 20-point floor. He does not seek interaction and will rarely hit the social>85 override threshold. His two patrol chunks in social locations (town_square, market) generate proximity events but not social drive expression.
- **No starting inventory:** Roland carries nothing. He references a weapon rack (`guard_weapon_rack_01`, examine action) in his morning chunk but starts without items. He is the only NPC with zero starting items.
- **Night override is active patrol:** `{"location": "town_square", "duration": 8.0, "priority": 0.9}`. While other NPCs are in home/sleep context, Roland's social propagation windows, perception queries, and memory events all continue. He is the only NPC generating world observations through the night cycle.
- **5-chunk day, 3 distinct locations:** Guard post → town_square → market → road_east → guard post. The east road chunk (3h, 0.8) is the only time he leaves the core town area. This is his highest exposure-to-novelty window.

---

## Voice Markers

Clipped and formal. Declarative short sentences. No hedging, no small talk, no metaphor. He speaks in present-tense assessments of conditions.

- **"Stay safe, traveler."** — Two words of imperative, one of address. No greeting, no warmth, no question. Categorizes the listener (traveler = unknown/transient), issues instruction, ends.
- **"Roads have been too quiet. That worries me."** — Note the construction: observation first, evaluation second, as separate sentences. He does not embed concern into the observation. He reports, then interprets. This is a diagnostic pattern.
- **"On patrol. Make it quick."** — Subject dropped entirely. State reported as fact. Urgency is bureaucratic, not emotional.

Avoid: exclamations, questions (unless tactical), warmth, metaphor, personal disclosure. He gives information. He does not offer it.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Greta | 0.6 | She made him a blade (implied by her gossip line: "Roland ordered a new blade last week"). Material transaction elevated to trust. She is reliable and does not waste his time. |
| Hugo | 0.5 | The inn is an intelligence node. Travelers pass through; Hugo tracks them. Roland values Hugo's observational position, not his personality. |

Unspecified relationships: Roland and Mabel represent the sharpest potential friction in the cast. Mabel is animated and conspiratorial; Roland is stoic and duty-bound. His low social drive means he will not approach her, but her schedule places her in town_square during his patrol windows — repeated proximity without interaction will generate neutral-to-negative trust drift over time unless their dialogue generates positive affect. Roland and Felix share no relationship value — the courier crosses his patrol routes but Roland has no reason to prioritize him.

---

## Emotional Fingerprint

Baseline: `pride 0.3, fear 0.2`. The presence of fear at 0.2 is architecturally significant — it is not a flaw to suppress but the engine that keeps him scanning. His pride is not dominant enough to generate overconfidence spikes. Together they describe vigilance: he believes something could go wrong (fear) and that he is responsible for preventing it (pride).

L2 modulation: fear→interruption_sensitivity maps to higher alertness at his baseline level. He is easier to interrupt than his high momentum might suggest — a suspicious event will pull him off task more readily than energy or social pressures. Curiosity is absent from his baseline, so exploration_bias stays low unless an event fires the "discovered" keyword.

---

## Schedule Logic

Five chunks is the median chunk count for the cast. The shape is surveillance geometry: radiate out from post, cover commercial center, extend to road, return to post. The east road chunk is both highest mission-weight (0.8) and highest risk — it's the only location outside the social graph, where NPCs can't see each other and SocialPropagation can't pulse. Memory events from road_east will be his most unique information.

Night patrol creates an asymmetry: Roland accumulates observations during the sleep cycle that no other NPC can corroborate or replicate. When he reports "Saw something on the east road last night," he is the sole source. This is significant for social propagation trust dynamics — his information is unverifiable but his role-tag affinity (guard shares security events preferentially) means it propagates with high salience.

---

## Stress Signature

Roland's neurogenesis will specialize toward **stress neurons** and **novelty neurons** in competition. His safety drive is high but fear at 0.2 creates a low-frequency background that can become sustained if east-road patrol events accumulate without resolution. Novelty neurons are plausible if road_east consistently delivers unfamiliar stimuli (new entities, unusual objects). His observe bias means he generates more novelty exposure events than most NPCs.

The stress neuron pathway would inhibit his frustration — which fits: a soldier learns to suppress stress rather than express it. His behavioral signature under accumulated stress is not agitation but increased OBSERVE frequency and shorter reorientation pauses. He won't look broken. He'll look even more vigilant.

High-risk trigger: `guard_weapon_rack_01`. If the rack is empty or in a non-default state, he will inject a concern chunk with high priority. Given his role, this is the object most likely to generate a persistent unresolved concern.

---

## Open Questions / Gaps

- **No `sensor_profile` field.** A guard is the strongest candidate for a widened sensor profile. Suggested: vision_range 128px, vision_arc 110deg, hearing_sensitivity high. His patrol purpose is surveillance; default sensor parameters undersell his role.
- **No somatic fingerprint.** Somatic tags for Roland: `[alert, tense, steady]` during patrol; `[fatigued, vigilant]` during night override. Vagal gate should be defined with suppressed parasympathetic response — he should be slow to relax.
- **Vagal gate thresholds missing.** Given the three competing autonomic neurons (project_vagal_gate.md), Roland should have a pronounced sympathetic dominance that resists downregulation. His fear baseline suggests the vagal gate rarely fully closes.
- **No inventory, but references weapon rack.** Whether examining the rack produces an item is undefined. Object state mechanics for `guard_weapon_rack_01` need clarification.
- **Sleep never triggers.** Energy at 90 with no home-return means energy depletion over very long sessions could eventually force an override — but the persona does not account for this. Either Roland needs a passive energy recovery mechanic during patrol pauses, or his energy floor needs documentation.

---

## Thematic Weight

Roland is the town's anxiety made visible. His permanent wakefulness and observe-dominant neural architecture mean he is continuously processing the world as a threat environment. He is not paranoid — he is correct that something could go wrong, and he is the only one positioned to catch it early. Story pressure comes from what he sees on that east road, who he tells (Hugo at 0.5 trust, Greta at 0.6), and how long it takes the rest of the town to believe him. He is the early-warning system for emergent town-level events.
