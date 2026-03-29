## PART 1 — Core Thesis

The architecture should be treated as a simulation-first adaptive NPC system whose purpose is not to imitate consciousness, not to simulate “true emotion,” and not to replace all traditional game AI with language-like reasoning. Its purpose is narrower and more useful: to produce NPCs that persist in a world over time, accumulate consequential history, form plans, react under pressure, and remain legible enough that their behavior can be inspected, tuned, and steered. The town exists as a stress environment for this architecture. It supplies repeated exposure, routine, interruption, rumor, obligation, and player disturbance. The question is whether NPCs built this way feel more continuous, more behaviorally grounded, and more intelligible than NPCs built from schedules plus ad hoc trigger scripts.

Layer 1 is the actual behavioral machinery. It is where the agent’s operative state lives. This is the substrate that governs attraction and avoidance, persistence and abandonment, interruption thresholds, habits, trust shifts, place familiarity, recovery from disruption, and action momentum. If the NPC behaves differently because it had a bad morning, was interrupted twice, distrusts the speaker, and is already halfway committed to a task, that difference must come from Layer 1. It is the only layer that should be treated as the real causal core of behavior.

Layer 2 is a human-shaped translation and modulation surface. It is not the NPC’s ontology. It is not “where the feelings are.” It is a compact coordinate surface that projects deeper conditions into a readable form and provides handles for steering those conditions without directly manipulating every low-level variable. If a system designer, debugging tool, or executive layer sees “cautious,” “frustrated,” “urgent,” “curious,” or “committed,” those are interface coordinates over deeper dynamics, not declarations about inner experience. Layer 2 exists because complex procedural state is hard to summarize and harder to steer.

Layer 3 is executive framing, planning, and symbolic direction. It is responsible for deciding what the NPC is trying to do in the larger sense: what role obligations matter today, what commitments should be honored, what remembered events are now relevant, what short-horizon plans should be pursued, and what dialogue-level intention should shape social interaction. Layer 3 should not be responsible for every step, every turn, every local response, or every interruption. It should steer rather than puppeteer.

The town simulation is therefore a harness for evaluating whether this layered system produces NPCs that are more believable, more legible, and more steerable than standard game AI. Believable means they seem to have continuity across time rather than existing only when the player is looking. Legible means the causes of their behavior can be summarized and inspected without flattening them into scripts. Steerable means high-level framing can alter behavior meaningfully without replacing the underlying local substrate.

## PART 2 — Distinction Between This System and a Generative-Agents-Style Town Model

A town-memory-planning social simulation model and a layered adaptive agent architecture solve different problems. The former is about persistence of social life. The latter is about how an individual agent actually behaves.

A generative-agents-like model is strong at maintaining observation streams, writing memory logs, producing reflections or summaries from those logs, forming short-horizon or daily plans, propagating information socially, and causing town-level coordination around shared events. It answers questions such as: who saw the announcement, who told whom, who plans to go to the square, who remembers being insulted yesterday, who intends to visit the doctor this afternoon. It is well suited to the slow continuity of town existence.

That model should not be mistaken for a full behavioral architecture. It is not the right place to govern moment-to-moment action selection, local reaction under threat, interruption handling, persistence under pressure, path-dependent adaptation, or low-level modulation of behavior. Those problems require a substrate that can remain active continuously, respond at fast cadence, and carry accumulated local state without turning every small decision into textual planning.

The clean distinction is this: the social-memory planner is the slow town brain; your layered architecture is the fast local agent. The slow town brain maintains ongoing social continuity. It knows that the baker heard about the late delivery, that the guard intends to check the east road, that the herbalist now distrusts the smith, and that three townsfolk expect rain. The fast local agent determines whether the baker, on the way to the square, hesitates near a stranger, becomes distracted by a damaged cart, avoids a loud argument, resumes the walk after interruption, or abandons the original errand because accumulated frustration and delay cross a threshold.

This separation matters because otherwise the system collapses into either brittle scripting or expensive over-cognition. If the town-memory system tries to own all behavior, it becomes too slow, too textual, and too detached from embodied local dynamics. If the local behavior substrate has no access to long-term memory, reflection, and social propagation, the town becomes decorative background. The architecture should therefore treat town-scale social cognition as a persistent scaffolding layer above and around the actual adaptive behavioral system, not as a substitute for it.

