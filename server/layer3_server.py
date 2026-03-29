"""
Layer 3 Inference Server — High-order reasoning

Runs SmolLM2-1.7B-Instruct on localhost:8421.
Low-frequency, high-quality calls for executive planning, dialogue,
chat, NPC-to-NPC conversation, and memory reflection.
"""

import sys
import os
import time
import asyncio
from concurrent.futures import ThreadPoolExecutor
import torch
from fastapi import FastAPI
from pydantic import BaseModel
import uvicorn

_executor = ThreadPoolExecutor(max_workers=2)
sys.path.insert(0, os.path.dirname(__file__))

from layer3_model import Layer3Model

app = FastAPI(title="Burg Layer 3 Server", version="1.0")
model: Layer3Model | None = None
startup_time: float = 0


# --- Request/Response Models ---

class PlanRequest(BaseModel):
    role: str
    memory_summary: str = ""
    current_context: str = ""
    emotion_summary: str = ""

class PlanResponse(BaseModel):
    agenda: list[dict]
    source: str

class ReflectRequest(BaseModel):
    memory_events: list[str] = []

class ReflectResponse(BaseModel):
    reflections: list[str]
    concerns: list[str]

class DialogueRequest(BaseModel):
    role: str
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
    speaker_emotion: str = ""
    listener_role: str
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
    result = await _run(model.plan, req.role, req.memory_summary, req.current_context, req.emotion_summary)
    return PlanResponse(**result)

@app.post("/layer3/reflect", response_model=ReflectResponse)
async def reflect(req: ReflectRequest):
    result = await _run(model.reflect, req.memory_events)
    return ReflectResponse(**result)

@app.post("/layer3/dialogue", response_model=DialogueResponse)
async def dialogue(req: DialogueRequest):
    result = await _run(model.dialogue, req.role, req.emotion_summary,
                         req.relationship_context, req.recent_events)
    return DialogueResponse(**result)

@app.post("/layer3/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    def _do():
        return model.chat(req.role, req.npc_name, req.emotion_summary,
                           req.relationship_context, req.recent_events,
                           req.conversation_history, req.player_message)
    result = await _run(_do)
    return ChatResponse(**result)

@app.post("/layer3/converse", response_model=ConverseResponse)
async def converse(req: ConverseRequest):
    def _do():
        return model.converse(req.speaker_role, req.speaker_emotion,
                               req.listener_role, req.listener_emotion,
                               req.shared_context, req.speaker_recent)
    result = await _run(_do)
    return ConverseResponse(**result)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8421, log_level="info")
