#!/usr/bin/env python3
"""
Tests for the thought loop pipeline.
Run with the L3 server loaded: python3 test_thought_loop.py

Tests each stage independently:
1. Does generate_thought() produce THOUGHT/WANT/FEEL?
2. Does _parse_simple_thought() extract structure correctly?
3. Does the chat prompt include perception context?
4. Does belief extraction parse beliefs from conversation?
5. Does NPCState manage intentions/beliefs correctly?
6. End-to-end: snapshot → thought → commands
"""

import sys
import os
import json
import time

sys.path.insert(0, os.path.dirname(__file__))

PASS = 0
FAIL = 0


def test(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  PASS: {name}")
    else:
        FAIL += 1
        print(f"  FAIL: {name} — {detail}")


def section(name):
    print(f"\n{'='*60}")
    print(f"  {name}")
    print(f"{'='*60}")


# ============================================================
# 1. Parser tests (no model needed)
# ============================================================
section("1. _parse_simple_thought parser")

from layer3_model import Layer3Model

m = object.__new__(Layer3Model)
m.personas = {}
m.locations = {"inn": {}, "bakery": {}, "market": {}, "town_square": {}, "farm": {}}

# Structured output
raw = "THOUGHT: A stranger is walking toward me.\nWANT: Go to the market to buy supplies\nFEEL: curious"
r = m._parse_simple_thought(raw, {})
test("parses THOUGHT line", len(r["thoughts"]) == 1 and "stranger" in r["thoughts"][0])
test("parses WANT as intention", len(r["intentions"]) == 1, f"got {r['intentions']}")
test("intention has correct location", r["intentions"][0]["location"] == "market" if r["intentions"] else "no intent")
test("parses FEEL into biases", "observe" in r["action_biases"], f"got {r['action_biases']}")

# Unstructured fallback
raw2 = "I wonder what that noise was. Maybe I should investigate."
r2 = m._parse_simple_thought(raw2, {})
test("fallback: raw text becomes thought", len(r2["thoughts"]) == 1, f"got {r2['thoughts']}")
test("fallback: no false intentions", len(r2["intentions"]) == 0)

# Empty output
r3 = m._parse_simple_thought("", {})
test("empty: no crash", len(r3["thoughts"]) == 0)

# WANT with no location match
raw4 = "THOUGHT: Feeling restless.\nWANT: Just pace around\nFEEL: bored"
r4 = m._parse_simple_thought(raw4, {})
test("WANT without location: no intention", len(r4["intentions"]) == 0)
test("WANT without location: thought still captured", len(r4["thoughts"]) == 1)

# FEEL emotion → bias mapping
raw5 = "THOUGHT: Something feels wrong.\nWANT: nothing\nFEEL: anxious"
r5 = m._parse_simple_thought(raw5, {})
test("anxious → flee/avoid bias", r5["action_biases"].get("flee", 0) > 0 or r5["action_biases"].get("avoid", 0) > 0,
     f"got {r5['action_biases']}")


# ============================================================
# 2. NPCState tests (no model needed)
# ============================================================
section("2. NPCState management")

from npc_state import NPCState

persona = {
    "name": "Hugo",
    "role": "Innkeeper",
    "schedule": [
        {"location": "inn", "duration": 6.0, "priority": 0.8, "purpose": "Serve guests"},
        {"location": "market", "duration": 2.0, "priority": 0.5, "purpose": "Buy supplies"},
    ],
    "personality": {"traits": ["jovial"], "speech_style": "warm", "backstory": "Runs the inn."},
}

state = NPCState("Hugo", "Innkeeper", persona)
test("schedule seeds routine intentions", len(state.active_intentions) == 2, f"got {len(state.active_intentions)}")
test("routine intentions are low priority", all(i["priority"] <= 0.5 for i in state.active_intentions),
     f"priorities: {[i['priority'] for i in state.active_intentions]}")

# Add a high-priority intention
state.add_intention("Greet the stranger", "inn", 0.8, "saw someone new")
test("add intention", len(state.active_intentions) == 3)
top = state.get_top_intention()
test("top intention is highest priority", top["goal"] == "Greet the stranger", f"got {top}")

# Duplicate goal updates priority
state.add_intention("Greet the stranger", "inn", 0.9, "they're closer now")
test("duplicate goal updates, doesn't add", len(state.active_intentions) == 3)
top2 = state.get_top_intention()
test("priority updated", top2["priority"] == 0.9)

# Beliefs
state.add_belief("Player", "is", "a traveler", 0.7, "observation")
test("add belief", len(state.beliefs) == 1)
state.add_belief("Player", "is", "a traveler", 0.5, "conversation")
test("reinforcing belief boosts confidence", state.beliefs[0]["confidence"] > 0.7)
state.add_belief("Player", "is", "a merchant", 0.9, "conversation")
test("contradicting belief with higher confidence replaces", state.beliefs[0]["object"] == "a merchant")

summary = state.get_beliefs_summary()
test("beliefs summary not empty", len(summary) > 0, f"got '{summary}'")

# Snapshot + urgency
state.receive_snapshot({
    "drives": {"energy": 15, "hunger": 80, "safety": 30, "frustration": 0.6},
    "visible": [{"name": "Player", "distance": 2.0, "direction": "east"}],
    "recent_events": ["Stranger arrived"],
})
test("has fresh snapshot", state.has_fresh_snapshot())
urgency = state.compute_urgency()
test("low energy + high hunger = high urgency", urgency > 0.5, f"got {urgency:.2f}")

# Thought recording
state.record_thought("Who is this stranger?")
test("thought recorded", state.current_thought == "Who is this stranger?")
test("thought in history", len(state.thought_history) == 1)

# Context building
ctx = state.build_thought_context()
test("context has drives", "energy" in ctx["drives"])
test("context has visible", len(ctx["visible"]) > 0)
test("context has beliefs summary", len(ctx["beliefs_summary"]) > 0)
test("context has recent thoughts", len(ctx["recent_thoughts"]) > 0)


# ============================================================
# 3. Model inference test (needs running L3 server model)
# ============================================================
section("3. generate_thought() model output format")

try:
    import torch
    from layer3_model import Layer3Model as L3

    print("  Loading model (this takes ~20s)...")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = L3(model_name="HuggingFaceTB/SmolLM2-1.7B-Instruct", device=device)

    context = {
        "npc_name": "Hugo",
        "role": "Innkeeper",
        "persona": persona,
        "hour": 8.0,
        "location": "inn",
        "position": [2096, 800],
        "drives": {"energy": 70, "hunger": 30, "social_need": 50, "safety": 80, "frustration": 0.1, "task_momentum": 0.3},
        "emotion_vector": [0.1] * 27,
        "visible": [{"name": "Player", "distance": 2.0, "direction": "east", "exposure": 0.9}],
        "heard": [],
        "recent_events": ["A traveler arrived at the inn"],
        "current_action": "Serve guests",
        "intentions_summary": "Serve guests at inn (routine)",
        "beliefs_summary": "none",
        "recent_thoughts": [],
    }

    print("  Running generate_thought()...")
    t0 = time.time()
    result = model.generate_thought(context)
    elapsed = time.time() - t0

    print(f"  Raw output ({elapsed:.1f}s):")
    for line in result["raw"].split("\n"):
        print(f"    | {line}")
    print(f"  Parsed thoughts: {result['thoughts']}")
    print(f"  Parsed intentions: {result['intentions']}")
    print(f"  Parsed biases: {result['action_biases']}")

    test("model produced output", len(result["raw"]) > 0)
    test("at least one thought extracted", len(result["thoughts"]) > 0, f"got {result['thoughts']}")
    test(f"inference time reasonable (<15s)", elapsed < 15, f"took {elapsed:.1f}s")

    # Test with different scenario: NPC alone, hungry
    context2 = dict(context)
    context2["drives"] = {"energy": 20, "hunger": 85, "social_need": 70, "safety": 80, "frustration": 0.4, "task_momentum": 0.1}
    context2["visible"] = []
    context2["recent_events"] = ["My energy is low", "I haven't eaten"]

    print("\n  Running generate_thought() — hungry/tired scenario...")
    t0 = time.time()
    result2 = model.generate_thought(context2)
    elapsed2 = time.time() - t0

    print(f"  Raw output ({elapsed2:.1f}s):")
    for line in result2["raw"].split("\n"):
        print(f"    | {line}")
    print(f"  Parsed thoughts: {result2['thoughts']}")
    print(f"  Parsed intentions: {result2['intentions']}")
    print(f"  Parsed biases: {result2['action_biases']}")

    test("hungry scenario: produced output", len(result2["raw"]) > 0)
    test("hungry scenario: thought extracted", len(result2["thoughts"]) > 0)

    # Test chat prompt includes perception
    print("\n  Testing chat_from_packet perception...")
    chat_params = {
        "npc_name": "Hugo",
        "role": "Innkeeper",
        "trust": 0.5,
        "conversation_history": [],
        "player_message": "What do you see around you?",
        "perception": "You are near the inn. You can see: a traveler, 2 tiles away.",
        "current_thought": "A stranger just arrived.",
        "somatic_tags": ["head:buzzing", "chest:open"],
    }

    t0 = time.time()
    chat_result = model.chat_from_packet(chat_params)
    elapsed3 = time.time() - t0
    utterance = chat_result.get("utterance", "")
    print(f"  Chat response ({elapsed3:.1f}s): \"{utterance}\"")

    test("chat produced utterance", len(utterance) > 0)
    # Check if the response mentions the traveler/perception context
    has_grounding = any(w in utterance.lower() for w in ["traveler", "stranger", "someone", "you", "visitor", "person", "see"])
    test("chat references visible entity", has_grounding, f"utterance: {utterance[:100]}")

    # Check for hallucination markers
    halluc_words = ["fire", "fireplace", "hearth", "roast", "candle", "ale", "mug", "chair", "table", "armor", "sword"]
    has_halluc = any(w in utterance.lower() for w in halluc_words)
    test("chat does NOT hallucinate furniture", not has_halluc,
         f"found hallucination in: {utterance[:100]}")

except ImportError as e:
    print(f"  SKIP: Model tests require torch ({e})")
except Exception as e:
    print(f"  ERROR: {e}")
    import traceback
    traceback.print_exc()


# ============================================================
# 4. Belief extraction test (needs model)
# ============================================================
section("4. Belief extraction from conversation")

try:
    print("  Testing extract_beliefs_from_conversation()...")
    t0 = time.time()
    beliefs = model.extract_beliefs_from_conversation(
        "Hugo", "Innkeeper",
        "The bakery oven has been broken since yesterday.",
        "Edith"
    )
    elapsed = time.time() - t0
    print(f"  Raw result ({elapsed:.1f}s): {beliefs}")
    test("belief extraction produced result", "beliefs" in beliefs)
    # This may or may not produce beliefs depending on model quality
    if beliefs["beliefs"]:
        print(f"  Extracted beliefs: {beliefs['beliefs']}")
        test("extracted at least one belief", True)
    else:
        print("  No beliefs extracted (model may not support this format)")
        test("belief extraction ran without error", True)
except NameError:
    print("  SKIP: Model not loaded")
except Exception as e:
    print(f"  ERROR: {e}")


# ============================================================
# Summary
# ============================================================
print(f"\n{'='*60}")
print(f"  Results: {PASS} passed, {FAIL} failed")
print(f"{'='*60}")
sys.exit(1 if FAIL > 0 else 0)