## PART 3 — The Three Layers in Detail

### Layer 1 — Behavioral Substrate

Layer 1 is the operative core. It should be mostly numeric, procedural, and stateful. Its job is not to narrate or explain behavior. Its job is to generate it. This layer contains the variables and processes that shape what the NPC does next under concrete conditions.

It should include local drives or pressures: bodily or situational needs, exposure to risk, fatigue-like depletion, perceived safety, time pressure, progress debt, social strain, and task commitment. These are not moral abstractions. They are continuously updated factors that bias action. If an NPC is hungry, late, exposed, overburdened, annoyed by repeated interruption, or drawn toward a familiar place, that pressure lives here.

It should include action tendencies: learned or seeded propensities toward approaching, avoiding, observing, helping, fleeing, continuing, postponing, or rechecking. These tendencies are not plans; they are behavioral inclinations shaped by current conditions and prior history. Threat response belongs here as well, including how quickly the NPC escalates to avoidance, alarm, intervention, or retreat. Attraction and avoidance toward places, people, or situations should be stateful rather than purely tagged. A market square may become attractive because it is familiar and socially dense, or aversive because of a recent public conflict.

Interruption thresholds are central. A strong architecture must distinguish between an agent that can be knocked off course by any minor stimulus and one that can maintain activity until a meaningful threshold is crossed. Momentum or inertia in ongoing actions therefore belongs in Layer 1. Starting a task, being deep in a task, and nearing completion should all feel different procedurally. Recovery from disruption also belongs here. After interruption, an agent should not instantly snap back to neutral. It should carry residual delay, annoyance, uncertainty, reorientation cost, or renewed caution.

Habit formation and familiarity should be Layer 1 properties. Repeated successful trips to a place should alter how the NPC traverses, prioritizes, and feels about that place in purely operational terms. Trust of people should also have a low-level footprint. If the NPC distrusts someone, that should change interruption tolerance, conversational exposure, willingness to help, or readiness to accept second-hand claims. Persistence versus abandonment should likewise be procedural: a task that has consumed effort without progress should become harder to sustain unless some countervailing pressure or commitment exists.

Most importantly, Layer 1 must be path dependent. Two identical world states should still permit different behavior if the NPC arrived there through different histories. An NPC that was delayed, startled, insulted, and then asked for help should not respond like one that arrived calm and unbothered, even if the visible scene is the same. Layer 1 must therefore preserve state history, not just current instantaneous values.

### Layer 2 — Translation and Modulation Surface

Layer 2 is a compact projection and steering layer. It should map the dense, mixed state of Layer 1 into a smaller human-legible coordinate space and accept top-down framing from Layer 3 that is converted back into modulation signals. It should be treated as a control panel, not a claim about inner life.

The upward direction is projection. Layer 2 takes a large and uneven set of local state variables and summarizes them into a bounded coordinate surface. Those coordinates might be described with terms such as caution, urgency, frustration, curiosity, commitment, confidence, social openness, or volatility. The exact vocabulary matters less than consistency. The point is not that the NPC “feels” these terms. The point is that a designer, debugger, planning layer, or higher-level interaction system can inspect a compact state that corresponds to deeper operative conditions.

The downward direction is modulation. Layer 3 can issue framing such as prioritize safety, push through delay, investigate anomalies, avoid public conflict, protect the companion, finish the current obligation before diversions, or stay socially available. Layer 2 converts such framing into bounded modulation on Layer 1: higher interruption tolerance, lower exploration, elevated vigilance, increased persistence, reduced social openness, or a stronger pull toward obligation completion. This preserves a distinction between deciding what matters and deciding exactly how every motor-sized behavior unfolds.

Consistency and boundedness are the essential obligations of Layer 2. It should not drift wildly in semantics. It should not generate unstable extremes. It should not become ornamental text. If it says the NPC is highly cautious and low in commitment, that should reliably correspond to recognizable modulation downstream. Likewise, a top-down request for greater urgency should not arbitrarily mean different things at different moments unless that variation is deliberately mediated by deeper context and remains inspectable.

