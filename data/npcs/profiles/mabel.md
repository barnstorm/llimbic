# Mabel — Gossip

**Role in Story:** Gossip  
**Persona source:** `data/npcs/mabel.json`

---

## Snapshot

Mabel has the most paradoxical neural wiring in the cast. Her `drive_social` defaults to 10 — the lowest in the entire NPC roster, lower even than Roland's 20. Yet she spends her entire day in social locations and her schedule is built entirely around information-gathering from other people. The paradox resolves through her biases: `drive_social → action_observe (+0.03)` and `drive_social → action_approach (-0.02)`. Low social drive activates observation and suppresses approach. Mabel starts the day socially starved and immediately begins watching — not greeting. She is a watcher, not a greeter. Her currency is observation, not interaction.

---

## Behavioral Patterns

- **drive_social at 10 + observe bias (+0.03):** The lowest social default in the cast directly feeds her strongest behavioral output. At 10, her social drive is near the bottom, continuously pushing observe tendency upward and approach tendency down. She is always marginally hungry for social contact but never reaches the threshold (85) that forces her to seek it directly. She orbits without closing.
- **action_approach bias (-0.02):** Mabel is the only NPC with a negative approach bias. She doesn't walk up to people; she stations herself near them and waits. This is behaviorally accurate to a "watcher" archetype and has mechanical consequences: her social_propagation events are more likely to be initiated by the other party, since she suppresses her own approach tendency.
- **5-chunk schedule, all social venues:** market (3h) → town_square (3h) → inn (2h) → bakery (1h) → well (2h). No work location, no object-action targets. She has no `work_location` in the functional sense — `town_square` is listed but she doesn't produce anything there. She is the only NPC whose schedule is entirely observational.
- **No starting inventory.** Mabel holds nothing. She is the only NPC besides Roland with an empty starting inventory — but where Roland's emptiness means military discipline, Mabel's means she trades in information, not goods.
- **Emotion baseline (curiosity 0.5, surprise 0.3):** Highest curiosity value in the cast. Surprise at 0.3 is unique to her — she is the only NPC with surprise in her emotional baseline, meaning the L2 engine periodically drifts her back toward a state of being caught off-guard. Structurally, this extends her reactivity window.
- **Highest observe priority in cast:** Between her observe neural bias (+0.03, tied with Roland) and her curiosity baseline (the L2 emotion→L1 curiosity→explore mapping), Mabel generates more OBSERVE actions per simulation time than any NPC except possibly Roland. The difference: Roland observes in service of safety; Mabel observes in service of curiosity.

---

## Voice Markers

Animated, conspiratorial. She leans in (positionally, via her approach to entities she targets for conversation). Every sentence sounds like a secret even when it isn't. She frames observations as shared discoveries rather than reports.

- **"Oh! Have you heard the latest?"** — Opens with a surprise exclamation. "Oh!" is not genuine surprise — it's a social signal that marks the following content as important. "Have you heard" frames her information as currency: do you have what I have?
- **"Between us — I saw something odd near the well."** — "Between us" is her primary confidentiality marker. She uses it even when she will tell the same thing to ten people. The dash creates conspiratorial pacing. "Odd" is her evaluation word — she doesn't report facts, she reports interpretations.
- **"Nobody tells me anything anymore."** — Her complaint reveals her self-concept: she is supposed to be told things. Information flow is an entitlement. When it stops, she is aggrieved.

Avoid: direct declarations, impersonal framing, flat tone. She contextualizes everything. Even "The bread is fresh" becomes "Edith had the oven going before dawn — I noticed the smoke." She wraps observations in social framing.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Hugo | 0.6 | The inn is her best intelligence node. Hugo stays late, hears everything, and is socially fluent. They have a mutual-use arrangement dressed up as warmth. |
| Edith | 0.55 | The bakery visit is a daily ritual. Edith tolerates it; Mabel values the early-morning information (who came in, what was discussed). Edith's low social drive means this is more one-sided than Mabel realizes. |
| Ivy | 0.4 | Ivy has information Mabel cannot access directly (botanical signals, environmental readings). Mabel finds Ivy useful but slightly opaque — Ivy doesn't perform the exchange rituals Mabel expects. |

Role friction analysis: Mabel↔Roland is the highest-tension unspecified pair. Her schedule places her in town_square during his patrol, generating regular proximity. His duty-bound stoicism and her conspiratorial animation are incompatible behavioral styles. Roland's clipped formal speech cannot be processed by Mabel's social framework — she will interpret his terseness as withholding. Over time, trust may erode even without a direct negative event. Mabel↔Felix: high interaction probability (both in market and town_square windows), compatible social energies, natural information exchange pair.

