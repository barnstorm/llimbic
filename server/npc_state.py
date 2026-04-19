"""
Per-NPC server-side state for the thought loop.

Each NPC has an NPCState that holds:
- Active intentions (persistent goals that bias behavior)
- Beliefs (structured knowledge from observation and conversation)
- Thought history (ring buffer of recent thoughts + emotional responses)
- Last client snapshot (drives, position, perceptions)
- Pending push commands (queued for delivery to client)
- Adaptive cadence control (urgency → thought interval)
"""

import json
import time
from collections import deque
from pathlib import Path

from perception_rank import rank_percepts, attention_entropy

# Constants loaded once at module import. K (prompt_top_k_percepts) and the
# F6 entropy factor are both Tier-2 seeds living in perception_constants.json.
_CONSTS_PATH = Path(__file__).resolve().parent.parent / "data" / "perception_constants.json"
try:
    with _CONSTS_PATH.open() as _f:
        _CONSTS = json.load(_f)
    _TOP_K_PERCEPTS = int(_CONSTS.get("capacity", {}).get("prompt_top_k_percepts", 8))
    _H_FACTOR = float(_CONSTS.get("h_min_attention_entropy_factor", 0.6))
except Exception:
    _TOP_K_PERCEPTS = 8
    _H_FACTOR = 0.6


