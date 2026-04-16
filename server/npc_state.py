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

import time
from collections import deque


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

    def has_fresh_snapshot(self, max_age: float = 5.0) -> bool:
        return (time.time() - self.last_snapshot_time) < max_age

    # --- Cadence ---

    def should_think(self) -> bool:
        """Check if enough time has passed and there's reason to think."""
        elapsed = time.time() - self.last_thought_time
        interval = self._current_interval()
        return elapsed >= interval

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

        return min(urgency, 1.0)

    def _current_interval(self) -> float:
        """Map urgency to thought interval (inverse: high urgency = short interval)."""
        u = self.compute_urgency()
        return self.max_thought_interval - u * (self.max_thought_interval - self.min_thought_interval)

    # --- Intentions ---

    def add_intention(self, goal: str, location: str, priority: float,
                      reason: str, expires_in: float | None = 600.0,
                      object_id: str = "", object_action: str = ""):
        """Add or update an intention. Higher priority replaces lower for same goal."""
        now = time.time()
        expires_at = now + expires_in if expires_in else None

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

    # --- Push commands ---

    def queue_command(self, cmd: dict):
        self.pending_commands.append(cmd)

    def flush_commands(self) -> list[dict]:
        cmds = self.pending_commands
        self.pending_commands = []
        return cmds

    # --- Context assembly for thought generation ---

    def build_thought_context(self) -> dict:
        """Assemble everything the thought generator needs."""
        snap = self.last_snapshot
        drives = snap.get("drives", {})

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
            "visible": snap.get("visible", []),
            "visible_objects": snap.get("visible_objects", []),
            "heard": snap.get("heard", []),
            "recent_events": snap.get("recent_events", []),
            "current_action": snap.get("current_action", "idle"),
            "intentions_summary": self.get_intentions_summary(),
            "beliefs_summary": self.get_beliefs_summary(),
            "recent_thoughts": self.get_recent_thoughts(3),
            "somatic_tags": snap.get("somatic_tags", []),
        }
