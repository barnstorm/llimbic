"""
Thought Loop Engine — async coroutine per NPC.

Each NPC runs a thought cycle at adaptive cadence (2-8 seconds):
  1. L2 limbic: color raw perception → base emotion vector
  2. L3 executive: generate_thought() → thoughts + tool calls
  3. L2 limbic: color the thoughts themselves → updated emotion vector
  4. Compile push commands from tool call results
  5. Push to client via WebSocket

The server is authoritative for emotions, intentions, and beliefs.
The client is authoritative for L1 drives, position, and perception.
"""

import asyncio
import json
import time
import logging
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from npc_state import NPCState
from perception_rank import attention_entropy, h_floor
from identity_phantom import build_phantom_nudges
from intention_attention import IntentionAttention
from trace_logger import trace_thought, trace_speech

# Optional appraisal bridge (Phase 0). Both imports are guarded so the server
# still works when the embedding bridge or decode matrix isn't yet available.
try:
    from embedding_source import EmbeddingSource  # noqa: F401  (type only)
    from appraisal_embeddings import AppraisalEmbeddingManager
    _APPRAISAL_AVAILABLE = True
except Exception as _e:  # pragma: no cover
    AppraisalEmbeddingManager = None  # type: ignore
    _APPRAISAL_AVAILABLE = False

# Phase 5 identity-appraisal tracker. Same guard — no-op gracefully if the
# embedding bridge isn't available (tracker needs the source for the F2
# cosine branch).
try:
    from identity_appraisal import IdentityAppraisalTracker
    _IDENTITY_AVAILABLE = True
except Exception as _e:  # pragma: no cover
    IdentityAppraisalTracker = None  # type: ignore
    _IDENTITY_AVAILABLE = False


def _narrate_body(context: dict) -> str:
    """Build a felt body-state narrative from drives and somatic tags.

    Deterministic template — no model call. Produces 2-4 short second-person
    sentences the command model can reason from.
    """
    drives = context.get("drives", {})
    energy = drives.get("energy", 80)
    hunger = drives.get("hunger", 20)
    social = drives.get("social_need", 30)
    safety = drives.get("safety", 80)
    frustration = drives.get("frustration", 0)

    vagal = context.get("vagal_state", {})
    ventral = vagal.get("ventral", 60)
    sympathetic = vagal.get("sympathetic", 20)
    dorsal = vagal.get("dorsal", 5)

    parts = []

    # Hunger
    if hunger > 80:
        parts.append("Your stomach is gnawing at you. You need food badly.")
    elif hunger > 60:
        parts.append("Your stomach feels empty. You could use a meal.")
    elif hunger > 40:
        parts.append("You're getting a bit hungry.")
    elif hunger < 10:
        parts.append("Your stomach feels settled and full.")

    # Energy
    if energy < 15:
        parts.append("You can barely keep your eyes open. Your body is shutting down.")
    elif energy < 30:
        parts.append("Your muscles are heavy and your head is foggy. You need rest.")
    elif energy < 50:
        parts.append("You're getting tired.")
    elif energy > 85:
        parts.append("You feel rested and alert.")

    # Safety
    if safety < 25:
        parts.append("Your skin is prickling. Something feels wrong. You want to run.")
    elif safety < 40:
        parts.append("You feel uneasy. Your chest is tight.")
    elif safety > 90:
        parts.append("You feel safe here.")

    # Social
    if social > 80:
        parts.append("There's an aching hollowness in your chest. You need to be around people.")
    elif social > 60:
        parts.append("You're feeling lonely. Some company would help.")
    elif social > 40:
        parts.append("You could use some conversation.")

    # Frustration
    if frustration > 0.7:
        parts.append("Frustration is building. Nothing is going right.")
    elif frustration > 0.4:
        parts.append("You're feeling a bit frustrated.")

    # Vagal state
    if dorsal > sympathetic and dorsal > ventral and dorsal > 40:
        parts.append("You feel disconnected, like you're watching from far away.")
    elif sympathetic > ventral and sympathetic > 40:
        parts.append("Your body is tense and alert. Ready to move.")

    # Fallback — nothing notable
    if not parts:
        parts.append("You feel calm. Nothing demands your attention.")

    return " ".join(parts)

