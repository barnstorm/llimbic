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
import torch
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
import uvicorn

logging.basicConfig(level=logging.INFO, format="%(asctime)s [L3] %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("layer3")

_executor = ThreadPoolExecutor(max_workers=4)
sys.path.insert(0, os.path.dirname(__file__))

from layer3_model import Layer3Model

app = FastAPI(title="Burg Layer 3 Server", version="1.0")
model: Layer3Model | None = None
startup_time: float = 0


# --- Request/Response Models ---

class PlanRequest(BaseModel):
    role: str
    npc_name: str = ""
    memory_summary: str = ""
    current_context: str = ""
    emotion_summary: str = ""

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
    emotion_summary: str = ""
    relationship_context: str = ""
    recent_events: list[str] = []

class DialogueResponse(BaseModel):
    intent: str
    utterance: str

class ChatRequest(BaseModel):
    role: str
    npc_name: str
    emotion_summary: str = ""
    relationship_context: str = ""
    recent_events: list[str] = []
    conversation_history: list[dict] = []
    player_message: str

class ChatResponse(BaseModel):
    utterance: str
    mood_shift: str

class ConverseRequest(BaseModel):
    speaker_role: str
    speaker_name: str = ""
    speaker_emotion: str = ""
    listener_role: str
    listener_name: str = ""
    listener_emotion: str = ""
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
    global model, startup_time
    startup_time = time.time()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = Layer3Model(model_name="HuggingFaceTB/SmolLM2-1.7B-Instruct", device=device)
    print("Layer 3 server ready.")


async def _run(fn, *args):
    return await asyncio.get_event_loop().run_in_executor(_executor, fn, *args)


# --- Endpoints ---

@app.get("/health", response_model=HealthResponse)
async def health():
    gpu_mem = torch.cuda.memory_allocated() / 1e6 if torch.cuda.is_available() else 0
    return HealthResponse(
        status="ok" if model else "loading",
        model=model.model_name if model else "not loaded",
        gpu_memory_used_mb=gpu_mem,
        uptime_seconds=time.time() - startup_time,
    )

@app.post("/layer3/plan", response_model=PlanResponse)
async def plan(req: PlanRequest):
    log.info(f"PLAN [{req.role}] context='{req.current_context[:60]}' emotion='{req.emotion_summary[:40]}'")
    t0 = time.time()
    result = await _run(model.plan, req.role, req.memory_summary, req.current_context, req.emotion_summary, req.npc_name)
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
    log.info(f"DIALOGUE [{req.role}] emotion='{req.emotion_summary[:40]}'")
    t0 = time.time()
    result = await _run(model.dialogue, req.role, req.emotion_summary,
                         req.relationship_context, req.recent_events, req.npc_name)
    log.info(f"DIALOGUE [{req.role}] -> intent={result.get('intent','')} \"{result.get('utterance','')}\" [{time.time()-t0:.1f}s]")
    return DialogueResponse(**result)

@app.post("/layer3/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    log.info(f"CHAT [{req.npc_name}] player says: \"{req.player_message}\"")
    t0 = time.time()
    def _do():
        return model.chat(req.role, req.npc_name, req.emotion_summary,
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
        return model.converse(req.speaker_role, req.speaker_emotion,
                               req.listener_role, req.listener_emotion,
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
            # Log based on method
            if method == "chat":
                log.info(f"WS CHAT [{params.get('npc_name','')}] player: \"{params.get('player_message','')}\" -> \"{result.get('utterance','')}\" [{elapsed:.1f}s]")
            elif method == "plan":
                log.info(f"WS PLAN [{params.get('role','')}] -> {len(result.get('agenda',[]))} chunks ({result.get('source','?')}) [{elapsed:.1f}s]")
            elif method == "dialogue":
                log.info(f"WS DIALOGUE [{params.get('role','')}] -> \"{result.get('utterance','')}\" [{elapsed:.1f}s]")
            elif method == "converse":
                log.info(f"WS CONVERSE [{params.get('speaker_role','')}] -> \"{result.get('utterance','')}\" [{elapsed:.1f}s]")
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
                           params.get("emotion_summary", ""),
                           params.get("npc_name", ""))
    elif method == "reflect":
        return await _run(model.reflect, params.get("memory_events", []),
                           params.get("npc_name", ""), params.get("role", ""))
    elif method == "dialogue":
        return await _run(model.dialogue, params.get("role", ""),
                           params.get("emotion_summary", ""),
                           params.get("relationship_context", ""),
                           params.get("recent_events", []),
                           params.get("npc_name", ""))
    elif method == "chat":
        def _do():
            return model.chat(params.get("role", ""), params.get("npc_name", ""),
                               params.get("emotion_summary", ""),
                               params.get("relationship_context", ""),
                               params.get("recent_events", []),
                               params.get("conversation_history", []),
                               params.get("player_message", ""))
        return await _run(_do)
    elif method == "converse":
        def _do():
            return model.converse(params.get("speaker_role", ""),
                                   params.get("speaker_emotion", ""),
                                   params.get("listener_role", ""),
                                   params.get("listener_emotion", ""),
                                   params.get("shared_context", ""),
                                   params.get("speaker_recent", []),
                                   params.get("speaker_name", ""),
                                   params.get("listener_name", ""))
        return await _run(_do)
    else:
        return {"error": f"unknown method: {method}"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8421, log_level="info")
