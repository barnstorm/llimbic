"""
Layer 2 Inference Server — Limbic System

Runs TinyLlama-1.1B + LoRA on localhost:8420.
Medium-cadence calls (~every 2s per NPC) for emotion projection,
attention focus, and motivational drive computation.
"""

import sys
import os
import time
import json
import asyncio
from concurrent.futures import ThreadPoolExecutor
import torch
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [L2] %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("layer2")
_fh = logging.FileHandler("/tmp/burg_l2.log", mode="w")
_fh.setFormatter(logging.Formatter("%(asctime)s [L2] %(message)s", datefmt="%H:%M:%S"))
log.addHandler(_fh)

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
    emotions: dict = {}
    attention: list[str] = []
    drives: dict = {}

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
    model = Layer2Model(device=device)
    # Warm up
    _ = model.project(
        {"energy": 50, "hunger": 30, "frustration": 0.1, "social_need": 40, "safety": 80, "task_momentum": 0.3},
        [], default_vector()
    )
    print("Layer 2 limbic server ready.")


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
    t0 = time.time()
    result = await _run(model.project, req.layer1_state, req.recent_events, vec)
    top = top_dimensions(result["vector"], 5)
    val = valence_summary(result["vector"])
    top_str = ", ".join(f"{d['name']}={d['value']:.2f}" for d in [{"name": n, "value": round(v, 3)} for n, v in top][:3])
    emo_str = ", ".join(f"{k}={v:.2f}" for k, v in list(result.get("emotions", {}).items())[:3])
    att_str = ", ".join(result.get("attention", [])[:3])
    log.info(f"PROJECT e={req.layer1_state.get('energy',0):.0f} f={req.layer1_state.get('frustration',0):.2f} -> {emo_str} attn=[{att_str}] [{time.time()-t0:.2f}s]")
    return ProjectResponse(
        vector=result["vector"], summary=result["summary"],
        top_dimensions=[{"name": n, "value": round(v, 3)} for n, v in top],
        valence=val,
        emotions=result.get("emotions", {}),
        attention=result.get("attention", []),
        drives=result.get("drives", {}),
    )

@app.post("/layer2/modulate", response_model=ModulateResponse)
async def modulate(req: ModulateRequest):
    vec = req.current_vector if len(req.current_vector) == NUM_DIMS else default_vector()
    t0 = time.time()
    params = await _run(model.modulate, req.directives, vec)
    log.info(f"MODULATE '{req.directives[:50]}' -> lr={params['learning_rate_mod']:.1f} exp={params['exploration_bias']:.1f} [{time.time()-t0:.2f}s]")
    return ModulateResponse(**params)


# --- WebSocket endpoint ---
# Same multiplexing pattern as Layer 3. Client sends:
#   {"id": "req_1", "method": "project", "params": {...}}
# Server sends:
#   {"id": "req_1", "result": {...}}

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    print("Layer 2 WebSocket client connected")
    state = {"open": True}
    pending_tasks: set = set()

    async def safe_send(text: str):
        if not state["open"]:
            return
        try:
            await ws.send_text(text)
        except Exception:
            state["open"] = False

    async def handle(req_id: str, method: str, params: dict):
        t0 = time.time()
        try:
            result = await _ws_dispatch(method, params)
            elapsed = time.time() - t0
            if method == "project":
                top_str = ", ".join(f"{d['name']}={d['value']:.2f}" for d in result.get("top_dimensions", [])[:3])
                log.info(f"WS PROJECT -> {top_str} [{elapsed:.2f}s]")
            else:
                log.info(f"WS {method.upper()} [{elapsed:.2f}s]")
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

            task = asyncio.create_task(handle(req_id, method, params))
            pending_tasks.add(task)
            task.add_done_callback(pending_tasks.discard)
    except WebSocketDisconnect:
        log.info("Layer 2 WebSocket client disconnected")
    except Exception as e:
        print(f"Layer 2 WebSocket error: {e}")
    finally:
        state["open"] = False
        for t in pending_tasks:
            t.cancel()
        pending_tasks.clear()


async def _ws_dispatch(method: str, params: dict) -> dict:
    """Route a WebSocket request to the right model method."""
    if method == "project":
        layer1_state = params.get("layer1_state", {})
        recent_events = params.get("recent_events", [])
        current_vector = params.get("current_vector", [])
        vec = current_vector if len(current_vector) == NUM_DIMS else default_vector()
        result = await _run(model.project, layer1_state, recent_events, vec)
        top = top_dimensions(result["vector"], 5)
        val = valence_summary(result["vector"])
        return {
            "vector": result["vector"],
            "summary": result["summary"],
            "top_dimensions": [{"name": n, "value": round(v, 3)} for n, v in top],
            "valence": val,
            "emotions": result.get("emotions", {}),
            "attention": result.get("attention", []),
            "drives": result.get("drives", {}),
        }
    elif method == "modulate":
        directives = params.get("directives", "")
        current_vector = params.get("current_vector", [])
        vec = current_vector if len(current_vector) == NUM_DIMS else default_vector()
        return await _run(model.modulate, directives, vec)
    else:
        return {"error": f"unknown method: {method}"}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8420, log_level="info")