Layer 2 should never be described as understanding emotions. It does not interpret the world psychologically. It projects and modulates. It is a translator between a rich but opaque procedural substrate and a compact set of handles usable by other systems and by human inspection.

### Layer 3 — Executive and Symbolic Framing

Layer 3 is responsible for larger-scale coherence. It forms agendas, maintains role continuity, reacts to remembered events, chooses short-horizon plans, manages social intentions, and preserves narrative consistency. If the NPC is a shopkeeper, a courier, a sibling, a gossip, a guard, or a debtor, Layer 3 should be where those role constraints become active priorities rather than just tags.

This layer should generate broad daily or half-day intentions: open the shop, deliver the parcel, visit the healer, avoid the square after yesterday’s argument, check on the child before sunset, attend the meeting if the mayor actually calls one. It should react to remembered events and unresolved concerns: if a rumor about wolves spreads, the hunter may shift afternoon plans; if a friend failed to appear, a concern may become an intention to investigate; if the player caused trouble yesterday, a social goal may emerge to avoid or confront.

Task decomposition should live here, but in modest form. Layer 3 should decide that a goal requires going to a location, speaking to a person, collecting something, or postponing another obligation. It should also own dialogue-level intent: reassure, refuse, recruit, apologize, deflect, warn, ask for help. Narrative consistency belongs here too. An NPC should continue to be recognizably itself across different scenes because its role, commitments, and remembered concerns shape what it tries to do.

What Layer 3 should not do is micromanage local action. It should not specify each movement choice, each turn, each evasion, or each interruption response. That would make the architecture brittle, expensive, and strangely disembodied. Layer 3 should steer by setting goals, priorities, and constraints, then allow lower layers to execute and adapt. It provides the “why now” and “what matters,” not the complete “how” of every second.

## PART 4 — Time Scales

The architecture should operate on deliberately separated time scales. Running all cognition at one cadence is both inefficient and conceptually wrong. Different problems unfold at different temporal resolutions. The system becomes robotic if everything is too slow and declarative. It becomes chaotic or wasteful if everything is too fast and overcomputed.

The very fast loop belongs to local behavior. This is where Layer 1 evaluates immediate pressures, current action momentum, local stimuli, threat response, interruption thresholds, and short reactivity. It should be responsible for maintaining smooth continuity in the face of real-time player interaction. If the player suddenly enters a shop, blocks a path, draws a weapon, drops an item, initiates a conversation, or causes panic, the NPC cannot wait for a high-level reflective planner. The local loop must already be alive.

A medium loop belongs to translation and state summarization. Layer 2 does not need to update at every tiny behavioral tick, but it must update frequently enough that current local conditions remain legible and modulations remain relevant. This is where compact projection is refreshed, where top-down framing is applied, and where drift or instability can be bounded. It sits between continuous local process and slower symbolic reasoning.

A slower loop belongs to planning and reflection. Layer 3 should not replan every moment. It should form agendas and plan chunks, evaluate whether major intentions are still viable, absorb summarized memory, and revise current priorities when meaningful changes occur. This cadence is where role coherence and narrative continuity are maintained. The slower cadence prevents the system from overreacting to every noise and turning executive reasoning into expensive chatter.

An even slower loop belongs to town-scale event propagation. Rumors, shared awareness, public disturbances, and social diffusion should not be handled as instant omniscience. Information should move with exposure, conversation, place, trust, salience, and delay. This slower ecology produces the feeling that the town exists over time rather than updating globally the instant something happens.

These distinct cadences keep the simulation credible and affordable. Real-time player interaction requires fast local behavior. Social coherence requires slower accumulation and diffusion. Planning requires enough latency to preserve intention rather than constant nervous replanning. Reflection requires enough distance from raw observation to extract patterns instead of merely recording noise.

## PART 5 — Town Simulation as Harness

The town layer should be understood as a background ecology rather than the intelligence itself. It provides the recurring structure necessary for adaptive NPCs to reveal whether they truly persist and whether memory and planning matter.

