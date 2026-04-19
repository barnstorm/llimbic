# Felix — Courier

**Role in Story:** Courier  
**Persona source:** `data/npcs/felix.json`

---

## Snapshot

Felix has the most fragmented schedule in the cast — 7 chunks across 6 distinct locations, the shortest individual slot being 1 hour. His neural bias (`drive_energy → action_approach, +0.02`) means high energy translates directly into approaching people and destinations. He starts at 85 energy and almost never depletes below override threshold (20), so this wire is always live. He is not the town gossip — Mabel owns that function — but he is the town's connective tissue: he visits Edith, Greta, and Hugo on his daily circuit, generating proximity events and social propagation opportunities with three of the four most relationship-dense NPCs in the cast. His emotional home is optimism and excitement, which makes him the town's highest-valence NPC by baseline.

---

## Behavioral Patterns

- **Energy at 85 + approach bias (+0.02):** Felix's energy drive is almost always high and always converting into approach tendency. He moves toward things. His behavioral default is forward motion. Stall events — being blocked, path obstructions — are felt more acutely because they contradict his core wiring.
- **Social at 40:** Highest social default in the cast alongside Hugo (15, low) and uniquely above the pack. He will reach the social>85 override threshold sooner than most NPCs during long isolated runs (road_east, 3h). His east-road delivery chunk is the only slot where social need builds without interaction opportunity.
- **7-chunk schedule, low per-chunk duration:** Chunks of 2, 1, 1, 1, 2, 3, 2 hours. Task momentum accumulates briefly then resets on chunk transition. Felix's `task_momentum` never builds the deep reserves that Edith or Greta sustain over 6-hour baking/forging blocks. His interruption tolerance is structurally lower — not from drive pressure but from habituated chunk-switching.
- **Approach bias generates frequent social propagation windows:** His route takes him through bakery, blacksmith, and inn in sequence. Each 1-hour stop creates proximity events. Social propagation (NPC pairs within 64px, social_need > 30, both can see each other) will fire on Felix more than any other NPC except Mabel. He is a conversation initiator even without intent.
- **Road_east chunk (3h, 0.8):** His only high-priority extended commitment. This is where his social need builds. After returning to courier_office for end-of-day sorting, his social need may be elevated enough to push toward social override unless the sort triggers drive recovery.
- **Emotion baseline (excitement 0.3, optimism 0.3):** No negative baseline values. His emotional home is the most positive in the cast. L2 decay returns him to high-valence state after any negative spike.

---

## Voice Markers

Fast, breathless, elliptical. He sounds like he's already halfway through the next thought. Sentences are short and often incomplete. He uses "heard" as a verb of currency — information is something he received and is handing off, not something he analyzed.

- **"Can't stop long — deliveries to make!"** — No subject. Activity named, constraint named, sentence over. The dash signals he's already pivoting.
- **"Three packages backed up and the road's been rough."** — Complaint delivered as logistics report. The emotional content (frustration) is present but framed as operational data, not feeling.
- **"Heard something interesting on the east road today."** — Opens with "heard," ends with "today" (recency marker). He is implicitly inviting a transaction: I have information, give me your attention.

Avoid: deliberate pacing, long explanation, botanical or meteorological metaphor (Ivy/Aldric register). He does not sit with a thought long enough to elaborate it. If asked to repeat himself, he rephrases as a shorter version of the original, never a longer one.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Edith | 0.55 | Daily delivery stop. Transactional warmth — she provides bread sometimes, he brings her packages. Consistent proximity drives trust. |
| Greta | 0.55 | Delivery stop. Greta values reliability; Felix is reliable if not always punctual. She tolerates his energy. |
| Hugo | 0.5 | Inn delivery. Hugo is a social information node; Felix brings road news Hugo doesn't have. Mutual utility. |

Felix is the NPC who most naturally mediates between isolated characters. He visits Edith, Greta, and Hugo — who are connected to Roland, Mabel, Aldric, and Ivy through those hubs. He is structurally positioned to carry information between people who don't visit each other directly. This is a key emergent story function.

---

## Emotional Fingerprint

Baseline: `excitement 0.3, optimism 0.3`. Both are forward-facing, anticipatory emotions. L2 modulation: excitement doesn't map cleanly to any single modulation parameter — it falls near curiosity in the GoEmotions space, likely raising exploration_bias. Optimism may reinforce approach tendency. Together they create a low-latency, high-approach, low-fear modulation profile.

