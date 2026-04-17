"""
Tests for the Burg inference server.
Run with: python3 server/test_server.py
Expects server running at localhost:8420.
"""

import sys
import json
import time
import requests

L2_BASE = "http://127.0.0.1:8420"
L3_BASE = "http://127.0.0.1:8421"
PASS = 0
FAIL = 0


def test(name, fn):
    global PASS, FAIL
    try:
        fn()
        PASS += 1
        print(f"  PASS: {name}")
    except Exception as e:
        FAIL += 1
        print(f"  FAIL: {name} — {e}")


def check_health_l2():
    r = requests.get(f"{L2_BASE}/health", timeout=5)
    assert r.status_code == 200
    d = r.json()
    assert d["status"] == "ok"
    assert "SmolLM2" in d["model"]

def check_health_l3():
    r = requests.get(f"{L3_BASE}/health", timeout=5)
    assert r.status_code == 200
    d = r.json()
    assert d["status"] == "ok"
    assert "1.7B" in d["model"]


def check_layer2_project():
    r = requests.post(f"{L2_BASE}/layer2/project", json={
        "layer1_state": {"energy": 40, "hunger": 60, "frustration": 0.4,
                         "social_need": 70, "safety": 60, "task_momentum": 0.3},
        "recent_events": ["was interrupted", "saw a fight"],
        "current_vector": [0.1] * 27,
    }, timeout=10)
    assert r.status_code == 200
    d = r.json()
    assert len(d["vector"]) == 27
    assert all(0.0 <= v <= 1.0 for v in d["vector"])
    assert len(d["top_dimensions"]) > 0
    assert "summary" in d


def check_layer2_modulate():
    r = requests.post(f"{L2_BASE}/layer2/modulate", json={
        "directives": "stay alert, avoid east road",
        "current_vector": [0.2] * 27,
    }, timeout=10)
    assert r.status_code == 200
    d = r.json()
    assert 0.5 <= d["learning_rate_mod"] <= 2.0
    assert 0.0 <= d["exploration_bias"] <= 1.0
    assert 0.0 <= d["attention_weight"] <= 1.0
    assert 0.0 <= d["interruption_sensitivity"] <= 1.0
    assert 0.5 <= d["persistence_scale"] <= 2.0


def check_layer3_plan():
    r = requests.post(f"{L3_BASE}/layer3/plan", json={
        "role": "Baker",
        "memory_summary": "Sold bread, heard about wolves",
        "current_context": "10:30 AM, at bakery",
        "somatic_tags": ["body:settled", "head:clear"],
    }, timeout=15)
    assert r.status_code == 200
    d = r.json()
    assert len(d["agenda"]) >= 3
    for chunk in d["agenda"]:
        assert "location" in chunk
        assert "duration" in chunk
        assert "priority" in chunk


def check_layer3_dialogue():
    r = requests.post(f"{L3_BASE}/layer3/dialogue", json={
        "role": "Guard",
        "somatic_tags": ["chest:tight", "head:sharp"],
        "relationship_context": "Trust: 0.5",
        "recent_events": ["patrolled east road"],
    }, timeout=10)
    assert r.status_code == 200
    d = r.json()
    assert "intent" in d
    assert "utterance" in d
    assert len(d["utterance"]) > 0


def check_layer3_chat():
    r = requests.post(f"{L3_BASE}/layer3/chat", json={
        "role": "Guard",
        "npc_name": "Roland",
        "somatic_tags": ["chest:tight", "head:sharp"],
        "relationship_context": "Trust: 0.5",
        "recent_events": ["saw a stranger"],
        "conversation_history": [
            {"speaker": "Roland", "text": "All quiet today."},
        ],
        "player_message": "Have you seen anything unusual?",
    }, timeout=15)
    assert r.status_code == 200
    d = r.json()
    assert "utterance" in d
    assert "mood_shift" in d
    assert len(d["utterance"]) > 0
    # Should NOT be parroting the player's message
    assert d["utterance"].lower() != "have you seen anything unusual?"