The harness should supply places with distinct functional meaning: homes, shops, roads, gathering points, semi-private spaces, work sites, and transit edges. It should define roles that create expected patterns of movement and obligation: shopkeeper, laborer, courier, healer, guard, child, drifter, visitor. It should establish ownership and affiliation so that places and people matter differently to different NPCs. The town also needs social visibility: some spaces are public and rumor-rich, others are private and memory-rich.

Repeated encounters are essential. NPCs should see each other often enough that relationship changes have somewhere to land. Shared locations matter because they create overlapping exposure. Event exposure matters because it differentiates what each NPC knows. The world should contain memory-worthy incidents: missed appointments, public arguments, injuries, favors, thefts, weather shifts, blocked routes, festival preparations, unusual arrivals, monster sightings, player disruptions.

A good town harness also creates opportunities for schedule bending. Pure schedules are dead. The system needs reasons to deviate: a storm, a conversation, an injury, a rumor, a shortage, a public spectacle, a social obligation, a private concern. It needs opportunities for rumor spread, for conflict, for aid, for avoidance, and for coordination. The point is not maximal complexity. The point is repeated social and spatial structure rich enough that planning and memory have consequences.

A town is a strong evaluation environment because it combines persistent relationships, recurring routines, interruptions, player influence, public events, private memory, and believable social consequences. It is neither a pure sandbox nor a pure script. It is stable enough to observe patterns and dynamic enough to test adaptation. Because the player can interact in real time, the town also exposes whether the architecture survives live disturbance rather than only succeeding in turn-like simulation.

## PART 6 — Memory Model

The memory system should be layered and selective. Not everything observed should be treated as meaningful memory. The architecture needs a distinction between immediate perception, stored recollection, reflective abstraction, intention-supporting retrieval, and low-level behavioral residue.

Raw observations are the first layer. These are local perception records: saw the player near the well, heard shouting in the square, noticed the shop was closed, observed rain beginning, saw the guard run east. Raw observations are not yet memories of equal significance. They are candidates for retention.

Tagged events are the second layer. Some observations are promoted because they are salient, role-relevant, surprising, repeated, socially important, or operationally disruptive. An event record should include what happened, where, who was involved, whether it was direct or second-hand, and why it mattered. A public argument, a missed delivery, an injury, a theft rumor, an offered favor, or a route blockage should become tagged memory candidates.

Relationship updates form a separate but connected memory class. They encode changes in trust, expectation, warmth, obligation, fear, resentment, or reliability concerning other actors. They should not merely be diary entries. They should alter how future interactions are filtered.

Place familiarity is another distinct layer. A place is not just a coordinate; it accumulates familiarity, comfort, danger association, social expectation, and route confidence. This matters both for planning and for local behavior.

Unresolved concerns should be represented explicitly. These are not just memories of events; they are open loops. An NPC heard that someone was missing. A payment is overdue. A conflict remains unaddressed. The player acted suspiciously. An animal was seen near the fields. These concerns should bias planning and retrieval.

Summarized reflections should condense clusters of memory into more durable abstractions: the market has been tense lately, the player is helpful but disruptive, the east road has become unreliable, the blacksmith and baker are no longer getting along. Reflection should not overwrite raw memory; it should sit above it as an interpretive compression useful for later planning.

Active intentions belong in memory as well, because they must survive interruption. Recently failed strategies should also be stored. If an NPC repeatedly tried a route that was blocked, repeatedly attempted to talk to someone unavailable, or repeatedly delayed a difficult errand, that history should alter future choices.

Socially acquired beliefs and rumors require source metadata. An NPC may believe that wolves were seen near the mill, but the system should know whether that came from direct observation, a trusted guard, a gossiping child, or a notoriously unreliable drunk.

The key distinction is this. Observation is what entered perception. Memory is what survived. Reflection is what was generalized. Planning change is what alters future intentions. Local behavior change is what biases immediate reactions. Retrieval must support both slow planning and fast local reaction. A guard hearing a sudden shout may retrieve a recent rumor about theft and react quickly. A shopkeeper planning the afternoon may retrieve a summarized reflection that business has been poor on rainy days and stay home longer. Memory should therefore support both rapid salience-triggered access and slower relevance-driven review.

