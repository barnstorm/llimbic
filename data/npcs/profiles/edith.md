# Edith — Baker

**Role in Story:** Baker  
**Persona source:** `data/npcs/edith.json`

---

## Snapshot

Edith is a high-output, low-complexity NPC anchored to her oven. She starts the day with strong safety and energy reserves, low hunger, and modest social need, making her the most task-stable character in town. Her internal state is unusual for its *flatness* — joy and caring sit at modest baselines without any strong negative emotion, which means her L2 emotion engine rarely fires spike corrections. She is psychologically predictable in a way that makes her a reliable supply node and a social anchor for characters who need stability (Hugo, Aldric). Her single neural bias (drive_hunger → action_approach, +0.02) is subtle and rarely triggers, since her hunger default is 10 — the lowest of any NPC. She runs on routine.

---

## Behavioral Patterns

- **High safety (80) + high energy (75):** Edith starts each tick with the two drives that support uninterrupted work at their upper range. The NPCBrain drive-override thresholds are safety<30 and energy<20 — she almost never hits either. She completes chunks reliably and rarely suspends.
- **Low social (30):** Social need is 30, the override threshold is >85. She will not seek socialization on her own initiative. The two hours at town_square (priority 0.4) are her only scheduled social window, and that chunk has the lowest priority in her day — it will yield first to any interruption.
- **Hunger bias (drive_hunger → action_approach, +0.02):** Because hunger defaults to 10, this connection carries almost no activation in normal conditions. It becomes meaningful only if she skips her market chunk or is interrupted before eating — a rare edge case that will wire up via Hebbian learning only if the scenario repeats.
- **Two oven-targeted chunks (priority 0.9 and 0.8):** Her schedule's highest-weight chunks both reference `bakery_oven_01`. When the oven's state is non-default (broken/empty from task init), she will inject a concern chunk immediately on examination. She is the character most likely to file an object-problem concern event early in the day.
- **4-chunk day, two location types:** Bakery (work) → Market (sell) → Town square (social) → Bakery (work). The shape is symmetric and occupation-dominated. Transitions are predictable, interruption tolerance stays high through most of the day.
- **Emotion baseline gravity (joy 0.4, caring 0.3):** The L2 emotion engine decays toward this on every tick. Edith's emotional home is warm but not effusive. She won't spike into anger or fear without a direct trigger event.

---

## Voice Markers

Speech is casual and terse. She uses bread-and-baking vocabulary as grounding metaphors even in non-baking contexts. Sentences are declarative, subject-present, rarely conditional.

- **"Fresh bread today!"** — Present-tense, no subject, no qualifier. She states facts. The exclamation is habitual, not excited.
- **"Can't stop now, bread's in the oven."** — Prioritization stated as environmental constraint ("the oven") not personal choice. She deflects with the object, not herself.
- **"Did you see who was at the market?"** — Her gossip line is curiosity framed as a question, not a declaration. She collects social data passively rather than broadcasting it.

Avoid: long explanations, hedging, emotional declarations. She names what needs doing. If pressed she names it twice, shorter the second time.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Hugo | 0.6 | Regular buyer — transactional warmth. Hugo's inn needs her bread; she needs his social buffer. Mutual benefit keeps trust stable. |
| Aldric | 0.55 | Supplier relationship. Aldric's produce feeds her recipe variation. Trust grounded in reliability of his schedule, not personal closeness. |

No negative relationships encoded. Roland, Felix, Greta, Mabel, Ivy are all unspecified (trust defaults to system baseline). Mabel's visits to the bakery (her schedule includes a 1-hour bakery stop) will generate repeated proximity events — Edith's low social drive means these visits are tolerated but not sought.

---

## Emotional Fingerprint

Baseline: `joy 0.4, caring 0.3`. All other GoEmotions dimensions at zero or near-zero. This is one of the sparser baselines in the cast — only two anchors.

L2 engine behavior: The engine will return Edith to this pair as home state after any spike. Events that move her: `broken` keyword (disappointment spike, oven-relevant), social interaction at positive trust (joy reinforcement), stall events (frustration → anger spike, quickly decaying back toward joy). Fear is structurally absent from her baseline — it requires a safety event to generate. Because safety defaults to 80, fear spikes will be rare and short-lived.

Modulation effect: her steady joy→approach mapping keeps task_momentum high and interruption_sensitivity low. She is hard to derail by ambient social stimuli.

---

## Schedule Logic

Four chunks, two locations. The 6-hour morning bake is the longest single commitment in the NPC roster — it creates extended task_momentum and Hebbian reinforcement of the oven-related action pathway. The market slot (3h, 0.7) is where she collects social input passively without seeking it. Town square (2h, 0.4) is the only low-stakes window where a social override or player interaction won't feel disruptive. Afternoon bake (4h, 0.8) mirrors the morning but slightly shorter and lower priority — fatigue context.

Expected interruption pattern: low. Her chunks are long and high-priority. Social need will not override before ~85 threshold. Energy depletion is the only realistic mid-day disruptor if time_scale is high and she can't eat.

---

## Stress Signature

Edith's neurogenesis is likely to specialize toward **reward neurons** first. Her drives recover reliably (high baseline safety, energy), which is the trigger condition for reward neuron creation. She will reinforce her oven-approach pathway. Stress neurons are unlikely unless she regularly encounters a broken oven (object_problem concern + repeated failure). If the oven stays broken across multiple sessions, Hebbian co-activation of frustration + oven-approach will wire a stress neuron targeting that pathway, which would begin inhibiting her oven approach tendency — a slow degradation of her core competence. Object: `bakery_oven_01` is her highest-risk trigger point.

---

## Open Questions / Gaps

- **No `sensor_profile` field.** She uses system defaults (96px range, 90deg arc). A baker working over an oven probably has reduced peripheral awareness — a narrower arc (60deg) facing her work object would be plausible. Needs decision.
- **No somatic fingerprint.** The somatic stream (compound body-sensation tags) is not represented. Edith's somatic profile would likely include `[warm, fatigued, productive]` during long bake chunks. No vagal gate thresholds defined.
- **No vagal gate values.** Threat-response individuation not specified. Given her high safety default, she's likely parasympathetic-dominant — her vagal gate should suppress flee tendencies strongly.
- **Hunger drive at 10 makes the neural bias inert.** If hunger never climbs meaningfully, `drive_hunger → action_approach` never fires. Either raise the default slightly or document this as intentional (Edith always has access to bread).
- **Inventory: three bread items.** What happens when they're consumed or given away? No restock logic specified in the persona.
- **Relationship with Mabel unspecified** despite Mabel scheduling a bakery visit. Needs a trust value or the proximity events will generate random-walk trust drift.

---

## Thematic Weight

Edith is the town's metabolic baseline — she is what normal looks like. Her stability makes her a useful contrast character: when something disrupts her routine, it signals that something is genuinely wrong in the town's economy. She anchors the supply chain (bread to Hugo, grain relationship with Aldric) and provides the social fabric's low-drama connective tissue. Emergent story potential is low from Edith herself, but high from watching what breaks her.
