# Greta — Blacksmith

**Role in Story:** Blacksmith  
**Persona source:** `data/npcs/greta.json`

---

## Snapshot

Greta has the most unusual neural bias in the cast: `task_momentum → action_approach (+0.02)`. She is the only NPC wired to internal task state rather than a drive or sensory signal. The higher her momentum, the more she approaches things. This creates a positive feedback loop during long forge sessions: momentum builds, approach tendency rises, she re-engages her work object more readily, momentum stays high. She is operationally self-reinforcing when working and the hardest NPC to interrupt mid-task. Her emotion baseline (pride 0.4, admiration 0.2) mirrors Roland's pride anchor — but where Roland's pride serves vigilance, Greta's serves craft.

---

## Behavioral Patterns

- **task_momentum → approach (+0.02):** During the 6-hour morning forge block (priority 0.9), Greta's momentum rises steadily. The approach bias activates progressively, meaning she becomes more and more likely to re-examine her forge and anvil objects, reducing the probability of any distraction-driven OBSERVE action. By the middle of her morning block, she is the most task-locked NPC in the simulation.
- **Energy at 80, hunger at 20:** Stable drives. Override conditions are unlikely in normal operation. She will not be pulled off the forge by basic needs.
- **Social at 30:** Same as Edith and Ivy. Low but above floor. She schedules no explicit social chunk — her inn stop (2h, 0.4) is for "evening meal and rest," a drive-recovery function, not a social one. She uses the inn's ale barrel and pantry objects, not its social atmosphere.
- **Pride baseline 0.4:** Her L2 engine baseline gravity is the highest pride value in the cast. Pride in the GoEmotions mapping promotes approach tendency and suppresses help response (she is not oriented toward assisting others). Her pride specifically attaches to her forge — the object she built herself.
- **Two forge/anvil targeted chunks:** `smith_forge_01` (use, morning) and `smith_anvil_01` (use, late). If the forge is broken at simulation start (MEMORY.md confirms: `smith_forge_01` starts in broken state), Greta will inject a concern chunk within the first minutes of play. This is one of the three predetermined object-problem triggers in the world.
- **No approach to market before inn:** Her market slot (2h, 0.6) is between the forge and inn. She sells, buys minimally, then rests. She does not linger. Her market presence is commercial, not social.

---

## Voice Markers

Direct, matter-of-fact. No wasted words. She names objects and states them: "forge," "steel," "repair." Active voice. Her complaints are statements of condition, not appeals for sympathy.

- **"Need something repaired? I'm your smith."** — Conditional question followed by self-identification as capability. She skips name-based introduction and goes straight to function. She is what she does.
- **"Steel's hot. Talk later."** — Three words, one sentence, absolute priority ranking. The steel takes precedence over the conversation. No apology.
- **"Roland ordered a new blade last week. Wonder what for."** — Her gossip is military-logistical curiosity. She notices unusual orders because orders define her work. "Wonder what for" is a genuine question, not rhetorical — she is thinking out loud about context she doesn't have.

Avoid: social pleasantries, metaphors from other domains (no bread or plant analogies), emotional elaboration. When she has delivered information she considers complete, she stops. She does not add comfort.

---

## Relationships

| NPC | Trust score | Inference |
|-----|-------------|-----------|
| Roland | 0.6 | She made him a blade (per her own gossip line). Craft relationship: she respects competence and duty; he respects reliability and silence. Probably the least verbal relationship in the cast. |
| Felix | 0.55 | He delivers to her. She values punctuality and straightforwardness. Felix's energy registers as acceptable energy, not intrusion, because he doesn't stay long. |

No relationships with Edith, Ivy, Mabel, Hugo, Aldric specified. Given the forge's central position and her schedule, she will generate proximity events with Felix (daily delivery) and Roland (patrol through market area) more than others. Mabel and Greta are structurally unlikely to converge — Mabel's schedule doesn't route through the blacksmith.

---

## Emotional Fingerprint

Baseline: `pride 0.4, admiration 0.2`. The admiration dimension is interesting — it's outward-facing, implying she recognizes quality in others' work. This is consistent with having learned from a traveling master. She doesn't admire people; she admires craft.