## PART 7 — Planning Model

Planning in a living town should be hierarchical without being rigid. There must be a broad daily agenda, short-horizon plan chunks, immediate local action, interruption handling, and re-entry logic. Without this structure, the system either becomes an inflexible scheduler or dissolves into reactive drift.

The broad daily agenda defines the major obligations and intentions: open the stall, visit the healer, deliver a package, check on a neighbor, patrol a route, gather supplies, attend a public event if conditions allow. This agenda gives the day shape. It should be informed by role, routine, recent memory, unresolved concerns, and social commitments.

Short-horizon plan chunks convert broad agenda items into bounded sequences. Instead of “manage the shop all day,” the system should think in chunks such as travel to the shop, unlock and arrange, serve during the morning period, visit the square briefly, return, close before dusk. Chunks make replanning tractable and allow interruption without losing the whole day’s coherence.

Immediate local action belongs to Layer 1, but it should remain attached to the current chunk. If the chunk is “travel to market,” immediate local action decides how to walk, whether to avoid a crowd, whether to stop for a short conversation, whether to help someone who dropped goods, whether to react to the player blocking the path. This is how planning and local adaptation remain connected rather than isolated.

Interrupt handling is essential. An NPC should be able to intend one thing and be diverted by danger, curiosity, conversation, obligation, or player interference. The system then needs to decide whether to resume, abandon, or revise the original plan. That decision should depend on interruption severity, task commitment, role pressure, current modulation, recent failures, and unresolved concerns. A trivial conversation should not permanently destroy a strong obligation. A major danger should.

Re-entry after interruption must be explicit. Many game NPCs fail here; they either snap back unnaturally or lose the thread forever. The architecture should preserve suspended intentions with context: what was being done, how far along it was, why it mattered, and whether the reasons still hold. After the interruption resolves, the executive layer can resume the chunk, revise it, or abandon it with consequences.

Planning should use memory, current role, social commitments, and recent failures together. Memory provides what matters now. Role provides baseline obligation. Social commitments provide external pressure. Recent failures prevent naïve repetition. The result should be an agent that can continue to have a day even when the player repeatedly collides with it in real time.

## PART 8 — Social Propagation

Information should move through the town by multiple channels with loss, distortion, and selectivity. The architecture should not simulate all social awareness as omniscient global state, nor should it require giant language-model deliberation for every transfer.

Direct observation is the strongest channel. If an NPC sees the player steal, sees a fight, sees smoke, or sees the mayor making preparations, that should become a high-confidence event memory. Direct conversation is the next strongest. One NPC telling another that something happened should transfer content with source identity, trust weighting, and situational salience.

Rumor or second-hand transmission should be weaker and more deformable. A rumor may preserve the event but blur who, when, or why. Partial misunderstandings should be expected. A reported argument becomes “they’re feuding.” A wolf sighting becomes “the east road is unsafe.” This is not noise for its own sake; it creates social texture and differentiates what different NPCs believe.

Salience-based spread is important. Public danger, scandal, festival news, a missing person, and player violence should propagate more aggressively than minor inconveniences. Role-filtered spread should also matter. Guards share security-relevant information more readily with guards. Merchants share supply and trade rumors. Children spread spectacle. Healers attend to sickness and injury. Trust-weighted spread should determine whether information is accepted, repeated, doubted, or ignored.

Location-based spread is equally important. Taverns, squares, markets, gatehouses, and wells are social amplifiers. Home interiors are not. Event decay over time should prevent the town from becoming clogged with stale social state. Old rumors fade unless refreshed. Minor incidents disappear. Major events persist as reflections or relationship changes.

This yields believable town life because the world reacts through structured channels rather than through universal script triggers or full-blown freeform reasoning everywhere. Information moves because somebody saw something, told somebody, misremembered it, trusted the source, overheard it in a public place, or dismissed it. This is enough to create variation and consequence without asking a large text model to simulate the entire town at conversational granularity at all times.

## PART 9 — Evaluation Criteria

