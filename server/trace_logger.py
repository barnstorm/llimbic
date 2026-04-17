"""
Trace logger — structured JSONL recording of every cognitive event.

One file per server session: /tmp/burg_trace_{timestamp}.jsonl
Each line is a complete JSON object capturing the full causal context
of a thought cycle or speech event. Designed to be transformed into
training data for embodied cognitive models.

Two event types:
  - "thought": internal thought cycle (body state → perception → thought → command)
  - "speech": any spoken output (dialogue, chat, converse, SAY command)
"""

import json
import time
import logging
import os

log = logging.getLogger("layer3")

_trace_file = None
_trace_path = None


def _ensure_open():
    global _trace_file, _trace_path
    if _trace_file is not None:
        return
    ts = int(time.time())
    _trace_path = f"/tmp/burg_trace_{ts}.jsonl"
    _trace_file = open(_trace_path, "a")
    log.info(f"Trace logger: writing to {_trace_path}")


def _write(record: dict):
    _ensure_open()
    _trace_file.write(json.dumps(record, default=str) + "\n")
    _trace_file.flush()


def trace_thought(npc_name: str, context: dict, thought_result: dict,
                  elapsed_ms: float):
    """Record a complete thought cycle."""
    snap = context
    _write({
        "ts": time.time(),
        "type": "thought",
        "npc": npc_name,
        "role": snap.get("role", ""),
        "location": snap.get("location", ""),
        "doing": snap.get("current_action", "idle"),
        "hour": snap.get("hour", 0.0),
        # Body state
        "somatic_tags": snap.get("somatic_tags", []),
        "drives": snap.get("drives", {}),
        "vagal_state": snap.get("vagal_state", {}),
        "salience": snap.get("drives", {}).get("salience", 0.0),
        # Inventory
        "carrying": snap.get("carried_items", []),
        "available_here": snap.get("available_items", []),
        # Perception
        "visible": [
            {"name": v.get("name"), "distance": v.get("distance"),
             "direction": v.get("direction")}
            for v in snap.get("visible", [])[:6]
        ],
        "heard": snap.get("heard", [])[:3],
        "visible_objects": [
            v.get("name") for v in snap.get("visible_objects", [])[:6]
        ],
        # Memory context
        "recent_events": snap.get("recent_events", [])[:3],
        "intentions": snap.get("intentions_summary", ""),
        "beliefs": snap.get("beliefs_summary", ""),
        "recent_thoughts": snap.get("recent_thoughts", [])[-2:],
        # Body narrative (from L2)
        "body_narrative": snap.get("body_narrative", ""),
        # Model output
        "thought": thought_result.get("thoughts", [""])[0][:300] if thought_result.get("thoughts") else "",
        "command": thought_result.get("command", ""),
        "command_target": thought_result.get("target"),
        "action_biases": thought_result.get("action_biases", {}),
        "trigger_actions": [
            {"type": t.get("type"), "item": t.get("item", ""), "target": t.get("target", "")}
            for t in thought_result.get("trigger_actions", [])
        ],
        "raw": thought_result.get("raw", "")[:500],
        # Performance
        "inference_ms": round(elapsed_ms),
    })


def trace_speech(npc_name: str, mode: str, params: dict, result: dict,
                 elapsed_ms: float):
    """Record a speech event (dialogue, chat, converse, SAY)."""
    record = {
        "ts": time.time(),
        "type": "speech",
        "npc": npc_name,
        "mode": mode,
        # Body state (from params/packet)
        "somatic_tags": params.get("somatic_tags", []),
        "location": params.get("current_location", params.get("location", "")),
        "carrying": params.get("carried_items", []),
        # Output
        "utterance": result.get("utterance", ""),
        "intent": result.get("intent", ""),
        "inner_thought": result.get("inner_thought", ""),
        # Performance
        "inference_ms": round(elapsed_ms),
    }

    # Mode-specific context
    if mode in ("chat", "chat_v2"):
        record["player_message"] = params.get("player_message", "")
        record["conversation_history"] = params.get("conversation_history", [])[-4:]
        record["perception"] = params.get("perception", "")[:200]
        record["current_thought"] = params.get("current_thought", "")
    elif mode in ("converse", "converse_v2"):
        speaker = params.get("speaker", params)
        listener = params.get("listener", {})
        record["speaker"] = speaker.get("npc_name", npc_name)
        record["listener"] = listener.get("npc_name", "")
        record["listener_somatic"] = listener.get("somatic_tags", [])
    elif mode == "say":
        record["target"] = params.get("target", "")
        record["text"] = params.get("text", "")

    _write(record)


def get_trace_path() -> str:
    """Return current trace file path (for status display)."""
    _ensure_open()
    return _trace_path
