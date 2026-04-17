"""
Layer 3 Inference Server — High-order reasoning

Runs SmolLM2-1.7B-Instruct on localhost:8421.
Low-frequency, high-quality calls for executive planning, dialogue,
chat, NPC-to-NPC conversation, and memory reflection.
"""

import sys
import os
import time
import json
import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
import uvicorn

logging.basicConfig(level=logging.INFO, format="%(asctime)s [L3] %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("layer3")
_fh = logging.FileHandler("/tmp/burg_l3.log", mode="w")
_fh.setFormatter(logging.Formatter("%(asctime)s [L3] %(message)s", datefmt="%H:%M:%S"))
log.addHandler(_fh)

_executor = ThreadPoolExecutor(max_workers=4)
sys.path.insert(0, os.path.dirname(__file__))

from layer3_model import Layer3Model
from command_model import CommandModel
from thought_loop import ThoughtLoop
from trace_logger import trace_speech

app = FastAPI(title="Burg Layer 3 Server", version="1.0")
model: Layer3Model | None = None
thought_loop: ThoughtLoop | None = None
startup_time: float = 0


# --- Request/Response Models ---

class PlanRequest(BaseModel):
    role: str
    npc_name: str = ""
    memory_summary: str = ""
    current_context: str = ""
    somatic_tags: list[str] = []

class PlanResponse(BaseModel):
    agenda: list[dict]
    source: str

class ReflectRequest(BaseModel):
    npc_name: str = ""
    role: str = ""
    memory_events: list[str] = []

class ReflectResponse(BaseModel):
    reflections: list[str]
    concerns: list[str]

class DialogueRequest(BaseModel):
    role: str
    npc_name: str = ""
    somatic_tags: list[str] = []
    relationship_context: str = ""
    recent_events: list[str] = []

class DialogueResponse(BaseModel):
    intent: str
    utterance: str

class ChatRequest(BaseModel):
    role: str
    npc_name: str
    somatic_tags: list[str] = []
    relationship_context: str = ""
    recent_events: list[str] = []
    conversation_history: list[dict] = []
    player_message: str

class ChatResponse(BaseModel):
    utterance: str
    mood_shift: str

class PlanPacketRequest(BaseModel):
    npc_name: str
    role: str
    hour: float = 0.0
    current_location: str = ""
    current_chunk: dict = {}
    replan_reason: str = "none"
    somatic_tags: list[str] = []
    concerns: list[str] = []
    problem_objects: list[dict] = []
    recent_failures: list[dict] = []
    salient_events: list[dict] = []

class ConverseRequest(BaseModel):
    speaker_role: str
    speaker_name: str = ""
    speaker_somatic: list[str] = []
    listener_role: str
    listener_name: str = ""
    listener_somatic: list[str] = []
    shared_context: str = ""
    speaker_recent: list[str] = []

class ConverseResponse(BaseModel):
    intent: str
    utterance: str
    topic: str

class HealthResponse(BaseModel):
    status: str
    model: str
    gpu_memory_used_mb: float
    uptime_seconds: float


# --- Startup ---

@app.on_event("startup")
async def load_model():
    global model, thought_loop, startup_time
    startup_time = time.time()

    # Command model: SmolLM3-3B fine-tuned for adventure-command thought loop (port 8423)
    cmd_model = None
    try:
        cmd_model = CommandModel()
        print("Layer 3 server: CommandModel (SmolLM3-3B) loaded for thought loop")
    except FileNotFoundError as e:
        print(f"Layer 3 server: CommandModel not available ({e}), using legacy thought generation")

    # Chat model: SmolLM3-3B base for chat/plan/dialogue/converse/reflect (port 8424)
    model = Layer3Model(command_model=cmd_model)

    # Try to load L2 model for thought loop (limbic coloring of thoughts)
    l2_model = None
    try:
        from layer2_model import Layer2Model
        l2_model = Layer2Model()
        print("Layer 3 server: L2 limbic model loaded for thought loop")
    except Exception as e:
        print(f"Layer 3 server: L2 model not available for thought loop ({e}), "
              f"thought coloring will be skipped")

    thought_loop = ThoughtLoop(l2_model=l2_model, l3_model=model)
    print("Layer 3 server ready (thought loop initialized).")


async def _run(fn, *args):
    return await asyncio.get_event_loop().run_in_executor(_executor, fn, *args)


# --- Endpoints ---

@app.get("/health", response_model=HealthResponse)
async def health():
    try:
        import torch
        gpu_mem = torch.cuda.memory_allocated() / 1e6 if torch.cuda.is_available() else 0
    except ImportError:
        gpu_mem = 0
    return HealthResponse(
        status="ok" if model else "loading",
        model=model.model_name if model else "not loaded",
        gpu_memory_used_mb=gpu_mem,
        uptime_seconds=time.time() - startup_time,
    )

@app.post("/layer3/plan", response_model=PlanResponse)
async def plan(req: PlanRequest):
    tags_preview = ", ".join(req.somatic_tags[:3]) if req.somatic_tags else "(none)"
    log.info(f"PLAN [{req.role}] context='{req.current_context[:60]}' feel='{tags_preview}'")
    t0 = time.time()
    result = await _run(model.plan, req.role, req.memory_summary, req.current_context, req.somatic_tags, req.npc_name)
    log.info(f"PLAN [{req.role}] -> {len(result.get('agenda',[]))} chunks ({result.get('source','?')}) [{time.time()-t0:.1f}s]")
    return PlanResponse(**result)

@app.post("/layer3/reflect", response_model=ReflectResponse)
async def reflect(req: ReflectRequest):
    log.info(f"REFLECT {len(req.memory_events)} events")
    t0 = time.time()
    result = await _run(model.reflect, req.memory_events, req.npc_name, req.role)
    log.info(f"REFLECT -> {len(result.get('reflections',[]))} reflections [{time.time()-t0:.1f}s]")
    return ReflectResponse(**result)

@app.post("/layer3/dialogue", response_model=DialogueResponse)
async def dialogue(req: DialogueRequest):
    tags_preview = ", ".join(req.somatic_tags[:3]) if req.somatic_tags else "(none)"
    log.info(f"DIALOGUE [{req.role}] feel='{tags_preview}'")
    t0 = time.time()
    result = await _run(model.dialogue, req.role, req.somatic_tags,
                         req.relationship_context, req.recent_events, req.npc_name)
    log.info(f"DIALOGUE [{req.role}] -> intent={result.get('intent','')} \"{result.get('utterance','')}\" [{time.time()-t0:.1f}s]")
    return DialogueResponse(**result)

@app.post("/layer3/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    log.info(f"CHAT [{req.npc_name}] player says: \"{req.player_message}\"")
    t0 = time.time()
    def _do():
        return model.chat(req.role, req.npc_name, req.somatic_tags,
                           req.relationship_context, req.recent_events,
                           req.conversation_history, req.player_message)
    result = await _run(_do)
    log.info(f"CHAT [{req.npc_name}] -> \"{result.get('utterance','')}\" mood={result.get('mood_shift','')} [{time.time()-t0:.1f}s]")
    return ChatResponse(**result)

@app.post("/layer3/converse", response_model=ConverseResponse)
async def converse(req: ConverseRequest):
    log.info(f"CONVERSE [{req.speaker_role}] -> [{req.listener_role}]")
    t0 = time.time()
    def _do():
        return model.converse(req.speaker_role, req.speaker_somatic,
                               req.listener_role, req.listener_somatic,
                               req.shared_context, req.speaker_recent,
                               req.speaker_name, req.listener_name)
    result = await _run(_do)
    log.info(f"CONVERSE [{req.speaker_role}] -> \"{result.get('utterance','')}\" topic={result.get('topic','')} [{time.time()-t0:.1f}s]")
    return ConverseResponse(**result)


# --- WebSocket endpoint ---
# Single persistent connection multiplexes all L3 requests.
# Client sends: {"id": "req_1", "method": "plan", "params": {...}}
# Server sends: {"id": "req_1", "result": {...}}

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    print("WebSocket client connected")

    # Don't set thought loop WS here — wait until client identifies itself
    # by sending a register_npc or state_update message (prevents debug
    # queries from stealing the push channel).
    is_game_client = False

    state = {"open": True}
    pending_tasks: set = set()

    async def safe_send(text: str):
        """Send text on websocket, silently drop if closed."""
        if not state["open"]:
            return
        try:
            await ws.send_text(text)
        except Exception:
            state["open"] = False

    async def handle(req_id: str, method: str, params: dict):
        t0 = time.time()
        try:
            result = await _dispatch(method, params)
            elapsed = time.time() - t0
            # Log based on method — always include utterances
            npc = params.get("npc_name", params.get("speaker", {}).get("npc_name", ""))
            utt = result.get("utterance", "")
            if method == "chat":
                log.info(f"WS CHAT [{npc}] player: \"{params.get('player_message','')}\" -> \"{utt}\" [{elapsed:.1f}s]")
                trace_speech(npc, "chat", params, result, elapsed * 1000)
            elif method == "chat_v2":
                log.info(f"WS CHAT_V2 [{npc}] player: \"{params.get('player_message','')}\" -> \"{utt}\" [{elapsed:.1f}s]")
                trace_speech(npc, "chat_v2", params, result, elapsed * 1000)
            elif method == "dialogue_v2":
                log.info(f"WS DIALOGUE_V2 [{npc}] intent={result.get('intent','')} \"{utt}\" [{elapsed:.1f}s]")
                trace_speech(npc, "dialogue_v2", params, result, elapsed * 1000)
            elif method == "converse_v2":
                speaker_name = params.get("speaker", {}).get("npc_name", "")
                listener_name = params.get("listener", {}).get("npc_name", "")
                log.info(f"WS CONVERSE_V2 [{speaker_name}->{listener_name}] \"{utt}\" topic={result.get('topic','')} [{elapsed:.1f}s]")
                trace_speech(speaker_name, "converse_v2", params, result, elapsed * 1000)
            elif method == "plan":
                log.info(f"WS PLAN [{params.get('role','')}] -> {len(result.get('agenda',[]))} chunks ({result.get('source','?')}) [{elapsed:.1f}s]")
            elif method == "plan_v2":
                log.info(f"WS PLAN_V2 [{npc}] reason={params.get('replan_reason','')} -> {len(result.get('agenda',[]))} chunks ({result.get('source','?')}) [{elapsed:.1f}s]")
            elif method == "dialogue":
                log.info(f"WS DIALOGUE [{params.get('role','')}] -> \"{utt}\" [{elapsed:.1f}s]")
                trace_speech(npc, "dialogue", params, result, elapsed * 1000)
            elif method == "converse":
                log.info(f"WS CONVERSE [{params.get('speaker_role','')}] -> \"{utt}\" [{elapsed:.1f}s]")
                trace_speech(params.get("speaker_name", ""), "converse", params, result, elapsed * 1000)
            elif method == "reflect_v2":
                refs = result.get("reflections", [])
                log.info(f"WS REFLECT_V2 [{npc}] {len(refs)} reflections, concerns={result.get('concerns',[])} [{elapsed:.1f}s]")
            elif method == "state_update":
                pass  # too noisy
            else:
                log.info(f"WS {method.upper()} [{elapsed:.1f}s]")
            await safe_send(json.dumps({"id": req_id, "result": result}))
        except asyncio.CancelledError:
            pass
        except Exception as e:
            log.error(f"WS {method} error: {e}")
            await safe_send(json.dumps({"id": req_id, "error": str(e)}))

    try:
        while True:
            raw = await ws.receive_text()
            msg = json.loads(raw)
            req_id = msg.get("id", "?")
            method = msg.get("method", "")
            params = msg.get("params", {})
            log.info(f"WS <- {method} ({req_id})")

            # Identify game client by its first game-specific message
            if not is_game_client and method in ("register_npc", "state_update"):
                is_game_client = True
                if thought_loop is not None:
                    thought_loop.set_websocket(ws)
                    print("WebSocket identified as game client — push channel set")

            task = asyncio.create_task(handle(req_id, method, params))
            pending_tasks.add(task)
            task.add_done_callback(pending_tasks.discard)
    except WebSocketDisconnect:
        log.info("WebSocket client disconnected")
    except Exception as e:
        print(f"WebSocket error: {e}")
    finally:
        state["open"] = False
        for t in pending_tasks:
            t.cancel()
        pending_tasks.clear()


async def _dispatch(method: str, params: dict) -> dict:
    """Route a WebSocket request to the right model method."""
    if method == "plan":
        return await _run(model.plan, params.get("role", ""),
                           params.get("memory_summary", ""),
                           params.get("current_context", ""),
                           params.get("somatic_tags", []),
                           params.get("npc_name", ""))
    elif method == "plan_v2":
        return await _run(model.plan_from_packet, params)
    elif method == "reflect":
        return await _run(model.reflect, params.get("memory_events", []),
                           params.get("npc_name", ""), params.get("role", ""))
    elif method == "reflect_v2":
        return await _run(model.reflect_from_packet, params)
    elif method == "dialogue":
        return await _run(model.dialogue, params.get("role", ""),
                           params.get("somatic_tags", []),
                           params.get("relationship_context", ""),
                           params.get("recent_events", []),
                           params.get("npc_name", ""))
    elif method == "dialogue_v2":
        return await _run(model.dialogue_from_packet, params)
    elif method == "chat_v2":
        def _do_chat_v2():
            return model.chat_from_packet(params)
        return await _run(_do_chat_v2)
    elif method == "converse_v2":
        def _do_converse_v2():
            return model.converse_from_packet(params)
        return await _run(_do_converse_v2)
    elif method == "chat":
        def _do():
            return model.chat(params.get("role", ""), params.get("npc_name", ""),
                               params.get("somatic_tags", []),
                               params.get("relationship_context", ""),
                               params.get("recent_events", []),
                               params.get("conversation_history", []),
                               params.get("player_message", ""))
        return await _run(_do)
    elif method == "converse":
        def _do():
            return model.converse(params.get("speaker_role", ""),
                                   params.get("speaker_somatic", []),
                                   params.get("listener_role", ""),
                                   params.get("listener_somatic", []),
                                   params.get("shared_context", ""),
                                   params.get("speaker_recent", []),
                                   params.get("speaker_name", ""),
                                   params.get("listener_name", ""))
        return await _run(_do)

    # --- Thought loop methods ---
    elif method == "register_npc":
        if thought_loop is not None:
            npc_name = params.get("npc_name", "")
            persona = params.get("persona", {})
            log.info(f"[THOUGHT LOOP] Registering NPC: {npc_name}")
            await thought_loop.register_npc(npc_name, persona)
            return {"ok": True, "npc": npc_name}
        print("[THOUGHT LOOP] register_npc called but thought_loop is None!")
        return {"error": "thought loop not initialized"}

    elif method == "state_update":
        if thought_loop is not None:
            npc_name = params.get("npc_name", "")
            await thought_loop.receive_snapshot(npc_name, params)
            return {"ok": True}
        return {"ok": True}

    elif method == "extract_beliefs":
        if thought_loop is not None:
            await thought_loop.extract_conversation_beliefs(
                params.get("listener_name", ""),
                params.get("listener_role", ""),
                params.get("utterance", ""),
                params.get("speaker_name", ""),
            )
            return {"ok": True}
        return {"ok": True}

    # --- Human control methods ---

    elif method == "inject_commands":
        # Inject adventure commands into an NPC (from human controller)
        if thought_loop is not None:
            npc_name = params.get("npc_name", "")
            commands = params.get("commands", [])
            if npc_name and commands:
                await thought_loop._push_commands(npc_name, commands)
                log.info(f"HUMAN_CMD [{npc_name}] {len(commands)} commands injected")
                return {"ok": True, "npc": npc_name}
        return {"error": "no thought loop or missing params"}

    elif method == "get_npc_state":
        # Return current NPC state for human control display
        if thought_loop is not None:
            npc_name = params.get("npc_name", "")
            state = thought_loop.npc_states.get(npc_name)
            if state:
                snap = state.last_snapshot
                return {
                    "npc_name": npc_name,
                    "role": state.role,
                    "location": snap.get("location", "unknown"),
                    "current_action": snap.get("current_action", "idle"),
                    "drives": snap.get("drives", {}),
                    "emotion_vector": state.emotion_vector,
                    "visible": snap.get("visible", []),
                    "visible_objects": snap.get("visible_objects", []),
                    "heard": snap.get("heard", []),
                    "recent_events": snap.get("recent_events", []),
                    "active_intentions": [
                        {"goal": i.get("goal", ""), "location": i.get("location", ""),
                         "priority": i.get("priority", 0)}
                        for i in state.active_intentions
                    ],
                    "recent_thoughts": state.get_recent_thoughts(3),
                }
            return {"error": f"NPC not found: {npc_name}"}
        return {"error": "no thought loop"}

    elif method == "list_npcs":
        # List all registered NPCs
        if thought_loop is not None:
            return {"npcs": list(thought_loop.npc_states.keys())}
        return {"npcs": []}

    else:
        return {"error": f"unknown method: {method}"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8421, log_level="info")