log = logging.getLogger("layer3")  # share logger with layer3_server for file output

# Shared executor for blocking model calls
_executor = ThreadPoolExecutor(max_workers=4)

# F6 attention-entropy floor factor. Seeded from constants at import time; the
# thought-loop records this alongside the tick entropy so every trace carries
# the threshold it was measured against (no hardcoded gate in replay).
try:
    import json as _json
    _fp = Path(__file__).resolve().parent.parent / "data" / "perception_constants.json"
    with _fp.open() as _cf:
        _H_FACTOR_FOR_THOUGHT_LOOP = float(_json.load(_cf).get(
            "h_min_attention_entropy_factor", 0.6
        ))
except Exception:
    _H_FACTOR_FOR_THOUGHT_LOOP = 0.6


async def _run(fn, *args):
    return await asyncio.get_event_loop().run_in_executor(_executor, fn, *args)


class ThoughtLoop:
    """Manages per-NPC thought loops and push delivery."""

    def __init__(
        self,
        l2_model,
        l3_model,
        embedding_source=None,
        appraisal_manager=None,
        saves_dir: str | Path = "saves",
    ):
        self.l2 = l2_model
        self.l3 = l3_model
        self.npc_states: dict[str, NPCState] = {}
        self._ws = None  # shared WebSocket reference (set when client connects)
        self._tasks: dict[str, asyncio.Task] = {}  # npc_name -> running loop task
        self._running = True

        # Phase 0 bridge — both may be None if the matrix or server isn't ready.
        # When None, snapshot handling and cortical feedback no-op gracefully.
        self.embedding_source = embedding_source
        self.appraisal_manager = appraisal_manager
        self.saves_dir = Path(saves_dir)
        if self.appraisal_manager is None:
            log.info("ThoughtLoop: appraisal embedding bridge DISABLED "
                     "(no manager provided). Cortical feedback will no-op.")
        else:
            log.info("ThoughtLoop: appraisal embedding bridge ENABLED. "
                     "Saves dir: %s", self.saves_dir)

        # Phase 5 — identity-appraisal tracker. Reads constants lazily so it
        # picks up whatever seed values are current at startup. Disabled if
        # the embedding bridge is off (needs the source for F2 cosine match).
        self.identity_tracker = None
        self.intention_attention = None
        if (_IDENTITY_AVAILABLE
                and self.embedding_source is not None
                and self.appraisal_manager is not None):
            try:
                import json as _json
                _consts_path = Path(__file__).resolve().parent.parent / "data" / "perception_constants.json"
                with _consts_path.open() as _f:
                    _consts = _json.load(_f)
                _enc_thr = int(_consts["neurogenesis_thresholds"]["encounter_threshold"])
                _bind_thr = float(_consts["thought_entity_bind_threshold"])
                self.identity_tracker = IdentityAppraisalTracker(
                    self.embedding_source,
                    encounter_threshold=_enc_thr,
                    bind_cosine_threshold=_bind_thr,
                )
                log.info("ThoughtLoop: identity-appraisal tracker ENABLED "
                         "(encounter_threshold=%d, bind_threshold=%.2f)",
                         _enc_thr, _bind_thr)
                # Phase 11 — intention-attention selector. Reuses the same
                # embedding source + appraisal manager; no new infrastructure.
                _topk = int(_consts["neurogenesis_thresholds"]["intention_top_k_concepts"])
                _bootstrap_concepts = list(_consts["embedding_bridge"]["bootstrap_concepts"])
                self.intention_attention = IntentionAttention(
                    self.embedding_source,
                    self.appraisal_manager,
                    _bootstrap_concepts,
                    _topk,
                )
                log.info("ThoughtLoop: intention-attention ENABLED "
                         "(top_k=%d, bootstrap_concepts=%d)",
                         _topk, len(_bootstrap_concepts))
            except Exception as e:
                log.warning("ThoughtLoop: identity/intention init failed: %s", e)
                self.identity_tracker = None
                self.intention_attention = None

    def set_websocket(self, ws):
        """Set the shared WebSocket for push delivery."""
        self._ws = ws

    async def register_npc(self, npc_name: str, persona: dict):
        """Register an NPC and start its thought loop."""
        role = persona.get("role", "Villager")

        if npc_name in self.npc_states:
            # Already registered — update persona if needed
            log.info(f"NPC {npc_name} re-registered")
            return

        state = NPCState(npc_name, role, persona)
        self.npc_states[npc_name] = state
        log.info(f"[THOUGHT LOOP] Registered {npc_name} ({role}), "
              f"{len(state.active_intentions)} routine intentions")

        # Load persisted appraisals if any (per spec §3.7).
        if self.appraisal_manager is not None:
            try:
                path = self.saves_dir / npc_name / "appraisals.json"
                loaded = self.appraisal_manager.load(npc_name, path)
                if loaded:
                    log.info(f"[THOUGHT LOOP] {npc_name}: loaded {loaded} persisted appraisals")
            except Exception as e:
                log.warning(f"[THOUGHT LOOP] {npc_name}: appraisal load failed: {e}")

        # Start the thought loop coroutine
        task = asyncio.create_task(self._npc_loop(npc_name))
        self._tasks[npc_name] = task

    async def receive_snapshot(self, npc_name: str, snapshot: dict):
        """Called when client sends a state update."""
        state = self.npc_states.get(npc_name)
        if state is None:
            # Auto-register if we get a snapshot for an unknown NPC
            # (handles reconnection after server restart)
            log.warning(f"Snapshot for unregistered NPC {npc_name}, ignoring")
            return
        state.receive_snapshot(snapshot)

        # Drain newly-spawned appraisal neurons announced by the GDScript Hebbian
        # network (handshake per perception_implementation_plan.md Phase 0.6) and
        # initialize each in the embedding manager.
        if self.appraisal_manager is None:
            return
        appraisal = snapshot.get("appraisal") or {}
        new_neurons = appraisal.get("new_neurons") or []
        for entry in new_neurons:
            try:
                neuron_id = str(entry.get("id"))
                seed = entry.get("embedding_seed") or {}
                if not neuron_id or not seed:
                    continue
                if self.appraisal_manager.has_neuron(npc_name, neuron_id):
                    continue
                # seed values from GDScript are 0..100; normalize to 0..1 weights.
                seed_weights = {str(k): float(v) / 100.0 for k, v in seed.items()}
                self.appraisal_manager.initialize(npc_name, neuron_id, seed_weights)
                log.info("[APPRAISAL] %s: initialized %s seed=%s",
                         npc_name, neuron_id, list(seed_weights.keys()))
            except Exception as e:
                log.warning("[APPRAISAL] %s: initialize failed for %s: %s",
                            npc_name, entry, e)

    async def shutdown(self):
        """Stop all thought loops and persist appraisal state."""
        self._running = False
        # Persist long-standing appraisal neurons before shutdown.
        if self.appraisal_manager is not None:
            for npc_name in list(self.npc_states.keys()):
                try:
                    path = self.saves_dir / npc_name / "appraisals.json"
                    self.appraisal_manager.persist(npc_name, path)
                except Exception as e:
                    log.warning(f"[APPRAISAL] persist failed for {npc_name}: {e}")
        for task in self._tasks.values():
            task.cancel()
        self._tasks.clear()

    # --- Per-NPC loop ---

    async def _npc_loop(self, npc_name: str):
        """Continuous thought loop for one NPC."""
        state = self.npc_states[npc_name]
        log.info(f"[THOUGHT LOOP] Loop started for {npc_name}")

        # Wait for first snapshot before thinking
        while self._running and not state.has_fresh_snapshot(max_age=30.0):
            await asyncio.sleep(1.0)

        while self._running:
            try:
                if state.should_think() and state.has_fresh_snapshot():
                    await self._run_thought_cycle(npc_name)
                    state.last_thought_time = time.time()

                # Sleep briefly, then check again
                await asyncio.sleep(0.5)

            except asyncio.CancelledError:
                break
            except Exception as e:
                log.error(f"Thought loop error for {npc_name}: {e}", exc_info=True)
                await asyncio.sleep(5.0)  # back off on error

        log.info(f"[THOUGHT LOOP] Loop stopped for {npc_name}")

    async def _run_thought_cycle(self, npc_name: str):
        """One iteration of the thought loop."""
        state = self.npc_states[npc_name]
        context = state.build_thought_context()

        # Phase 6 — F6 attention-entropy monitor. `context` now carries the
        # top-K propagation weights for the ranked percepts consumed this
        # cycle. Compute Shannon entropy over the normalized weights and
        # push into the rolling-window gate. Zero-weight cold-start yields
        # H=0 which correctly signals undifferentiated attention.
        tick_entropy = attention_entropy(context.get("perception_top_k_weights", []))
        state.record_entropy(tick_entropy)

        t0 = time.time()

        # Step 1: Build body narrative from drives + somatic tags
        # Deterministic template — always correct, no model call needed.
        # TinyLlama can refine this later once fine-tuned on narrative output.
        snap_emotions = {}
        emo_vec = context.get("emotion_vector", state.emotion_vector)
        context["body_narrative"] = _narrate_body(context)

        # Phase 7 — decode active identity-appraisals BEFORE rendering the
        # prompt so the flat Percept renderer can inline tokens per spec §6.4.
        # Without this, decoded tokens are only computed post-thought for the
        # trace and the model never sees emergent identity content in-prompt.
        pre_prompt_identity_decoded: dict[str, list[str]] = {}
        if self.appraisal_manager is not None:
            try:
                for eid in state.visible_eid_to_name.keys():
                    nid = f"appr_identity_{eid}"
                    if self.appraisal_manager.has_neuron(npc_name, nid):
                        pre_prompt_identity_decoded[eid] = self.appraisal_manager.decode(npc_name, nid)
            except Exception as e:
                log.warning(f"[IDENTITY] pre-prompt decode failed for {npc_name}: {e}")
        context["identity_appraisal_decoded"] = pre_prompt_identity_decoded

        # Step 2: L3 executive generates thoughts
        thought_result = {"thoughts": [], "intentions": [], "beliefs": [],
                          "action_biases": {}, "raw": ""}
        if self.l3 is not None:
            try:
                # Inject current emotions into context for the thought prompt
                context["emotion_vector"] = emo_vec
                thought_result = await _run(self.l3.generate_thought, context)
            except Exception as e:
                log.warning(f"L3 thought generation failed for {npc_name}: {e}")

        # Step 2b: Cortical feedback — drift active appraisal embeddings toward
        # the generated thought (perception_spec §3.6). This is what gives each
        # appraisal a per-being trajectory through LLM latent space, decoded
        # back to tokens that reflect *this* being's interpretation of *this*
        # body pattern.
        #
        # Phase 5: the same thought embedding also feeds the identity-appraisal
        # tracker, which runs the F2 association filter against currently-
        # visible entities and (on threshold) requests a spawn.
        thought_emb = None
        identity_events: list = []
        identity_spawns: list = []
        if (self.embedding_source is not None
                and thought_result.get("thoughts")):
            try:
                think_text = thought_result["thoughts"][0]
                if think_text:
                    thought_emb = await _run(self.embedding_source.embed, think_text)
                    if not (isinstance(thought_emb, np.ndarray)
                            and float(np.linalg.norm(thought_emb)) > 1e-6):
                        thought_emb = None
            except Exception as e:
                log.warning(f"[APPRAISAL] embed(thought) failed for {npc_name}: {e}")
                thought_emb = None

        if (thought_emb is not None
                and self.appraisal_manager is not None
                and state.last_active_appraisals):
            try:
                for nid, activation in state.last_active_appraisals.items():
                    self.appraisal_manager.drift(
                        npc=npc_name,
                        neuron_id=nid,
                        activation=float(activation),
                        thought_embedding=thought_emb,
                    )
            except Exception as e:
                log.warning(f"[APPRAISAL] cortical feedback failed for {npc_name}: {e}")

        if (thought_emb is not None
                and self.identity_tracker is not None
                and self.appraisal_manager is not None
                and state.visible_eid_to_name):
            try:
                visible_pairs = list(state.visible_eid_to_name.items())
                think_text = thought_result["thoughts"][0] if thought_result.get("thoughts") else ""
                events, spawns = self.identity_tracker.associate_thought(
                    npc=npc_name,
                    thought_text=think_text,
                    thought_emb=thought_emb,
                    visible_entities=visible_pairs,
                )
                identity_events = events
                for sp in spawns:
                    # Python side: initialize the embedding from the deque mean.
                    if not self.appraisal_manager.has_neuron(npc_name, sp.neuron_id):
                        self.appraisal_manager.initialize_from_thoughts(
                            npc=npc_name,
                            neuron_id=sp.neuron_id,
                            thought_embeddings=sp.thought_embeddings,
                        )
                        identity_spawns.append({
                            "neuron_id": sp.neuron_id,
                            "entity_id": sp.entity_id,
                            "entity_name": sp.entity_name,
                            "thought_count": len(sp.thought_embeddings),
                        })
                        log.info("[IDENTITY] %s: spawned %s for %s (from %d thoughts)",
                                 npc_name, sp.neuron_id, sp.entity_name,
                                 len(sp.thought_embeddings))
            except Exception as e:
                log.warning(f"[IDENTITY] tracker failed for {npc_name}: {e}")

        # Step 3: (removed — L2 now narrates body state in Step 1,
        # no longer colors thoughts into emotion vectors)

        # Step 4: Update state and compile push commands
        state.emotion_vector = emo_vec

        # Record thoughts
        for thought_text in thought_result["thoughts"]:
            state.record_thought(thought_text, snap_emotions)

        # Process intentions
        for intention in thought_result["intentions"]:
            location = intention.get("location", "")
            # Validate location exists
            if location and self.l3 and location in self.l3.locations:
                state.add_intention(
                    goal=intention["goal"],
                    location=location,
                    priority=intention.get("priority", 0.5),
                    reason=intention.get("reason", ""),
                )

        # Process beliefs
        for belief in thought_result["beliefs"]:
            state.add_belief(
                subject=belief["subject"],
                predicate=belief["predicate"],
                obj=belief["object"],
                confidence=belief.get("confidence", 0.5),
                source="self",
            )

        # Compile commands
        commands = []

        # Always push emotion update
        commands.append({
            "cmd": "update_emotion",
            "vector": emo_vec,
            "summary": ", ".join(list(snap_emotions.keys())[:3]) if snap_emotions else "neutral",
        })

        # Push thoughts
        if thought_result["thoughts"]:
            commands.append({
                "cmd": "set_thought",
                "text": thought_result["thoughts"][0][:200],
            })

        # Push intentions
        for intention in thought_result["intentions"]:
            location = intention.get("location", "")
            if location and self.l3 and location in self.l3.locations:
                commands.append({
                    "cmd": "set_intention",
                    "goal": intention["goal"],
                    "location": location,
                    "priority": intention.get("priority", 0.5),
                    "reason": intention.get("reason", ""),
                })

        # Push beliefs
        for belief in thought_result["beliefs"]:
            commands.append({
                "cmd": "store_belief",
                "subject": belief["subject"],
                "predicate": belief["predicate"],
                "object": belief["object"],
                "confidence": belief.get("confidence", 0.5),
                "source": "self",
            })

        # Push action biases
        if thought_result["action_biases"]:
            commands.append({
                "cmd": "bias_action",
                "biases": thought_result["action_biases"],
            })

        # Push trigger actions from command model
        for trigger in thought_result.get("trigger_actions", []):
            ttype = trigger.get("type", "")
            if ttype == "speak":
                commands.append({
                    "cmd": "speak",
                    "text": trigger["text"],
                    "target": trigger.get("target"),
                })
                trace_speech(npc_name, "say", {
                    "text": trigger["text"],
                    "target": trigger.get("target", ""),
                    "somatic_tags": context.get("somatic_tags", []),
                    "location": context.get("location", ""),
                    "carried_items": context.get("carried_items", []),
                    "current_thought": thought_result["thoughts"][0][:200] if thought_result.get("thoughts") else "",
                }, {"utterance": trigger["text"]}, elapsed * 1000)
            elif ttype == "examine":
                commands.append({
                    "cmd": "examine",
                    "object_id": trigger.get("object_id"),
                    "target": trigger.get("target"),
                })
            elif ttype in ("take_item", "consume_item", "drop_item", "give_item"):
                commands.append({
                    "cmd": ttype,
                    "item": trigger.get("item", ""),
                    "target": trigger.get("target"),
                })
                log.info(f"INVENTORY [{npc_name}] {ttype}: {trigger.get('item', '')}")
            elif ttype in ("offer_item", "show_item"):
                commands.append({
                    "cmd": ttype,
                    "item": trigger.get("item", ""),
                    "target": trigger.get("target"),
                })
                log.info(f"SOCIAL [{npc_name}] {ttype}: {trigger.get('item', '')} -> {trigger.get('target', '')}")
            elif ttype == "touch":
                commands.append({
                    "cmd": "touch",
                    "target_type": trigger.get("target_type", ""),
                    "target_name": trigger.get("target_name", ""),
                    "object_id": trigger.get("object_id", ""),
                    "target": trigger.get("target"),
                })
            elif ttype == "interact":
                commands.append({
                    "cmd": "interact",
                    "target_name": trigger.get("target_name", ""),
                    "object_id": trigger.get("object_id", ""),
                    "target": trigger.get("target"),
                })
            elif ttype == "watch":
                commands.append({
                    "cmd": "watch",
                    "target": trigger.get("target", ""),
                    "position": trigger.get("position"),
                })
            elif ttype == "listen":
                commands.append({
                    "cmd": "listen",
                    "target_type": trigger.get("target_type", ""),
                    "target_name": trigger.get("target_name", ""),
                    "position": trigger.get("position"),
                })
            elif ttype == "follow":
                commands.append({
                    "cmd": "follow",
                    "target": trigger.get("target", ""),
                })
            elif ttype == "point_at":
                commands.append({
                    "cmd": "point_at",
                    "target_type": trigger.get("target_type", ""),
                    "target_name": trigger.get("target_name", ""),
                    "position": trigger.get("position"),
                })
            elif ttype in ("rest", "hide"):
                commands.append({"cmd": ttype})

        elapsed = time.time() - t0

        # Push command + target if present (from adventure-command model)
        cmd_str = thought_result.get("command", "")
        target = thought_result.get("target")
        if cmd_str:
            commands.append({
                "cmd": "motor_command",
                "command": cmd_str,
                "target": target,
            })

        # Reward salience if this thought was productive — the being learns
        # what's worth thinking about. A thought that produced new intentions,
        # actions, or beliefs was useful. One that just said WAIT was not.
        thought_productive = (
            len(thought_result.get("intentions", [])) > 0
            or len(thought_result.get("trigger_actions", [])) > 0
            or len(thought_result.get("beliefs", [])) > 0
            or cmd_str not in ("", "WAIT", "WANDER")
        )
        if thought_productive:
            commands.append({"cmd": "reward_salience", "amount": 15.0})
        else:
            # Unproductive thought — slightly suppress salience so the being
            # learns not to think when nothing needs thinking about.
            commands.append({"cmd": "reward_salience", "amount": -5.0})

        # Phase 5 — push any identity-appraisal spawns produced this cycle.
        # The Hebbian side will wire sense_visible_{eid} + active somatic
        # inputs at receipt; outgoing wiring emerges via Hebbian learning.
        for sp in identity_spawns:
            commands.append({
                "cmd": "spawn_identity_appraisal",
                "neuron_id": sp["neuron_id"],
                "entity_id": sp["entity_id"],
            })

        # Phase 7 §7.2 — somatic phantom activation driven by active identity-
        # appraisal decoded tokens instead of the removed memory-lookup path.
        # Each visible entity whose `appr_identity_{eid}` is firing contributes
        # nudges to the q_{tok} neurons named by its top decoded tokens.
        identity_activations = {
            nid: float(act)
            for nid, act in state.last_active_appraisals.items()
            if str(nid).startswith("appr_identity_")
        }
        if identity_activations and identity_decoded:
            phantom_cmds = build_phantom_nudges(
                identity_decoded=identity_decoded,
                active_identity_activations=identity_activations,
                visible_eids=list(state.visible_eid_to_name.keys()),
            )
            commands.extend(phantom_cmds)

        # Phase 11 §5.6 — embed current goal, select top-K nearest concept
        # neurons, and push a pulse_intention command to the client. The
        # client's Hebbian graph activates those neurons and seeds bootstrap
        # I→sense edges; subsequent propagate() ticks apply the attention
        # amplification. No action taken if there's no goal to embed.
        intention_ctx_record: dict = {"goal_text": "", "neuron_ids": [], "scores": [], "sources": []}
        if self.intention_attention is not None:
            goal_text = ""
            top_intention = state.get_top_intention()
            if top_intention:
                goal_text = f"{top_intention.get('goal', '')} {top_intention.get('location', '')}".strip()
            try:
                ictx = self.intention_attention.select_intention_context(
                    npc=npc_name,
                    goal_text=goal_text,
                    active_appraisal_ids=list(state.last_active_appraisals.keys()),
                )
                if ictx.neuron_ids:
                    commands.append({
                        "cmd": "pulse_intention",
                        "neuron_ids": ictx.neuron_ids,
                    })
                intention_ctx_record = {
                    "goal_text": ictx.goal_text,
                    "neuron_ids": list(ictx.neuron_ids),
                    "scores": list(ictx.scores),
                    "sources": list(ictx.sources),
                }
            except Exception as e:
                log.warning("[INTENTION] select failed for %s: %s", npc_name, e)

        # Step 5: Push to client
        await self._push_commands(npc_name, commands)

        thought_preview = thought_result["thoughts"][0][:60] if thought_result["thoughts"] else "(no thought)"
        cmd_preview = thought_result.get("command", "")
        log.info(
            f"THOUGHT [{npc_name}] \"{thought_preview}\" "
            f"cmd={cmd_preview} "
            f"intents={len(thought_result['intentions'])} "
            f"beliefs={len(thought_result['beliefs'])} "
            f"biases={thought_result['action_biases']} "
            f"[{elapsed:.1f}s]"
        )

        # Decode currently-active appraisals for the trace (v2 schema). The
        # decoded tokens are what downstream training-data replay turns into
        # the "Body sense:" line of the LLM prompt; capturing them per-cycle
        # is essential for replay fidelity.
        appraisal_decoded: dict[str, list[str]] = {}
        if (self.appraisal_manager is not None
                and state.last_active_appraisals):
            try:
                appraisal_decoded = self.appraisal_manager.get_active_decoded(
                    npc_name, state.last_active_appraisals,
                )
            except Exception as e:
                log.warning(f"[APPRAISAL] decode failed for {npc_name}: {e}")

        # Phase 5 — eid-keyed decoded tokens for every identity-appraisal
        # currently tracked on the Python side. This is the trace field the
        # spec calls out as "decoded tokens flow into trace v2 alongside the
        # entity". Use has_neuron() to avoid decoding non-identity appraisals.
        identity_decoded: dict[str, list[str]] = {}
        if self.appraisal_manager is not None:
            try:
                for eid in state.visible_eid_to_name.keys():
                    nid = f"appr_identity_{eid}"
                    if self.appraisal_manager.has_neuron(npc_name, nid):
                        identity_decoded[eid] = self.appraisal_manager.decode(npc_name, nid)
            except Exception as e:
                log.warning(f"[IDENTITY] decode failed for {npc_name}: {e}")

        # Serialize F2 audit events for trace v2.
        entity_thought_associations: list[dict] = [
            {"eid": ev.eid, "name": ev.name, "matched": ev.matched,
             "method": ev.method, "score": round(float(ev.score), 4)}
            for ev in identity_events
        ]

        # Phase 8 F5 — per-tick appraisal drift_count snapshot. Needed so the
        # maturity classifier (and the v3 training-data generator) can gate
        # on `mean_drift_count_per_appraisal`. Without this, drift-count is
        # only available at shutdown via the persist file.
        appraisal_drift_counts: dict[str, int] = {}
        if self.appraisal_manager is not None:
            try:
                appraisal_drift_counts = self.appraisal_manager.get_drift_counts(npc_name)
            except Exception as e:
                log.warning(f"[APPRAISAL] drift_counts snapshot failed for {npc_name}: {e}")

        # Phase 6 F6 trace fields — per-tick entropy plus rolling 10-min mean
        # and the current H_MIN floor (derived from K). Traces are the
        # regression substrate for F6 across every later phase, so the full
        # context lands here rather than only the tick value.
        k_for_floor = max(1, len(context.get("perception_top_k_weights", [])))
        attention_entropy_info = {
            "tick": float(tick_entropy),
            "mean_10min": float(state.rolling_entropy_mean(600.0)),
            "h_min": float(h_floor(k_for_floor, _H_FACTOR_FOR_THOUGHT_LOOP)),
            "k": int(k_for_floor),
            "fallback": bool(context.get("perception_fallback", False)),
            "total_considered": int(context.get("perception_total_considered", 0)),
        }

        # Phase 7 — rebuild the rendered prompt and compound/fallback metrics
        # for trace recording. The prompt string is the exact input the model
        # saw this tick; spec §6.5 requires it for v3-training replay fidelity.
        try:
            from perception import render as _render_perception
            prompt_rendered_text, _ = _render_perception(context)
        except Exception:
            prompt_rendered_text = ""
        # Grammar-derived F4 metrics flow through the thought_result (set in
        # command_model); fall back to None so the trace field is null rather
        # than a fabricated zero if the legacy path generates the thought.
        compounds_state = context.get("compounds") or {}

        # Structured trace for training data
        trace_thought(
            npc_name, context, thought_result, elapsed * 1000,
            active_appraisals=state.last_active_appraisals,
            appraisal_decoded=appraisal_decoded,
            reward_events=state.last_reward_events,
            new_identity_appraisals=identity_spawns,
            entity_thought_associations=entity_thought_associations,
            identity_appraisal_decoded=identity_decoded,
            attention_entropy=attention_entropy_info,
            prompt_rendered=prompt_rendered_text,
            fallback_contribution=thought_result.get("fallback_contribution"),
            fallback_coefficient=thought_result.get("fallback_coefficient"),
            compounds_state=compounds_state,
            verbs_via_compound=thought_result.get("verbs_via_compound") or [],
            verbs_via_fallback=thought_result.get("verbs_via_fallback") or [],
            appraisal_drift_counts=appraisal_drift_counts,
            cross_modal_state=context.get("cross_modal"),
            temporal_state=context.get("temporal"),
            intention_state=context.get("intention"),
            intention_context=intention_ctx_record,
        )
        # Drain so we don't double-attribute to the next thought cycle.
        state.last_reward_events = []

    async def _push_commands(self, npc_name: str, commands: list[dict]):
        """Push commands to client via WebSocket."""
        if not commands:
            return
        if self._ws is None:
            return

        msg = json.dumps({
            "push": True,
            "npc": npc_name,
            "commands": commands,
        })

        try:
            await self._ws.send_text(msg)
        except Exception as e:
            log.warning(f"Push failed for {npc_name}: {e}")

    # --- Conversation belief extraction (called from converse/chat handlers) ---

    async def extract_conversation_beliefs(self, listener_name: str, listener_role: str,
                                            utterance: str, speaker_name: str):
        """Extract beliefs from a conversation and push to the listener NPC."""
        if self.l3 is None:
            return

        state = self.npc_states.get(listener_name)
        if state is None:
            return

        try:
            result = await _run(
                self.l3.extract_beliefs_from_conversation,
                listener_name, listener_role, utterance, speaker_name,
            )
            beliefs = result.get("beliefs", [])
            if not beliefs:
                return

            commands = []
            for belief in beliefs:
                state.add_belief(
                    subject=belief["subject"],
                    predicate=belief["predicate"],
                    obj=belief["object"],
                    confidence=belief.get("confidence", 0.5),
                    source=speaker_name,
                )
                commands.append({
                    "cmd": "store_belief",
                    "subject": belief["subject"],
                    "predicate": belief["predicate"],
                    "object": belief["object"],
                    "confidence": belief.get("confidence", 0.5),
                    "source": speaker_name,
                })

            if commands:
                await self._push_commands(listener_name, commands)
                log.info(f"BELIEF_EXTRACT [{listener_name}] {len(beliefs)} beliefs from {speaker_name}")

        except Exception as e:
            log.warning(f"Belief extraction failed for {listener_name}: {e}")
