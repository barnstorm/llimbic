#!/usr/bin/env bash
# scripts/run_accelerated.sh — Phase 1.5 accelerated harness CLI.
#
# Per docs/perception_implementation_plan.md Phase 1.5 (F3, pulled from
# Phase 12). Used to accumulate substrate experience faster than wall-clock,
# so later phases (4 needs 200 action-success events, 5 needs 20 encounters,
# 8 needs being maturity = 50+ drift cycles per appraisal) become tractable.
#
# What scales with --accel: Hebbian propagate/update/neurogenesis, drive
# baseline drift, NPC movement, somatic emit, reward decay.
# What does NOT scale: LLM thought cycles (cadence is wall-clock-gated;
# the plan calls this out: "LLM calls remain real").
#
# Usage:
#   scripts/run_accelerated.sh --accel 10 --duration 600s
#   scripts/run_accelerated.sh --accel 20 --duration 30m --out /tmp/sim.jsonl
#
# The script:
#   1. Sets BURG_ACCEL env var so the AcceleratedMode autoload picks it up.
#   2. Launches `godot --headless` against the project (main.tscn loads NPCs).
#   3. Waits for --duration wall-clock seconds, sends SIGTERM to the engine.
#   4. Trace path is whatever the running layer3_server's trace_logger writes
#      to (per-session /tmp/burg_trace_{ts}.jsonl). --out is a hint for
#      symlink/copy after the run completes.
#
# Exit code: 0 = clean run, 1 = config error, 2 = engine crash.

set -euo pipefail

ACCEL=10
DURATION="60s"
OUT=""
SEED=42
EXTRA_ARGS=()
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 [options]

  --accel N         Time-scale multiplier (default: 10). Capped at 60.
  --duration TIME   Wall-clock duration. Suffix s/m/h, e.g. 30s, 5m, 1h.
                    Default: 60s.
  --seed N          Reserved for future deterministic-replay support.
  --out PATH        After run completes, copy the session trace to PATH.
                    (The engine writes to /tmp/burg_trace_*.jsonl regardless.)
  --                Pass remaining args to godot.

Environment:
  BURG_ACCEL        Overridden by --accel.

Examples:
  $0 --accel 10 --duration 60s
  $0 --accel 20 --duration 5m --out /tmp/sim_5min.jsonl
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --accel)    ACCEL="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --seed)     SEED="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --npcs)     # placeholder; npcs are loaded by the main scene's persona registry
                shift 2 ;;
    --help|-h)  usage; exit 0 ;;
    --)         shift; EXTRA_ARGS+=("$@"); break ;;
    *)          echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# Validate accel.
if ! [[ "$ACCEL" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "--accel must be a positive number, got: $ACCEL" >&2; exit 1
fi

# Convert duration to seconds.
case "$DURATION" in
  *s) DURATION_SEC="${DURATION%s}" ;;
  *m) DURATION_SEC=$(( ${DURATION%m} * 60 )) ;;
  *h) DURATION_SEC=$(( ${DURATION%h} * 3600 )) ;;
  *)  DURATION_SEC="$DURATION" ;;
esac
if ! [[ "$DURATION_SEC" =~ ^[0-9]+$ ]] || (( DURATION_SEC < 1 )); then
  echo "--duration must be positive (got: $DURATION → ${DURATION_SEC}s)" >&2; exit 1
fi

GODOT_BIN="${GODOT_BIN:-godot}"
if ! command -v "$GODOT_BIN" >/dev/null 2>&1; then
  echo "godot binary not found on PATH (set GODOT_BIN to override)" >&2; exit 1
fi

START_TS=$(date +%s)
echo "[run_accelerated] starting headless Godot"
echo "  project:  $PROJECT_ROOT"
echo "  accel:    ${ACCEL}x"
echo "  duration: ${DURATION_SEC}s wall-clock (~$(awk -v a="$ACCEL" -v d="$DURATION_SEC" 'BEGIN{print a*d}')s simulated)"
echo "  seed:     $SEED"

# Snapshot existing trace files so we can identify the new one.
PRE_TRACES=$(find /tmp -maxdepth 1 -name 'burg_trace_*.jsonl' -newer /tmp -mmin -60 2>/dev/null | sort)

BURG_ACCEL="$ACCEL" "$GODOT_BIN" \
  --path "$PROJECT_ROOT" \
  --headless \
  "${EXTRA_ARGS[@]}" \
  >/tmp/run_accelerated.log 2>&1 &
GODOT_PID=$!
echo "[run_accelerated] godot pid=$GODOT_PID, log=/tmp/run_accelerated.log"

# Cleanup on signal.
trap 'echo "[run_accelerated] interrupted; killing pid $GODOT_PID"; kill "$GODOT_PID" 2>/dev/null || true; exit 130' INT TERM

# Wait for duration, then terminate cleanly.
sleep "$DURATION_SEC"

if kill -0 "$GODOT_PID" 2>/dev/null; then
  echo "[run_accelerated] duration reached; sending SIGTERM"
  kill "$GODOT_PID" 2>/dev/null || true
  # Give Godot 5 s to flush traces.
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$GODOT_PID" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$GODOT_PID" 2>/dev/null; then
    echo "[run_accelerated] still alive after SIGTERM; SIGKILL"
    kill -9 "$GODOT_PID" 2>/dev/null || true
  fi
fi

WAIT_RC=0
wait "$GODOT_PID" 2>/dev/null || WAIT_RC=$?
END_TS=$(date +%s)
WALL_SEC=$(( END_TS - START_TS ))
echo "[run_accelerated] godot exit=$WAIT_RC wall_sec=${WALL_SEC}"

# Identify the newly-created trace file.
NEW_TRACE=""
for f in $(find /tmp -maxdepth 1 -name 'burg_trace_*.jsonl' -newer /tmp -mmin -60 2>/dev/null); do
  if ! grep -qF "$f" <<<"$PRE_TRACES"; then
    NEW_TRACE="$f"
  fi
done
if [[ -n "$NEW_TRACE" ]]; then
  echo "[run_accelerated] trace: $NEW_TRACE ($(wc -l <"$NEW_TRACE") events)"
  if [[ -n "$OUT" ]]; then
    cp "$NEW_TRACE" "$OUT"
    echo "[run_accelerated] copied trace → $OUT"
  fi
fi

# Acceptance gate per plan: trace must remain byte-compatible with realtime parser.
if [[ -n "$NEW_TRACE" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$NEW_TRACE" <<'PY'
import json, sys
path = sys.argv[1]
n_events = n_v2 = 0
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception as e:
            print(f"[run_accelerated] PARSE ERROR at line {n_events+1}: {e}", file=sys.stderr)
            sys.exit(2)
        n_events += 1
        if d.get("trace_schema_version") == 2:
            n_v2 += 1
print(f"[run_accelerated] trace parse OK: {n_events} events, {n_v2} v2-schema")
PY
fi

if (( WAIT_RC != 0 )) && (( WAIT_RC != 143 )); then
  # 143 = SIGTERM (expected); other non-zero is a real crash.
  echo "[run_accelerated] godot exited with $WAIT_RC (non-clean)" >&2
  exit 2
fi

exit 0
