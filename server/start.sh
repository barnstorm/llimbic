#!/bin/bash
# Start both inference servers with uvicorn
# Layer 2 (135M) on port 8420 — fast projection/modulation
# Layer 3 (1.7B) on port 8421 — planning/dialogue/chat
#
# Usage: bash server/start.sh        # foreground (Ctrl+C stops both)
#        bash server/start.sh &      # background

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

cleanup() {
    echo "Stopping servers..."
    kill $L2_PID $L3_PID 2>/dev/null
    wait $L2_PID $L3_PID 2>/dev/null
    echo "Servers stopped."
}
trap cleanup EXIT INT TERM

echo "Starting Layer 2 server (SmolLM2-135M, port 8420)..."
uvicorn layer2_server:app --host 127.0.0.1 --port 8420 --log-level warning --workers 1 &
L2_PID=$!

echo "Starting Layer 3 server (SmolLM2-1.7B, port 8421)..."
uvicorn layer3_server:app --host 127.0.0.1 --port 8421 --log-level warning --workers 1 &
L3_PID=$!

echo "PIDs: Layer2=$L2_PID, Layer3=$L3_PID"
echo "Waiting for models to load..."

# Poll until both are ready
for i in $(seq 1 120); do
    L2=$(curl -sf http://127.0.0.1:8420/health 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    L3=$(curl -sf http://127.0.0.1:8421/health 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    if [ "$L2" = "ok" ] && [ "$L3" = "ok" ]; then
        echo ""
        echo "Both servers ready."
        echo "  Layer 2: http://127.0.0.1:8420 (SmolLM2-135M)"
        echo "  Layer 3: http://127.0.0.1:8421 (SmolLM2-1.7B)"
        echo ""
        echo "Press Ctrl+C to stop."
        break
    fi
    printf "."
    sleep 1
done

# Keep running until killed
wait