Success should be evaluated in systemic terms rather than vague claims of immersion. The first measure is believable continuity of existence. NPCs should appear to have ongoing lives whether or not the player is currently interacting with them. This does not require full simulation at all moments, but it does require continuity in plans, relationships, knowledge, and location.

The second measure is schedule coherence with plausible deviation. NPCs should have recognizable routines, but those routines should bend for reasons. A baker who never deviates feels mechanical. A baker who deviates randomly feels fake. The architecture should produce routine plus interruption-sensitive adjustment.

The third measure is local reactivity that is not purely scripted. Real-time player interaction should meaningfully perturb behavior. Blocking a route, starting a conversation, causing panic, dropping an item, or helping during a crisis should have effects that emerge from current state, not just from hand-authored one-off triggers.

Memory affecting behavior in visible ways is another key criterion. If memory exists but does not alter future plans, trust, place choices, or local reactions, it is decorative. Socially propagated events should produce different outcomes depending on who knew what, when they knew it, and whether they trusted the source. Role-consistent but not deterministic behavior is also required: the guard should still feel like a guard, but not like a clockwork guard.

Readable internal state summaries matter because Layer 2 must be more than flavor text. The compact projection surface should correspond to visible modulation. Stable modulation instead of chaos is another criterion. A compact interface that oscillates incoherently or overdrives local behavior is a failure. Path dependence should be visible in action. Recovery from interruption should be legible. Player-observable consequences should exist at both local and town levels.

Failure modes are equally important. NPCs that feel like puppets are a failure: they only animate scripts and forget everything. Town behavior that is only decorative is a failure: the schedule exists but has no social consequence. Plans that do not survive contact with the world are a failure: every interruption erases intention. Memory that does not matter is a failure: the logs grow, nothing changes. Local behavior disconnected from planning is a failure: the NPC’s fast actions do not reflect broader commitments. Layer 2 becoming fake flavor text is a failure: readable summaries exist, but they do not map to meaningful control. Overuse of language-like reasoning for procedural problems is a failure: every small action requires symbolic interpretation. Incoherent oscillation between states is a failure: the architecture becomes unstable, indecisive, or theatrically reactive.

## PART 10 — Programming-Oriented Conceptual Breakdown

A future implementation should likely be separated into subsystems with clear ownership boundaries.

The world state subsystem should own places, adjacency, occupancy, public events, time, environmental conditions, and globally relevant facts. It should not own individual NPC memory or private intentions. It provides the stage and public ecology.

The NPC state subsystem should own each agent’s persistent internal state: role, affiliations, local pressures, tendencies, familiarity, trust, current plan chunk, active commitments, current action, interruption status, and relevant modulation state. It should not own other NPCs’ internal truth, only beliefs or memories about them.

Observation intake should own perception events generated from world exposure: who saw what, heard what, entered what space, encountered whom, or experienced which change. It should not decide long-term significance by itself; it only supplies structured perception candidates.

The memory store should own retained observations, tagged events, relationship updates, place familiarity, unresolved concerns, reflections, active intentions, recently failed strategies, and socially acquired beliefs. It should not directly decide behavior; it should provide retrievable history.

The reflection system should own periodic summarization and abstraction from memory. It should generate compact higher-level beliefs or concerns from memory clusters. It should not run continuously or own local reactions.

The plan generator should own agenda formation and short-horizon plan chunks. It should consult role, memory, reflection, current circumstances, and unresolved concerns. It should not own immediate pathing or local interruption responses.

The social exchange system should own direct conversation transfers, rumor propagation, source metadata, trust-weighted belief acceptance, and event spread through co-presence or communication. It should not own the full memory system, only the mechanics of social transfer.

Layer 1 behavior substrate should own local behavioral variables, action tendency calculation, interruption thresholds, momentum, persistence, recovery, low-level adaptation, and selection among immediate procedural actions. It should not own broad daily agenda or social rumor diffusion logic.

Layer 2 projection/modulation should own compact projection of Layer 1 state, bounded modulation parameters, translation between top-down framing and low-level biases, and inspection-ready summaries. It should not own narrative planning or claim to be the real inner state.