Spike triggers: "road" keyword + negative context (rough road, blocked road) → disappointment/frustration. "Package" + "backed up" → same. "Quick" and "stop" in negative context → annoyance spike. Recovery is fast given his high-valence baseline.

Key vulnerability: Felix has no fear in his baseline and no safety-type concern. If a genuine threat event reaches him (Roland's east-road concerns, Ivy's botanical omen), he may not assign it appropriate weight. His emotional architecture doesn't generate sustained dread.

---

## Schedule Logic

Seven chunks is the longest schedule in the cast. The geometry is hub-and-spoke with a long spoke: courier_office → delivery circuit (bakery/blacksmith/inn) → market → road_east → courier_office. The delivery circuit chunks are 1h each — minimum dwell time, maximum contact frequency. This creates Hebbian co-activation between approach_action and social_interaction at a higher rate than any other NPC, reinforcing his approach wiring.

The road_east slot (3h, 0.8) is the structural driver of his social need buildup. On return, if social_need is near override, his end-of-day sort chunk may be interrupted by a social override toward the inn or market. Hugo and Felix share 0.5 trust and are both in the inn during overlapping windows.

Interruption pattern: high frequency, low individual cost. Felix is habituated to task-switching. His stall-frustration spikes will be sharp but brief — he re-routes rather than persisting against obstacles.

---

## Stress Signature

Felix's neurogenesis will specialize toward **reward neurons** first. His energy drive is almost always recovered (never near 20), and each successful delivery completion triggers drive recovery — exactly the reward neuron creation condition. Over time, his delivery-approach pathway becomes deeply reinforced.

Novelty neurons are plausible: road_east is the highest-novelty location in the simulation (farthest from town social graph, most variable stimulus). Sustained low-familiarity exposure during long-distance delivery will trigger novelty neuron growth.

Stress neurons are the least likely for Felix. His frustration rarely sustains (low-momentum chunks reset often) and his high-valence baseline means frustration decays quickly. If he stress-neurons at all, it will be from a specific repeated blockage — the same NPC or obstacle pattern disrupting his delivery circuit daily.

Primary concern trigger: backed-up packages at `courier_office` (start-of-day sort chunk). If sorting fails or the office object is in a problem state, he injects a concern with an urgency that overrides his social appetite for the first part of the day.

---

## Open Questions / Gaps

- **No `sensor_profile` field.** Felix moves fast and changes direction frequently. A courier's sensor profile should arguably prioritize forward-facing range over arc width — he sees where he's going, not the sides. Worth specifying.
- **No somatic fingerprint.** Felix's somatic stream should include `[energized, rushed, slightly breathless]` as default. During road_east: `[alert, isolated]`. These would enrich the L2 emotional coloring of his thought loop.
- **No vagal gate thresholds.** His low fear baseline suggests a weakly-activated threat response. He should be hard to panic and quick to dismiss threat signals — which is a vulnerability, not just a strength.
- **Social drive at 40 — what does it look like when it overrides?** At 85+ threshold, he seeks social interaction. But his schedule never explicitly targets a social venue (unlike Edith's town_square slot). What location does the drive override send him to? The system defaults to generic SOCIAL behavior — this should be specified as a fallback target (probably inn or market).
- **7-chunk day and L3 planning:** Does the SmolLM3 thought loop respect all 7 chunks or compress them? The server's per-NPC coroutine fires every 2-8s — with 7 short chunks, plan state changes rapidly. Verify that `set_intention` commands don't create stale targets mid-delivery.
- **Letter in starting inventory.** No delivery destination or recipient specified. Mechanical loop undefined.

---

## Thematic Weight

Felix is the town's circulatory system. He carries goods, news, and proximity between nodes that would otherwise be isolated. Without him, Edith and Greta never interact; Roland's east-road observations stay in the inn (Hugo at 0.5 trust) and don't reach the herbalist or farmer. His cheerfulness is not naivety — it is what allows him to enter any social space without friction. The emergent story potential is in what he overhears and who he tells, and in what happens when his route is interrupted: a blocked road collapses the town's information network, not just his delivery schedule.
