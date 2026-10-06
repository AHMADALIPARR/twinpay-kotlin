#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p .runtime
PID_FILE=.runtime/burt.pid
LOG_FILE=.runtime/burt.log

running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid=$(cat "$PID_FILE")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$pid/cmdline")" == *twinpay_agents* ]]
}

case "${1:-status}" in
  start)
    if running; then echo "Burt Parr is already running (PID $(cat "$PID_FILE"))."; exit 0; fi
    command -v codex >/dev/null || { echo 'Install the Codex CLI first.' >&2; exit 1; }
    codex login status
    uv sync --locked
    .venv/bin/python -c 'from twinpay_agents.config import Settings; Settings.load()'
    nohup .venv/bin/python -m twinpay_agents > "$LOG_FILE" 2>&1 < /dev/null &
    echo "$!" > "$PID_FILE"
    echo "Started PID $(cat "$PID_FILE"); connection and replies must be verified separately."
    ;;
  stop)
    if running; then
      pid=$(cat "$PID_FILE")
      kill "$pid"
      for ((i=0; i<100; i++)); do
        running || break
        sleep 0.1
      done
      if running; then echo 'Shutdown still in progress; inspect logs before restarting.' >&2; exit 1; fi
      rm "$PID_FILE"
      echo 'Stopped Burt Parr.'
    else echo 'Burt Parr is not running.'; fi
    ;;
  status)
    if running; then echo "Running (PID $(cat "$PID_FILE")); this does not prove message replies."; else echo 'Not running.'; fi
    ;;
  logs) tail -n 40 -f "$LOG_FILE" ;;
  *) echo 'Usage: bash scripts/agent.sh {start|stop|status|logs}' >&2; exit 2 ;;
esac