def check_layer3_chat_multi_turn():
    """Test that multi-turn conversation tracks context."""
    r = requests.post(f"{L3_BASE}/layer3/chat", json={
        "role": "Baker",
        "npc_name": "Edith",
        "somatic_tags": ["chest:warm:open", "body:light"],
        "relationship_context": "Trust: 0.6",
        "recent_events": ["baked bread", "heard rumor about wolves"],
        "conversation_history": [
            {"speaker": "Edith", "text": "Fresh bread today!"},
            {"speaker": "Player", "text": "I heard there are wolves nearby"},
            {"speaker": "Edith", "text": "Oh my, that's concerning."},
        ],
        "player_message": "Should I warn the guard?",
    }, timeout=15)
    assert r.status_code == 200
    d = r.json()
    assert len(d["utterance"]) > 0


def check_layer3_converse():
    r = requests.post(f"{L3_BASE}/layer3/converse", json={
        "speaker_role": "Gossip",
        "speaker_somatic": ["head:buzzing", "chest:open"],
        "listener_role": "Baker",
        "listener_somatic": ["body:settled"],
        "shared_context": "At town square, morning",
        "speaker_recent": ["saw stranger near well"],
    }, timeout=10)
    assert r.status_code == 200
    d = r.json()
    assert "utterance" in d
    assert "intent" in d
    assert "topic" in d


def check_layer3_reflect():
    r = requests.post(f"{L3_BASE}/layer3/reflect", json={
        "memory_events": [
            "Sold bread to 3 customers",
            "Heard rumor about wolves from the guard",
            "Player asked about the east road",
        ],
    }, timeout=10)
    assert r.status_code == 200
    d = r.json()
    assert "reflections" in d
    assert "concerns" in d


def check_response_time():
    """Layer 2 should be fast (<2s), Layer 3 chat should be reasonable (<5s)."""
    t0 = time.time()
    requests.post(f"{L2_BASE}/layer2/project", json={
        "layer1_state": {"energy": 50, "hunger": 50, "frustration": 0.1,
                         "social_need": 50, "safety": 80, "task_momentum": 0.5},
        "recent_events": [],
        "current_vector": [0.1] * 27,
    }, timeout=10)
    l2_time = time.time() - t0

    t0 = time.time()
    requests.post(f"{L3_BASE}/layer3/chat", json={
        "role": "Guard", "npc_name": "Roland", "somatic_tags": ["chest:tight", "head:sharp"],
        "relationship_context": "Trust: 0.5", "recent_events": [],
        "conversation_history": [], "player_message": "Hello",
    }, timeout=15)
    l3_time = time.time() - t0

    assert l2_time < 2.0, f"Layer 2 too slow: {l2_time:.1f}s"
    assert l3_time < 5.0, f"Layer 3 too slow: {l3_time:.1f}s"
    print(f"    (L2: {l2_time:.2f}s, L3: {l3_time:.2f}s)")


if __name__ == "__main__":
    print("Burg Inference Server Tests")
    print("=" * 40)

    # Check server is reachable
    try:
        requests.get(f"{L2_BASE}/health", timeout=15)
        requests.get(f"{L3_BASE}/health", timeout=15)
    except requests.ConnectionError:
        print("ERROR: Servers not running. Start with: bash server/start.sh")
        sys.exit(1)

    print("\n[Health]")
    test("Layer 2 health (port 8420)", check_health_l2)
    test("Layer 3 health (port 8421)", check_health_l3)

    print("\n[Layer 2 — Projection/Modulation]")
    test("project: 27-dim vector output", check_layer2_project)
    test("modulate: bounded parameters", check_layer2_modulate)

    print("\n[Layer 3 — Planning/Dialogue]")
    test("plan: structured agenda", check_layer3_plan)
    test("dialogue: intent + utterance", check_layer3_dialogue)
    test("chat: single turn", check_layer3_chat)
    test("chat: multi-turn context", check_layer3_chat_multi_turn)
    test("converse: NPC-to-NPC", check_layer3_converse)
    test("reflect: memory compression", check_layer3_reflect)

    print("\n[Performance]")
    test("response times within budget", check_response_time)

    print(f"\n{'=' * 40}")
    print(f"Results: {PASS} passed, {FAIL} failed")
    sys.exit(0 if FAIL == 0 else 1)
