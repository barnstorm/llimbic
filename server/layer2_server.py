"""
Layer 2 Inference Server — Fast projection/modulation

Runs SmolLM2-135M-Instruct on localhost:8420.
High-frequency, low-latency calls for emotion vector projection
and behavioral modulation. Designed for ~4 calls/sec from 8 NPCs.
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

from layer2_model import Layer2Model
from emotion_coords import default_vector, NUM_DIMS, top_dimensions, valence_summary

app = FastAPI(title="Burg Layer 2 Server", version="1.0")
model: Layer2Model | None = None
startup_time: float = 0


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

class HealthResponse(BaseModel):
    status: str
    model: str
    gpu_memory_used_mb: float
    uptime_seconds: float


@app.on_event("startup")
async def load_model():
    global model, startup_time
    startup_time = time.time()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = Layer2Model(model_name="HuggingFaceTB/SmolLM2-135M-Instruct", device=device)
    # Warm up
    _ = model.project(
        {"energy": 50, "hunger": 30, "frustration": 0.1, "social_need": 40, "safety": 80, "task_momentum": 0.3},
        [], default_vector()
    )
    print("Layer 2 server ready.")


async def _run(fn, *args):
    return await asyncio.get_event_loop().run_in_executor(_executor, fn, *args)


@app.get("/health", response_model=HealthResponse)
async def health():
    gpu_mem = torch.cuda.memory_allocated() / 1e6 if torch.cuda.is_available() else 0
    return HealthResponse(
        status="ok" if model else "loading",
        model=model.model_name if model else "not loaded",
        gpu_memory_used_mb=gpu_mem,
        uptime_seconds=time.time() - startup_time,
    )

@app.post("/layer2/project", response_model=ProjectResponse)
async def project(req: ProjectRequest):
    vec = req.current_vector if len(req.current_vector) == NUM_DIMS else default_vector()
    result = await _run(model.project, req.layer1_state, req.recent_events, vec)
    top = top_dimensions(result["vector"], 5)
    val = valence_summary(result["vector"])
    return ProjectResponse(
        vector=result["vector"], summary=result["summary"],
        top_dimensions=[{"name": n, "value": round(v, 3)} for n, v in top],
        valence=val,
    )

@app.post("/layer2/modulate", response_model=ModulateResponse)
async def modulate(req: ModulateRequest):
    vec = req.current_vector if len(req.current_vector) == NUM_DIMS else default_vector()
    params = await _run(model.modulate, req.directives, vec)
    return ModulateResponse(**params)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8420, log_level="info")
