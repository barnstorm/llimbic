# Hugo — Innkeeper

**Role in Story:** Innkeeper  
**Persona source:** `data/npcs/hugo.json`

---

## Snapshot

Hugo is the town's social hub and the NPC with the most inbound relationships. Four NPCs list him in their relationship dict (Edith 0.6, Roland 0.5, Mabel 0.6, Aldric 0.5, Felix 0.5); no other NPC is referenced by this many others. His neural bias (`sense_nearby_npcs → action_help, +0.03`) means that when other NPCs are nearby, he actively tends toward helping them — not because of a drive override, but because presence triggers helpfulness. He has the lowest energy default in the cast (70) and the latest closing hour (23:00), creating a characteristic pattern: he depletes across a very long day but never leaves until the inn is empty. His emotion baseline (amusement 0.3, joy 0.3) is the warmest in the cast but the amusement dimension signals something colder underneath: he reads people and finds them useful.

---

## Behavioral Patterns

- **sense_nearby_npcs → help (+0.03):** Hugo's help tendency rises whenever other NPCs are within sensory range. This is his most active connection — the inn is a high-NPC-density location, meaning this wire fires most of the day. He will consistently take OBSERVE + HELP action pairs when social propagation windows open near him. He is the NPC most likely to respond to another NPC's distress signal.
- **Energy at 70 (lowest in cast):** He begins each day with 30 points less energy than Roland. His energy default is just above the override threshold (20) in relative terms — his operating window is narrower. Combined with a 23:00 closing time and an 18-hour schedule (5+8+3 hours), he accumulates energy debt over long sessions.
- **Social at 15 (second-lowest in cast, above Mabel's 10):** Despite running the town's social hub, Hugo has a low social need. He does not need others — he processes them. His warmth is professional. The social override threshold (85) is nearly unreachable; he will not seek social contact out of need.
- **3-chunk day, all inn-location:** Hugo is the most location-stable NPC. He almost never leaves the inn except for a 2-hour market supply run (0.6 priority). His entire day is inn-oriented. This makes him the most predictable NPC spatially but the most information-rich: every NPC who visits the inn (Greta, Aldric, Roland — all have inn slots) deposits their current state into Hugo's memory via social propagation.
- **Two object targets:** `inn_pantry_01` (examine, morning prep) and `inn_ale_barrel_01` (examine, run-the-inn block). The ale barrel starts empty (MEMORY.md: `inn_ale_barrel_01` starts in non-default empty state). He will inject a restock concern within the first hours of play — one of three predetermined object-problem events.
- **Night behavior: go_home_hour 23.0.** He stays open 2 hours later than everyone else. During 21:00-23:00, he is the only social NPC still active (Roland is also awake but on patrol). This window is the inn's most intimate period: late travelers, stray conversations, information from Roland's overnight observations.

---

## Voice Markers

Warm but transactional. Every sentence steers back toward the inn's function: comfort, food, seat, room. He is interested in people in the same way a merchant is interested in inventory — with genuine care for condition and strong attention to value.

- **"Welcome! Pull up a chair."** — No name, no question. Immediate command toward comfort. He skips evaluation (who are you, why are you here) and goes straight to hospitality. This is a sales technique.
- **"The ale barrel's running low again."** — The word "again" is critical. It implies this is a pattern he tracks with resignation. His complaint is a supply-chain concern, not an emotional one. He is monitoring the business.
- **"A stranger passed through last night. Didn't stay long."** — His gossip is intelligence framed as observation. "Didn't stay long" is an evaluation — a guest who leaves early is anomalous and worth noting. He files people by their deviation from expected behavior.

Avoid: excessive warmth, over-explanation, personal disclosure. His warmth has a ceiling set by commercial utility. He does not form attachments; he forms habits around people. When someone is no longer useful or present, he moves on cleanly.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Edith | 0.6 | Daily bread supply. She provides what his breakfast guests need. Highest trust of his specified relationships. Reliable supplier → stable trust. |
| Mabel | 0.6 | She brings information; he has a platform for it (the inn). They have a symbiotic intelligence arrangement. He doesn't repeat everything she tells him — he filters it through his commercial judgment. |
| Roland | 0.5 | Roland stops at the inn during his patrol circuit. Hugo values him as a source of security intelligence. Roland doesn't drink; Hugo values his information anyway. |
| Felix | 0.5 | Road news from the courier supplements Hugo's traveler intelligence. Felix is a secondary source who corroborates or contradicts what travelers tell him directly. |
| Aldric | 0.5 | The farmer eats lunch here most days. Crop information feeds Hugo's supply-planning for the inn menu. Stable, transactional, mid-warmth. |

Hugo is the only NPC with five specified relationships — every other NPC in the cast has at most three. He is structurally the most connected node in the social graph.

---

## Emotional Fingerprint

Baseline: `amusement 0.3, joy 0.3`. Amusement is the more revealing dimension: it implies mild detachment, the emotion of someone watching a performance. Hugo finds people entertaining. Combined with joy, this produces a warm-but-not-invested baseline. He is not cynical — he genuinely wants people to be comfortable — but his amusement ceiling means nothing truly surprises or moves him.

L2 modulation: joy → approach tendency boost (he moves toward guests). Amusement has a weak curiosity adjacency — he may spike toward curiosity when truly unusual information arrives. Help tendency receives continuous boost from his neural bias. Fear and anger are absent from his baseline, though the "empty barrel" complaint suggests mild, chronic frustration around supply management.

Spike triggers: `stranger` in gossip context (curiosity spike), `barrel` + `empty` (frustration), guests who stay past closing (mild annoyance). Positive spikes: full tavern, multiple NPCs nearby simultaneously (amplifies sense_nearby_npcs bias).

---

## Schedule Logic

Three chunks is the fewest of any NPC. But his chunks are the longest: 5 hours (breakfast prep/service), 8 hours (run the inn), 3 hours (evening service). He never leaves his working context except for the 2-hour market run, which is the only element of schedule variation in his day.

The 8-hour "run the inn" block is the longest single chunk in the cast, eclipsing even Edith's 6-hour morning bake. During this block, Hugo is static at the inn for an extended period. Every NPC who enters the inn during this window will generate a social propagation event with him (his sense_nearby_npcs bias is always active). He is essentially a fixed information node collecting inputs for 8 continuous hours.

The 23:00 closing means his energy depletes from 70 down toward 20 over a longer window than any other NPC. If he starts tired (energy slightly below default), the override condition becomes achievable by late evening.

Interruption pattern: low during his own drives (stable, low social, energy recovery through market slot). High from external interaction — he is the most interrupted NPC in the simulation because everyone comes to him. His interruption tolerance must be high; the `should_interrupt_for()` check will be evaluated more frequently against Hugo than any other NPC.

---

## Stress Signature

Hugo's neurogenesis will specialize toward **reward neurons** primarily. His help tendency is continuously activated by nearby NPCs (sense_nearby_npcs bias), and when helping succeeds (social propagation completing, dialogue resolving positively), drive recovery fires. The help→reward pathway will become one of the most reinforced connections in his network.

Stress neurons are plausible around the ale barrel — repeated empty-barrel concern events that recur daily create the sustained frustration pattern that triggers stress neuron growth. A stress neuron targeting the barrel-related frustration pathway would make Hugo increasingly stoic about supply problems: he would still notice them but not react with the same urgency.

Novelty neurons are unlikely: he is the most location-stable NPC in the cast. His spatial familiarity with the inn is maximal. Novel stimuli would have to come from unusual guests or unusual NPC behavior — which is possible but not structurally guaranteed.

Primary concern trigger: `inn_ale_barrel_01` (empty at simulation start). Secondary: `inn_pantry_01` if examined and found undersupplied. Hugo is the NPC whose concerns are most visible to other NPCs because he is spatially central.

---

## Open Questions / Gaps

- **No `sensor_profile` field.** An innkeeper behind a counter should have wide awareness of the room — a broad arc (130deg+) with moderate range fits. He monitors entrances and seating areas simultaneously. High hearing sensitivity for picking up table conversations at distance.
- **No somatic fingerprint.** Somatic tags: `[warm, alert, tired]` during long service periods; `[depleted, quiet]` in the 21:00-23:00 late window when energy is lowest. The somatic stream should reflect his energy-depletion arc across the day.
- **No vagal gate thresholds.** His baseline lacks fear, his energy drains slowly, and his social need is low. His vagal gate is probably highly regulated — he can switch between sympathetic activation (busy service) and parasympathetic recovery (late quiet hours) smoothly. But it needs explicit thresholds for the cognitive architecture.
- **Energy at 70 + 18-hour day = stress accumulation.** No mechanism for energy mid-day recovery is specified. He goes to market (2h) but this is not a rest event — it's active work. Is there a rest sub-action during his 8-hour run-the-inn block? This needs explicit design.
- **5 relationships but no documented friction relationships.** Everyone trusts Hugo. What breaks that? If Mabel spreads incorrect information through his platform, does he lose trust in her? No mechanism for trust degradation from false information is encoded.
- **Late closing creates a unique L3 context.** Between 21:00-23:00, Hugo and Roland are the only active NPCs. Their social propagation opportunities during this window could generate unique shared beliefs. The thought loop should produce meaningfully different dialogue during this quiet window vs. peak service hours — but the persona doesn't specify late-night behavioral modulation.

---

## Thematic Weight

Hugo is the town's information switchboard and its warmest surface. Every NPC visits him, and he processes them all with the same benevolent efficiency. His amusement baseline is the tell: he sees the town as a performance he is hosting, not a community he belongs to. He came from outside (traveling merchant background), he bought his way in, and he stays because it's profitable and interesting. The emergent story potential: Hugo knows more than he tells. When he does share something — the stranger who "didn't stay long," the night Roland was pacing more than usual — it has been curated. He is the last person to panic and the first to know something is wrong.