---

## Emotional Fingerprint

Baseline: `curiosity 0.5, surprise 0.3`. The 0.5 curiosity is the highest single-dimension baseline value in the cast. L2 engine returns her here on every tick. Curiosity maps to exploration_bias — she is always oriented toward novel stimuli.

Surprise (0.3) as a baseline is architecturally interesting: it's a reactive emotion, not a proactive one. Having it as a resting state means Mabel is chronically in "ready to react" mode. Her emotional repertoire peaks outward (curiosity, surprise) rather than inward (pride, caring). She is defined by what the world does to her attention, not by what she produces.

Spike triggers: `noticed` and `suspicious` in her vocabulary list are keyword cues for her gossip loop. "discovered" + another NPC → curiosity spike. "between us" is her production-side marker, not a reception trigger. Her social drive at 10 means she almost never hits the desire spike from social need — she is not lonely in the emotional sense, she is informationally hungry.

---

## Schedule Logic

Five chunks, five different locations. No location repeats. This is the most geographically dispersed schedule in the cast, and every location is a social hub: market (high NPC traffic), town_square (central propagation point), inn (traveler information), bakery (Edith's morning routine data), well (community gathering point). Her schedule is an intelligence collection circuit.

The well slot (2h, 0.6) is her least-documented chunk — no object target, no NPC relationship anchoring it. It appears in her schedule because it's a community gathering point, but mechanically it may generate the lowest-quality information if no other NPC routes through the well.

Her lowest-priority slot is the bakery visit (1h, 0.5) — it will yield first to any override condition. But since her social need is so low, overrides are rare. She will complete this circuit reliably every day.

Interruption pattern: low for her own drives (never overrides), moderate for external social interruptions. She is the NPC most likely to be interrupted by others (her approach suppression means she doesn't initiate, but others will approach her). She will always pause for conversation — her observe tendency means she welcomes being approached.

---

## Stress Signature

Novelty neurons are Mabel's most likely neurogenesis specialization. Her curiosity baseline and observe-dominant wiring mean she is in near-constant low-familiarity observation mode relative to other NPCs — she is watching for novelty, which keeps familiarity perception low at the social rather than spatial level. New NPCs, new behaviors, new objects in familiar locations will trigger sustained novelty neuron growth.

Reward neurons are plausible if her curiosity→explore cycle generates repeated satisfaction events (information received, believe command confirmed). But without an explicit satisfaction mechanism tied to information acquisition, this pathway may not fire cleanly.

Stress neurons are the least likely unless Mabel is repeatedly denied information — isolated from social locations, blocked from her observation posts. Her highest stress scenario is information drought.

Primary concern trigger: no object targets means she has no object-problem concern injection pathway. This is a gap — she will not inject concerns about world objects because she has no object-action chunks. If she observes a broken object at a location she visits, the concern tags to her memory but she cannot act on it directly.

---

## Open Questions / Gaps

- **No `sensor_profile` field.** Mabel's sensory profile should be widened for lateral observation — she watches crowds, not targets. A wide arc (120deg+) with moderate range fits. High hearing sensitivity for picking up fragments of conversation.
- **No somatic fingerprint.** Somatic tags: `[alert, excited, restless]` during observation; `[deflated, bored]` during low-traffic windows (well slot if empty).
- **No vagal gate thresholds.** High curiosity baseline suggests her sympathetic arousal is driven by interest, not threat. Her vagal gate should be tolerant of mild arousal (she enjoys being activated) but not protective against genuine threat (she underweights danger signals).
- **drive_social at 10 creates a paradox that needs resolution at the somatic layer.** Mechanically she is "socially satisfied" almost always, but narratively she is the most socially dependent NPC. This could be interpreted as: she doesn't *need* social contact to feel okay, she *craves* social information. The distinction matters for somatic expression.
- **No object-action chunks means no object-concern injection pathway.** If Mabel witnesses a broken object (via vision), she should have a way to signal concern or gossip about it — this requires either a special memory promotion pathway or an explicit "report to NPC" action type.
- **Well location.** What NPCs are expected to route through the well? No other NPC's schedule includes the well. This slot may generate no social propagation events unless the player is present or a drive override sends another NPC past the well.

---

## Thematic Weight

Mabel is the town's nervous system — she samples every node and carries signals between them. Her low social drive is the key insight: she doesn't need people, she needs *about* people. This is a colder motivation than it appears. She is the most likely NPC to detect a pattern before anyone else, and the most likely to frame it in a way that either accelerates social response or distorts it. Emergent story potential: when Mabel's information is wrong, she will broadcast the error with exactly the same confidence as correct information. She is the town's rumor cascade risk.