class NPCState:
    """Server-side state for one NPC's thought loop."""

    def __init__(self, npc_name: str, role: str, persona: dict):
        self.npc_name = npc_name
        self.role = role
        self.persona = persona

        # --- Thought loop state ---
        self.active_intentions: list[dict] = []
        # Each: {goal, location, priority, reason, created_at, expires_at}

        self.beliefs: list[dict] = []
        # Each: {subject, predicate, object, confidence, source, timestamp}
        self.MAX_BELIEFS = 30

        self.thought_history: deque[dict] = deque(maxlen=20)
        # Each: {text, emotion_response, timestamp}

        self.current_thought: str = ""

        # --- Emotion state (authoritative, pushed to client) ---
        self.emotion_vector: list[float] = [0.1] * 27

        # --- Client snapshot (received periodically) ---
        self.last_snapshot: dict = {}
        self.last_snapshot_time: float = 0.0

        # --- Appraisal handshake (Phase 0 cortical feedback) ---
        # Most recent {appraisal_id: activation} from snapshot.appraisal.active.
        # Cortical feedback drifts each of these toward the generated thought.
        self.last_active_appraisals: dict[str, float] = {}

        # --- Reward events (Phase 1) ---
        # Most recent batch of reward events from the GDScript Hebbian network,
        # surfaced via snapshot.reward_events. Each: {tag, magnitude, tick}.
        self.last_reward_events: list[dict] = []

        # --- Visible entity map (Phase 5) ---
        # Snapshot-derived {entity_id -> display_name} for the currently-visible
        # entities. The thought cycle hands this to the IdentityAppraisalTracker
        # so it can run the F2 filter (needs both eid and name) without having
        # to re-parse the raw snapshot. NPCs + player + named objects are all
        # eligible — identity-appraisal should not care about type.
        self.visible_eid_to_name: dict[str, str] = {}

        # --- Perception salience (Phase 6) ---
        # {entity_id: summed outgoing propagation weight of sense_visible_{eid}}.
        # The Hebbian graph's own weights — no authored salience function. Used
        # by the prompt builder to select top-K percepts and by the F6
        # attention-entropy monitor.
        self.perception_salience: dict[str, float] = {}

        # Rolling (timestamp, entropy) pairs for the F6 attention-entropy gate.
        # The plan specifies a 10-minute rolling mean as the gate metric;
        # older entries are pruned lazily when the mean is read. deque bound
        # is generous (capacity does NOT equal the 10-min window — the window
        # is time-based and computed on read). 1024 entries at ~2s/tick covers
        # >30min of history, more than enough for the gate.
        self.attention_entropy_window: deque = deque(maxlen=1024)

        # --- Push command queue ---
        self.pending_commands: list[dict] = []

        # --- Perception tracking for novelty detection ---
        self._prev_visible_names: set[str] = set()

        # --- Cadence control ---
        self.last_thought_time: float = 0.0
        self.min_thought_interval: float = 2.0   # seconds
        self.max_thought_interval: float = 8.0   # seconds

        # --- Seed intentions from persona schedule ---
        self._seed_schedule_intentions()

    def _seed_schedule_intentions(self):
        """Convert persona schedule entries into low-priority background intentions."""
        schedule = self.persona.get("schedule", [])
        for i, chunk in enumerate(schedule):
            if not isinstance(chunk, dict):
                continue
            self.active_intentions.append({
                "goal": chunk.get("purpose", "idle"),
                "location": chunk.get("location", "town_square"),
                "priority": chunk.get("priority", 0.5) * 0.5,  # halved — these are defaults
                "reason": "daily routine",
                "object_id": chunk.get("object_id", ""),
                "object_action": chunk.get("object_action", ""),
                "created_at": time.time(),
                "expires_at": None,  # routine intentions don't expire
                "is_routine": True,
                "schedule_index": i,
            })

    # --- Snapshot handling ---

    def receive_snapshot(self, snapshot: dict):
        """Update from client state report."""
        # Track who was visible before this update
        visible = snapshot.get("visible", [])
        self._prev_visible_names = {
            v.get("name", "") for v in self.last_snapshot.get("visible", [])
            if v.get("type") != "object"
        }
        self.last_snapshot = snapshot
        self.last_snapshot_time = time.time()

        # Cache active appraisals for the cortical-feedback drift step.
        appraisal = snapshot.get("appraisal") or {}
        self.last_active_appraisals = {
            str(k): float(v) for k, v in (appraisal.get("active") or {}).items()
        }
        # Phase 1: drain reward events surfaced by the snapshot. The trace
        # logger will pick these up on the next thought cycle.
        self.last_reward_events = list(snapshot.get("reward_events") or [])

        # Phase 5: rebuild the eid→name map for anything currently visible.
        # Both `visible` (NPCs/player) and `visible_objects` carry id+name, so
        # identity-appraisal can accumulate on either. Empty-eid entries
        # (legacy unnamed objects) are skipped.
        eid_map: dict[str, str] = {}
        for v in snapshot.get("visible", []) or []:
            eid = str(v.get("id", ""))
            name = str(v.get("name", ""))
            if eid and name:
                eid_map[eid] = name
        for v in snapshot.get("visible_objects", []) or []:
            eid = str(v.get("id", ""))
            name = str(v.get("name", ""))
            if eid and name:
                eid_map[eid] = name
        self.visible_eid_to_name = eid_map

        # Phase 6: cache the per-entity propagation-weight salience map the
        # client produced this tick.
        raw_sal = snapshot.get("perception_salience") or {}
        self.perception_salience = {str(k): float(v) for k, v in raw_sal.items()}

    def has_fresh_snapshot(self, max_age: float = 5.0) -> bool:
        return (time.time() - self.last_snapshot_time) < max_age

    # --- Cadence ---

    def should_think(self) -> bool:
        """Check if the salience neuron warrants a thought cycle.

        The salience neuron fires when network state shifts enough to need
        executive attention. The being learns what's salient through Hebbian
        co-activation. A minimum cooldown prevents thrashing.
        """
        elapsed = time.time() - self.last_thought_time
        if elapsed < self.min_thought_interval:
            return False  # hard floor — never think faster than 2s

        # Read salience from last snapshot
        drives = self.last_snapshot.get("drives", {}) if self.last_snapshot else {}
        salience = drives.get("salience", 0.0)

        # Salience neuron above threshold triggers thought
        if salience > 40.0:
            return True

        # Fallback: if salience neuron hasn't learned yet (stays near 0),
        # use a slow background cadence so the being isn't catatonic.
        # This cadence lengthens as the being ages — early on, think more
        # to build connections. Later, rely on salience.
        if elapsed >= self.max_thought_interval:
            return True

        return False

    def compute_urgency(self) -> float:
        """0.0 (calm) to 1.0 (urgent) based on current state."""
        if not self.last_snapshot:
            return 0.3  # moderate default

        drives = self.last_snapshot.get("drives", {})
        urgency = 0.0

        # Drive extremes increase urgency
        energy = drives.get("energy", 80.0)
        hunger = drives.get("hunger", 20.0)
        safety = drives.get("safety", 80.0)
        frustration = drives.get("frustration", 0.0)

        if energy < 25:
            urgency += 0.3
        if hunger > 75:
            urgency += 0.2
        if safety < 35:
            urgency += 0.4
        if frustration > 0.5:
            urgency += 0.3

        # Visible entities increase urgency — especially new ones
        visible = self.last_snapshot.get("visible", [])
        if visible:
            urgency += 0.1
            # Check for entities not seen in previous snapshot
            prev_visible = self._prev_visible_names
            current_names = {v.get("name", "") for v in visible if v.get("type") != "object"}
            new_entities = current_names - prev_visible
            if new_entities:
                urgency += 0.3  # someone new appeared — think about it fast

        # Recent events increase urgency
        events = self.last_snapshot.get("recent_events", [])
        if events:
            urgency += min(len(events) * 0.05, 0.2)

        # Vagal state modulates urgency
        vagal = self.last_snapshot.get("vagal_state", {})
        if vagal:
            dorsal = vagal.get("dorsal", 5.0)
            sympathetic = vagal.get("sympathetic", 20.0)
            ventral = vagal.get("ventral", 60.0)
            # Dorsal dominant: cortex going offline — think slowly
            if dorsal > sympathetic and dorsal > ventral and dorsal > 40.0:
                urgency *= 0.3
            # Sympathetic dominant: mobilized — think fast
            elif sympathetic > ventral and sympathetic > 40.0:
                urgency = min(urgency * 1.5, 1.0)

        return min(urgency, 1.0)

    def _current_interval(self) -> float:
        """Map urgency to thought interval (inverse: high urgency = short interval)."""
        u = self.compute_urgency()
        return self.max_thought_interval - u * (self.max_thought_interval - self.min_thought_interval)

    # --- Intentions ---

    def add_intention(self, goal: str, location: str, priority: float,
                      reason: str, expires_in: float | None = 600.0,
                      object_id: str = "", object_action: str = ""):
        """Add or update an intention. Higher priority replaces lower for same goal.
        Non-routine "go to" intentions replace each other — the being can only
        walk to one place at a time."""
        now = time.time()
        expires_at = now + expires_in if expires_in else None

        is_goto = goal.startswith("go to ")

        # Check for existing intention with same goal
        for i, existing in enumerate(self.active_intentions):
            if existing["goal"] == goal:
                if priority > existing["priority"]:
                    self.active_intentions[i] = {
                        "goal": goal, "location": location, "priority": priority,
                        "reason": reason, "object_id": object_id,
                        "object_action": object_action,
                        "created_at": now, "expires_at": expires_at,
                        "is_routine": False,
                    }
                return

        # A new "go to" replaces any existing non-routine "go to"
        if is_goto:
            self.active_intentions = [
                i for i in self.active_intentions
                if i.get("is_routine", False) or not i["goal"].startswith("go to ")
            ]

        self.active_intentions.append({
            "goal": goal, "location": location, "priority": priority,
            "reason": reason, "object_id": object_id,
            "object_action": object_action,
            "created_at": now, "expires_at": expires_at,
            "is_routine": False,
        })

    def remove_intention(self, goal: str):
        self.active_intentions = [i for i in self.active_intentions if i["goal"] != goal]

    def get_top_intention(self) -> dict | None:
        """Return highest priority non-expired intention."""
        self._expire_intentions()
        if not self.active_intentions:
            return None
        return max(self.active_intentions, key=lambda i: i["priority"])

    def _expire_intentions(self):
        now = time.time()
        self.active_intentions = [
            i for i in self.active_intentions
            if i.get("expires_at") is None or i["expires_at"] > now
        ]

    def get_intentions_summary(self, max_count: int = 3) -> str:
        self._expire_intentions()
        sorted_intentions = sorted(self.active_intentions, key=lambda i: -i["priority"])
        parts = []
        for i in sorted_intentions[:max_count]:
            if i.get("is_routine"):
                parts.append(f"{i['goal']} at {i['location']} (routine)")
            else:
                parts.append(f"{i['goal']} at {i['location']} (priority {i['priority']:.1f})")
        return "; ".join(parts) if parts else "nothing in particular"

    # --- Beliefs ---

    def add_belief(self, subject: str, predicate: str, obj: str,
                   confidence: float, source: str):
        """Add or update a belief. Contradictions resolved by confidence."""
        now = time.time()
        for i, b in enumerate(self.beliefs):
            if b["subject"] == subject and b["predicate"] == predicate:
                if b["object"] != obj:
                    # Contradicting — update if higher confidence
                    if confidence > b["confidence"]:
                        self.beliefs[i] = {
                            "subject": subject, "predicate": predicate,
                            "object": obj, "confidence": confidence,
                            "source": source, "timestamp": now,
                        }
                    return
                else:
                    # Reinforcing — boost confidence
                    self.beliefs[i]["confidence"] = min(b["confidence"] + confidence * 0.2, 1.0)
                    return

        self.beliefs.append({
            "subject": subject, "predicate": predicate, "object": obj,
            "confidence": confidence, "source": source, "timestamp": now,
        })

        # Evict lowest confidence if over cap
        if len(self.beliefs) > self.MAX_BELIEFS:
            min_idx = min(range(len(self.beliefs)), key=lambda i: self.beliefs[i]["confidence"])
            self.beliefs.pop(min_idx)

    def get_beliefs_summary(self, max_count: int = 5) -> str:
        sorted_beliefs = sorted(self.beliefs, key=lambda b: -b["confidence"])
        parts = []
        for b in sorted_beliefs[:max_count]:
            parts.append(f"{b['subject']} {b['predicate']} {b['object']} ({b['confidence']:.0%})")
        return "; ".join(parts) if parts else "none"

    # --- Thoughts ---

    def record_thought(self, text: str, emotion_response: dict | None = None):
        self.current_thought = text
        self.thought_history.append({
            "text": text,
            "emotion_response": emotion_response or {},
            "timestamp": time.time(),
        })

    def get_recent_thoughts(self, count: int = 5) -> list[str]:
        return [t["text"] for t in list(self.thought_history)[-count:]]

    # --- F6 attention entropy ---

    def record_entropy(self, entropy: float) -> None:
        """Append a (now, entropy) sample. Older samples expire on read."""
        self.attention_entropy_window.append((time.time(), float(entropy)))

    def rolling_entropy_mean(self, window_seconds: float = 600.0) -> float:
        """Mean entropy over the last `window_seconds` of samples. Returns 0.0
        when the window is empty. Does not mutate the deque; caller can prune
        if desired."""
        if not self.attention_entropy_window:
            return 0.0
        cutoff = time.time() - window_seconds
        recent = [h for (ts, h) in self.attention_entropy_window if ts >= cutoff]
        if not recent:
            return 0.0
        return sum(recent) / len(recent)

    # --- Push commands ---

    def queue_command(self, cmd: dict):
        self.pending_commands.append(cmd)

    def flush_commands(self) -> list[dict]:
        cmds = self.pending_commands
        self.pending_commands = []
        return cmds

    # --- Context assembly for thought generation ---

    def build_thought_context(self) -> dict:
        """Assemble everything the thought generator needs.

        Phase 6: `visible` and `visible_objects` are pre-ranked here into the
        top-K by propagation weight (K from `capacity.prompt_top_k_percepts`).
        Downstream prompt builders should NOT re-cap these lists — the ranking
        IS the selection. The raw un-ranked lists are available as
        `visible_raw` / `visible_objects_raw` for code paths that need them
        (trace logging keeps its own cap for disk footprint, a different
        concern).
        """
        snap = self.last_snapshot
        drives = snap.get("drives", {})

        raw_visible = snap.get("visible", []) or []
        raw_objects = snap.get("visible_objects", []) or []
        raw_heard = snap.get("heard", []) or []

        ranking = rank_percepts(
            raw_visible, raw_objects,
            self.perception_salience,
            top_k=_TOP_K_PERCEPTS,
            heard=raw_heard,
        )

        return {
            "npc_name": self.npc_name,
            "role": self.role,
            "persona": self.persona,
            "hour": snap.get("hour", 6.0),
            "location": snap.get("location", "unknown"),
            "position": snap.get("position", [0, 0]),
            "drives": {
                "energy": drives.get("energy", 80.0),
                "hunger": drives.get("hunger", 20.0),
                "social_need": drives.get("social_need", 30.0),
                "safety": drives.get("safety", 80.0),
                "frustration": drives.get("frustration", 0.0),
                "task_momentum": drives.get("task_momentum", 0.0),
            },
            "emotion_vector": snap.get("emotion_vector", self.emotion_vector),
            # Phase 6: ranked top-K by propagation weight.
            # Phase 9: heard enters the unified rank alongside visible/objects.
            "visible": ranking.visible,
            "visible_objects": ranking.visible_objects,
            "heard": ranking.heard,
            "visible_raw": raw_visible,
            "visible_objects_raw": raw_objects,
            "heard_raw": raw_heard,
            "perception_top_k_weights": ranking.weights,
            "perception_fallback": ranking.fallback,
            "perception_total_considered": ranking.total_considered,
            "recent_events": snap.get("recent_events", []),
            "current_action": snap.get("current_action", "idle"),
            "intentions_summary": self.get_intentions_summary(),
            "beliefs_summary": self.get_beliefs_summary(),
            "recent_thoughts": self.get_recent_thoughts(3),
            "somatic_tags": snap.get("somatic_tags", []),
            "vagal_state": snap.get("vagal_state", {}),
            "carried_items": snap.get("carried_items", []),
            "available_items": snap.get("available_items", []),
            "known_locations": snap.get("known_locations", []),
            "glimpsed_buildings": snap.get("glimpsed_buildings", []),
            # Phase 0/1/3 substrate channels — passed through to trace v2.
            "appraisal": snap.get("appraisal", {}),
            "per_entity_channels": snap.get("per_entity_channels", {}),
            "perception_salience": dict(self.perception_salience),
            # Phase 7 — compound-neuron state (for grammar gating + F4).
            "compounds": snap.get("compounds", {"active": {}, "count": 0}),
            # Phase 9 — cross-modal state (heard activations + bind_* neurons).
            "cross_modal": snap.get("cross_modal", {"heard": {}, "bind_active": {}}),
            # Phase 10 — temporal-texture state (lingering/approaching compounds).
            "temporal": snap.get("temporal", {"active": {}, "new_neurons": []}),
            # identity_appraisal_decoded is populated by thought_loop right
            # before prompt render; we leave it out of the default context so
            # callers that don't compute it don't emit empty inline tokens.
        }