L2 modulation: high pride → approach mapping sustains her forge engagement. Admiration has a weak curiosity adjacency — when she sees quality tools or objects (examine action), curiosity may spike briefly. Negative spikes: `broken` keyword → disappointment (forge problem), `rough` or `heat` context → frustration if work is stalled. Her recovery is rapid due to the positive feedback loop of task_momentum → approach re-engaging her after spikes.

---

## Schedule Logic

Four chunks, three locations. The shape is forge-dominant with a mid-day commercial-and-rest interlude. Total forge time (9h across two chunks) exceeds any other NPC's work commitment. The late forging block (3h, 0.7) is shorter and slightly lower priority than the morning — but still carries an object target (`smith_anvil_01`). Two different work objects across the day suggest task variety: the forge is for primary creation, the anvil for finishing or repair work.

The inn slot (2h, 0.4) is her lowest-priority chunk. If an object concern from the forge is unresolved, she may skip the inn entirely and inject a repair attempt instead. Social propagation events during the inn period will occur if Hugo or other NPCs are present — but Greta's social drive (30) means she's at the bottom of the mutual social threshold check.

Interruption pattern: very low during morning/late forging blocks due to task_momentum feedback. Moderate during market and inn slots. She is the hardest NPC to pull away from work and the most likely to complete her schedule without deviation.

---

## Stress Signature

Greta's neurogenesis will specialize toward **reward neurons** first — the task_momentum → approach loop creates repeated drive recovery events during forge work. This will deepen over time, making her forge engagement increasingly automatic.

Stress neurons are her second-most-likely specialization, specifically if the forge starts broken. Repeated failure to complete the forge chunk (concern → inject → examine → still broken) creates sustained frustration over time, eventually crossing the neurogenesis threshold. Stress neurons would inhibit frustration around `smith_forge_01` — a coping mechanism that makes her seem stoic about forge problems even as she functionally deprioritizes them.

Novelty neurons are her least likely specialization. She is the most location-stable NPC after Hugo. Familiarity with her forge grows rapidly; she almost never enters genuinely low-familiarity states.

Primary concern trigger: `smith_forge_01` (broken at simulation start — highest-urgency trigger confirmed).

---

## Open Questions / Gaps

- **No `sensor_profile` field.** Forge work implies forward-focused, close-range attention. A narrow arc (60-70deg) with moderate range fits her work posture. Alternatively, a blacksmith's shop is noisy — hearing_sensitivity should probably be lower than default.
- **No somatic fingerprint.** Somatic tags: `[hot, strong, focused]` during forge chunks; `[tired, satisfied]` during inn rest. The forge chunk should drive a distinctive somatic state that colors L2 emotion output.
- **No vagal gate thresholds.** Her high pride and low fear suggest sympathetic activation during work, but not threat-driven — it's more effort/exertion arousal. The vagal gate should distinguish these.
- **task_momentum bias creates a design question.** This is the only bias linked to a task neuron rather than a drive or sensor. Does momentum have a floor that prevents the approach feedback from going to zero overnight? The action baseline floors (approach: 20) protect this, but the momentum itself is not bounded from below in the same way.
- **Forge broken at simulation start.** This is the highest-stakes object scenario in the early game. Greta's response (immediate concern injection, high-priority repair chunk) should be validated — does she actually attempt to repair it, or just examine it repeatedly?
- **Admiration baseline without a target.** Who or what does she admire? The traveling master is referenced in backstory but not encoded anywhere. If another NPC produces visible high-quality work (Edith's bread, Roland's discipline), does admiration spike? The cognitive adventure-command interface's `believe` command could encode this.

---

## Thematic Weight

Greta is the town's productive pride. She represents work as identity — she built her forge from scratch and will not let anyone touch it. Her presence is a constant proof that things can be made well. The emergent story potential is in craft: when someone needs something built or repaired (Roland's blade, a broken lock, a collapsed tool), Greta is the bottleneck. Her stubbornness about her forge is not obstruction — it is self-worth encoded as object ownership. The forge being broken at simulation start is the town's first visible wound.
