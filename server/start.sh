#!/bin/bash
# Start both inference servers
# Layer 2 (135M) on port 8420 — fast projection/modulation
# Layer 3 (1.7B) on port 8421 — planning/dialogue/chat

cd "$(dirname "$0")"

echo "Starting Layer 2 server (SmolLM2-135M, port 8420)..."
python3 layer2_server.py &
L2_PID=$!

echo "Starting Layer 3 server (SmolLM2-1.7B, port 8421)..."
python3 layer3_server.py &
L3_PID=$!

echo "PIDs: Layer2=$L2_PID, Layer3=$L3_PID"
echo "Waiting for models to load..."

# Wait for both to be ready
for i in $(seq 1 60); do
    L2=$(curl -s http://127.0.0.1:8420/health 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    L3=$(curl -s http://127.0.0.1:8421/health 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    if [ "$L2" = "ok" ] && [ "$L3" = "ok" ]; then
        echo "Both servers ready."
        break
    fi
    sleep 2
done

echo "Press Ctrl+C to stop both servers."
wait