Layer 3 executive should own agenda formation, role coherence, social goals, chunk planning, and top-down framing. It should not own every immediate action or low-level stimulus response.

A scheduler or cadence manager should own update frequencies and cross-timescale coordination. It should decide when observation batches are committed, when reflection runs, when plans refresh, when propagation pulses occur, and when local behavior updates. It should not own the substantive logic of behavior itself.

An event queue should own time-ordered discrete incidents: public events, triggered interruptions, scheduled commitments, propagated rumors, pending conversations, delayed consequences. It should not own persistent memory or plans, only the sequencing of occurrences.

Debugging and inspection interfaces should own visibility into the system: current local pressures, projection coordinates, active commitments, memory excerpts, belief sources, interruption reasons, and plan state. They should not alter behavior directly except through explicit testing controls. This subsystem is not optional. Without it, the architecture will be opaque and impossible to tune.

## PART 11 — Prototype Scope Recommendation

The first prototype should be deliberately small. Not because the vision is small, but because the architecture must become legible before it becomes large.

A strong first scope is a small town with perhaps six to ten NPCs, a single in-game day or a short repeating day cycle, three to four roles, three to five shared public places, a handful of private spaces, a few relationship types, and a narrow set of event types. The world only needs enough complexity to expose memory, planning, social propagation, interruption, and local adaptation.

The roles should be chosen for contrast: one merchant-like routine role, one duty-bound patrol or caretaker role, one socially central gossip-like role, one errand or courier role, one home-centered role, and perhaps one irregular or unstable role. Shared places should include at least one rumor-rich public hub, one work site, one route bottleneck, and one semi-private threshold space. Relationship types need not be elaborate; trust, warmth, obligation, and suspicion may be enough at first.

Event types should be limited but consequential: a public argument, a blocked route, a missed appointment, a request for help, an injury or scare, a player-caused disturbance, and perhaps a scheduled town event. This is enough to test whether information propagates, whether plans bend, whether memories alter trust or avoidance, and whether NPCs can resume or abandon tasks coherently.

Real-time player interaction must be central in the prototype. The player should be able to interrupt movement, initiate conversation, cause minor trouble, provide help, block access, appear at unexpected times, and alter the information environment. If the architecture only works in offline town simulation and collapses once a human begins interfering continuously, then it is not suitable for the intended game.

Starting small is not merely convenient. It is necessary for interpretability. Large simulations conceal architectural weakness behind volume. A small prototype lets you trace why an NPC changed course, why a rumor spread, why a plan failed, why a trust score shifted, and whether Layer 2 actually maps to behavioral modulation. A small world forces the architecture to justify itself in observable terms. It makes debugging possible and failure intelligible.

## PART 12 — Final Synthesis

This system is a simulation-first adaptive NPC architecture for a living town world. It combines a persistent social-memory harness with a three-layer agent model in which Layer 1 is the real behavioral substrate, Layer 2 is a compact human-legible translation and modulation surface, and Layer 3 is an executive layer for agenda, planning, and symbolic direction.

It is not a theory of synthetic affect, not a claim about consciousness, and not an attempt to replace all procedural game AI with text-like reasoning. The compact coordinate space in Layer 2 is not the NPC’s true state. It is an interface surface for summarizing and steering deeper procedural dynamics.

The town harness matters because adaptive behavior needs ecology. Persistent places, recurring routines, repeated encounters, rumor channels, interruptions, and player disturbance provide the conditions under which continuity, memory, and planning become meaningful rather than decorative.

The three-layer model matters because a town planner alone cannot produce grounded local behavior, and ordinary scripted NPC logic cannot produce persistent social continuity with path dependence. The combination is stronger than either extreme. A pure social-planning simulation tends to become slow, textual, and detached from moment-to-moment action. Ordinary scripted logic tends to be immediate but forgetful, rigid, and socially hollow.

What you are building, then, is neither a town full of prompt-driven puppets nor a set of ordinary schedule actors with cosmetic memory. You are building a world in which NPCs can carry history, form intentions, react in real time, get interrupted, remember what mattered, propagate information socially, and still be steered through a compact readable interface without reducing their actual behavior to that interface. That is the value of the design.
