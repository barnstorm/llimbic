"""
Trace logger — structured JSONL recording of every cognitive event.

One file per server session: /tmp/burg_trace_{timestamp}.jsonl
Each line is a complete JSON object capturing the full causal context
of a thought cycle or speech event. Designed to be transformed into
training data for embodied cognitive models.

Schema version 2 (perception_implementation_plan.md Phase 0.8):
  - Records carry "trace_schema_version" so consumers can route by version.
  - Thought events include "active_appraisals" with decoded tokens for the
    cortical-feedback bridge.
  - "visible_objects" preserves state/position/distance/exposure (was lossy
    name-only in v1).

Two event types:
  - "thought": internal thought cycle (body state → perception → thought → command)
  - "speech": any spoken output (dialogue, chat, converse, SAY command)
"""

import json
import time
import logging
import os

log = logging.getLogger("layer3")

TRACE_SCHEMA_VERSION = 2

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
                  elapsed_ms: float,
                  active_appraisals: dict | None = None,
                  appraisal_decoded: dict | None = None,
                  reward_events: list[dict] | None = None,
                  new_identity_appraisals: list[dict] | None = None,
                  entity_thought_associations: list[dict] | None = None,
                  identity_appraisal_decoded: dict[str, list[str]] | None = None,
                  attention_entropy: dict | None = None,
                  prompt_rendered: str | None = None,
                  fallback_contribution: float | None = None,
                  fallback_coefficient: float | None = None,
                  compounds_state: dict | None = None,
                  verbs_via_compound: list[str] | None = None,
                  verbs_via_fallback: list[str] | None = None,
                  appraisal_drift_counts: dict[str, int] | None = None,
                  cross_modal_state: dict | None = None,
                  temporal_state: dict | None = None):
    """Record a complete thought cycle.

    active_appraisals: {neuron_id: activation} — the appraisal neurons that
        were firing when this thought was generated.
    appraisal_decoded: {neuron_id: [tokens]} — nearest-token decode of each
        active appraisal's drifted embedding.
    reward_events: list of {tag, magnitude, tick} — Phase 1 reward signals
        emitted by the engine since the last snapshot.
    new_identity_appraisals: Phase 5 — list of {neuron_id, entity_id,
        entity_name, thought_count} for identity-appraisals spawned this
        tick. Spawns happen Python-side (mean of per-entity thought deque)
        and are simultaneously pushed to GDScript for Hebbian wiring.
    entity_thought_associations: Phase 5 F2 audit — one entry per visible
        entity per tick: {eid, name, matched, method, score}. The rolling
        rejection rate over these entries must exceed
        identity_filter_min_rejection_rate or the filter is pass-through.
    identity_appraisal_decoded: {entity_id: [tokens]} — nearest-token decode
        of every currently-existing appr_identity_{eid} drifted embedding.
        This is the "decoded tokens flow into trace v2 alongside the entity"
        field from the plan.
    All emitted as structured records so trace replay is information-lossless.
    """
    snap = context
    appraisals_record = []
    if active_appraisals:
        for nid, activation in active_appraisals.items():
            appraisals_record.append({
                "id": nid,
                "activation": float(activation),
                "decoded_tokens": (appraisal_decoded or {}).get(nid, []),
            })

    appraisal_payload = snap.get("appraisal") or {}

    _write({
        "trace_schema_version": TRACE_SCHEMA_VERSION,
        "ts": time.time(),
        "type": "thought",
        "npc": npc_name,
        "role": snap.get("role", ""),
        "location": snap.get("location", ""),
        "scene": snap.get("scene", ""),
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
             "direction": v.get("direction"), "exposure": v.get("exposure")}
            for v in snap.get("visible", [])[:6]
        ],
        "heard": snap.get("heard", [])[:3],
        # v2: preserve full visible_object structure (state, position, distance,
        # exposure) instead of v1's lossy name-only serialization.
        "visible_objects": [
            {
                "id": v.get("id", ""),
                "name": v.get("name", ""),
                "state": v.get("state", ""),
                "distance": v.get("distance"),
                "position": v.get("position"),
                "exposure": v.get("exposure"),
            }
            for v in snap.get("visible_objects", [])[:6]
        ],
        # Memory context
        "recent_events": snap.get("recent_events", [])[:3],
        "intentions": snap.get("intentions_summary", ""),
        "beliefs": snap.get("beliefs_summary", ""),
        "recent_thoughts": snap.get("recent_thoughts", [])[-2:],
        # Body narrative (from L2)
        "body_narrative": snap.get("body_narrative", ""),
        # v2: appraisal layer state — what the bridge produced this cycle.
        "active_appraisals": appraisals_record,
        "new_appraisals_this_tick": appraisal_payload.get("new_neurons", []),
        # v2 Phase 5: identity-appraisal records (spawns + per-tick F2 audit
        # + eid-keyed decoded tokens).
        "new_identity_appraisals_this_tick": list(new_identity_appraisals or []),
        "entity_thought_associations_this_tick": list(entity_thought_associations or []),
        "identity_appraisal_decoded": dict(identity_appraisal_decoded or {}),
        # v2 Phase 6: attention entropy & top-K propagation-weight salience.
        # Full context (tick entropy + rolling mean + H_MIN floor + K) lets the
        # F6 CLI (tools/probe_attention_entropy.py) verify the gate from the
        # trace alone, no live run required.
        "attention_entropy": dict(attention_entropy or {}),
        "perception_salience": dict(snap.get("perception_salience") or {}),
        "perception_top_k_weights": list(snap.get("perception_top_k_weights") or []),
        # v2 Phase 7: the full rendered prompt (spec §6.5 "prompt_rendered"),
        # compound-neuron state, F4 fallback contribution, per-verb path info.
        # `prompt_rendered` is the exact string sent to the LLM this tick —
        # replay fidelity for v3 training (Phase 8) depends on it.
        "prompt_rendered": str(prompt_rendered or ""),
        "compounds_state": dict(compounds_state or {}),
        "fallback_coefficient": float(fallback_coefficient) if fallback_coefficient is not None else None,
        "fallback_contribution_per_tick": float(fallback_contribution) if fallback_contribution is not None else None,
        "verbs_via_compound": list(verbs_via_compound or []),
        "verbs_via_fallback": list(verbs_via_fallback or []),
        # v2 Phase 8 F5: per-tick appraisal drift_count snapshot so maturity
        # gating can resolve from the trace alone (no persist file needed).
        "appraisal_drift_counts": dict(appraisal_drift_counts or {}),
        # v2 Phase 9: cross-modal state. `cross_modal_state.new_bind_neurons`
        # is a per-tick drain (one-shot spawn events); bind_active and heard
        # are current activations for post-hoc diagnostics and §9.4 probes.
        "cross_modal_state": dict(cross_modal_state or {"heard": {}, "bind_active": {}, "new_bind_neurons": []}),
        # v2 Phase 10: temporal-texture state. `temporal_state.active` is
        # {eid: {kind: activation}} for lingering/approaching compounds;
        # `new_neurons` drains per-tick spawns. Feeds §9.4 temporal probes.
        "temporal_state": dict(temporal_state or {"active": {}, "new_neurons": []}),
        # v2 Phase 1: reward signals fired by the engine since last snapshot.
        "reward_events_this_tick": list(reward_events or []),
        # v2 Phase 3: continuous per-entity channels (visible level, distance
        # level, rate of change, dwell EMA) for every per-entity sensory
        # neuron currently registered.
        "per_entity_channels": dict(snap.get("per_entity_channels") or {}),
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
        "trace_schema_version": TRACE_SCHEMA_VERSION,
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
