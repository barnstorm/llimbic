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
from concurrent.futures import ThreadPoolExecutor

from npc_state import NPCState
from trace_logger import trace_thought, trace_speech


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


async def _run(fn, *args):
    return await asyncio.get_event_loop().run_in_executor(_executor, fn, *args)


class ThoughtLoop:
    """Manages per-NPC thought loops and push delivery."""

    def __init__(self, l2_model, l3_model):
        self.l2 = l2_model
        self.l3 = l3_model
        self.npc_states: dict[str, NPCState] = {}
        self._ws = None  # shared WebSocket reference (set when client connects)
        self._tasks: dict[str, asyncio.Task] = {}  # npc_name -> running loop task
        self._running = True

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

    async def shutdown(self):
        """Stop all thought loops."""
        self._running = False
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

        t0 = time.time()

        # Step 1: Build body narrative from drives + somatic tags
        # Deterministic template — always correct, no model call needed.
        # TinyLlama can refine this later once fine-tuned on narrative output.
        snap_emotions = {}
        emo_vec = context.get("emotion_vector", state.emotion_vector)
        context["body_narrative"] = _narrate_body(context)

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

        # Structured trace for training data
        trace_thought(npc_name, context, thought_result, elapsed * 1000)

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
