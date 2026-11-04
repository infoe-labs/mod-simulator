#!/usr/bin/env bash
# Every gate the project must pass before a build is published.
#   tools/check_all.sh
set -uo pipefail
cd "$(dirname "$0")/.."

GODOT=${GODOT:-godot}
if ! command -v "$GODOT" >/dev/null 2>&1; then
  if [ -x "$HOME/.local/bin/godot" ]; then GODOT="$HOME/.local/bin/godot"; else
    echo "godot not found (set GODOT=/path/to/godot)"; exit 2; fi
fi

fail=0
run() {
  local name=$1; shift
  printf '%-16s ' "$name"
  local out
  out=$(timeout "${TIMEOUT:-600}" "$@" 2>&1)
  local rc=$?
  if [ $rc -eq 0 ] && ! grep -qE "FAILURE|FAILED|SCRIPT ERROR|Parse Error" <<<"$out"; then
    grep -E "ALL PASS|BALANCE OK|SMOKE OK|LAYOUT OK|PAUSE MENU OK|PALETTE OK|SHOTS OK|E2E OK" <<<"$out" | tail -1
  else
    echo "FAILED (exit $rc)"
    tail -25 <<<"$out"
    fail=1
  fi
}

echo "── Streamer Moderator Simulator: checks ──"
run palette  python3 tools/check_palette.py
run logic    "$GODOT" --headless --path game -s res://tests/run_tests.gd
run balance  "$GODOT" --headless --path game -s res://tests/sim_tests.gd
run smoke    "$GODOT" --headless --path game -s res://tests/smoke.gd
run layout   "$GODOT" --headless --path game -s res://tests/layout_audit.gd
run pause    "$GODOT" --headless --path game -s res://tests/pause_input.gd
run ai       "$GODOT" --headless --path game -s res://tests/ai_tests.gd

if [ "${SKIP_BROWSER:-0}" != "1" ]; then
  run export ./tools/export.sh
  PORT=${PORT:-8765}
  python3 tools/serve.py --port "$PORT" >/dev/null 2>&1 &
  SRV=$!
  sleep 2
  ( cd tools/e2e && run browser node e2e.mjs --url "http://127.0.0.1:$PORT/" ) \
    || { echo "browser check needs: cd tools/e2e && npm install"; fail=1; }
  kill $SRV 2>/dev/null
  run shots python3 tools/check_shots.py
  # The real-inference gate is slow (it downloads a model), so it is opt-in:
  #   AI_LAB=1 tools/check_all.sh
  if [ "${AI_LAB:-0}" = "1" ]; then
    PORT_AI=${PORT_AI:-8766}
    python3 tools/serve.py --dir game/web --port "$PORT_AI" --coi >/dev/null 2>&1 &
    SRV_AI=$!
    sleep 2
    ( cd tools/e2e && node ai_lab.mjs --url "http://127.0.0.1:$PORT_AI/" ${AI_MODEL:+--model "$AI_MODEL"} ) \
      || { echo "AI lab failed"; fail=1; }
    kill $SRV_AI 2>/dev/null
  fi
fi

if [ $fail -eq 0 ]; then echo "── ALL CHECKS PASSED ──"; else echo "── CHECKS FAILED ──"; fi
exit $fail
