"""
Burg Inference Server

FastAPI server running two local models for NPC AI:
- Layer 2: SmolLM2-135M-Instruct (used in constrained mode for projection/modulation)
- Layer 3: SmolLM2-135M-Instruct (used for planning/reflection/dialogue)

Both layers share the same model instance since we use the same model
(SmolLM2-135M is the smallest instruct model that can produce structured JSON).
Layer 2 uses tighter constraints (lower temperature, shorter generation).

Serves on localhost:8420. Models loaded to GPU at startup.
"""

import sys
import os
import time
import torch
from fastapi import FastAPI
from pydantic import BaseModel
import uvicorn

# Add server dir to path
sys.path.insert(0, os.path.dirname(__file__))

from layer2_model import Layer2Model
from layer3_model import Layer3Model
from emotion_coords import default_vector, NUM_DIMS, DIMENSIONS, top_dimensions, valence_summary

app = FastAPI(title="Burg Inference Server", version="1.0")

# Global model instances
layer2: Layer2Model | None = None
layer3: Layer3Model | None = None
startup_time: float = 0


# --- Request/Response Models ---

class ProjectRequest(BaseModel):
    layer1_state: dict
    recent_events: list[str] = []
    current_vector: list[float] = []

class ProjectResponse(BaseModel):
    vector: list[float]
    summary: str
    top_dimensions: list[dict]
    valence: dict

class ModulateRequest(BaseModel):
    directives: str
    current_vector: list[float] = []

class ModulateResponse(BaseModel):
    learning_rate_mod: float
    exploration_bias: float
    attention_weight: float
    interruption_sensitivity: float
    persistence_scale: float

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
    layer2_model: str
    layer3_model: str
    gpu_memory_used_mb: float
    gpu_memory_total_mb: float
    uptime_seconds: float


# --- Startup ---

@app.on_event("startup")
async def load_models():
    global layer2, layer3, startup_time
    startup_time = time.time()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Using device: {device}")

    # Both layers use the same model (SmolLM2-135M-Instruct)
    # Layer 2 constrains it more tightly
    model_name = "HuggingFaceTB/SmolLM2-135M-Instruct"

    layer2 = Layer2Model(model_name=model_name, device=device)
    # Layer 3 uses a larger model for planning/dialogue/chat
    layer3_model_name = "HuggingFaceTB/SmolLM2-1.7B-Instruct"
    layer3 = Layer3Model(model_name=layer3_model_name, device=device)

    # Warm up with a test generation
    print("Warming up models...")
    _ = layer2.project(
        {"energy": 50, "hunger": 30, "frustration": 0.1, "social_need": 40, "safety": 80, "task_momentum": 0.3},
        ["saw a stranger near the well"],
        default_vector()
    )
    print("Server ready.")


# --- Endpoints ---

@app.get("/health", response_model=HealthResponse)
async def health():
    gpu_mem = 0
    gpu_total = 0
    if torch.cuda.is_available():
        gpu_mem = torch.cuda.memory_allocated() / 1e6
        gpu_total = torch.cuda.get_device_properties(0).total_memory / 1e6

    return HealthResponse(
        status="ok" if layer2 and layer3 else "loading",
        layer2_model=layer2.model_name if layer2 else "not loaded",
        layer3_model=layer3.model_name if layer3 else "not loaded",
        gpu_memory_used_mb=gpu_mem,
        gpu_memory_total_mb=gpu_total,
        uptime_seconds=time.time() - startup_time,
    )


@app.post("/layer2/project", response_model=ProjectResponse)
async def layer2_project(req: ProjectRequest):
    vec = req.current_vector if len(req.current_vector) == NUM_DIMS else default_vector()
    result = layer2.project(req.layer1_state, req.recent_events, vec)
    top = top_dimensions(result["vector"], 5)
    val = valence_summary(result["vector"])
    return ProjectResponse(
        vector=result["vector"],
        summary=result["summary"],
        top_dimensions=[{"name": name, "value": round(v, 3)} for name, v in top],
        valence=val,
    )


@app.post("/layer2/modulate", response_model=ModulateResponse)
async def layer2_modulate(req: ModulateRequest):
    vec = req.current_vector if len(req.current_vector) == NUM_DIMS else default_vector()
    params = layer2.modulate(req.directives, vec)
    return ModulateResponse(**params)


@app.post("/layer3/plan", response_model=PlanResponse)
async def layer3_plan(req: PlanRequest):
    result = layer3.plan(req.role, req.memory_summary, req.current_context, req.emotion_summary)
    return PlanResponse(**result)


@app.post("/layer3/reflect", response_model=ReflectResponse)
async def layer3_reflect(req: ReflectRequest):
    result = layer3.reflect(req.memory_events)
    return ReflectResponse(**result)


@app.post("/layer3/dialogue", response_model=DialogueResponse)
async def layer3_dialogue(req: DialogueRequest):
    result = layer3.dialogue(req.role, req.emotion_summary,
                             req.relationship_context, req.recent_events)
    return DialogueResponse(**result)


@app.post("/layer3/chat", response_model=ChatResponse)
async def layer3_chat(req: ChatRequest):
    result = layer3.chat(req.role, req.npc_name, req.emotion_summary,
                          req.relationship_context, req.recent_events,
                          req.conversation_history, req.player_message)
    return ChatResponse(**result)


@app.post("/layer3/converse", response_model=ConverseResponse)
async def layer3_converse(req: ConverseRequest):
    result = layer3.converse(req.speaker_role, req.speaker_emotion,
                              req.listener_role, req.listener_emotion,
                              req.shared_context, req.speaker_recent)
    return ConverseResponse(**result)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8420, log_level="info")
