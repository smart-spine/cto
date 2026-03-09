#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="cto-factory"
CHAT_ID=""
TOPIC_ID=""
CALLBACK_SESSION_ID=""
TIMEOUT_SECONDS=90
STATUS_TIMEOUT_SECONDS=12
LOG_DIR="${HOME}/.openclaw/logs"
OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-id)
      AGENT_ID="${2:-}"
      shift 2
      ;;
    --chat)
      CHAT_ID="${2:-}"
      shift 2
      ;;
    --topic)
      TOPIC_ID="${2:-}"
      shift 2
      ;;
    --callback-session-id)
      CALLBACK_SESSION_ID="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-90}"
      shift 2
      ;;
    --status-timeout)
      STATUS_TIMEOUT_SECONDS="${2:-12}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "${LOG_DIR}"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/cto-gateway-restart-${TS}.log"

resolve_target() {
  python3 - "$AGENT_ID" <<'PY'
import json
import sys
from pathlib import Path

agent_id = sys.argv[1]
cfg = Path.home() / ".openclaw" / "openclaw.json"
chat = ""
topic = ""

try:
    data = json.loads(cfg.read_text(encoding="utf-8"))
    for binding in data.get("bindings", []):
        if binding.get("agentId") != agent_id:
            continue
        match = binding.get("match", {})
        if match.get("channel") != "telegram":
            continue
        peer_id = (((match.get("peer") or {}).get("id")) or "")
        if ":topic:" in peer_id:
            chat, topic = peer_id.split(":topic:", 1)
            break
except Exception:
    pass

print(chat)
print(topic)
PY
}

if [[ -z "${CHAT_ID}" || -z "${TOPIC_ID}" ]]; then
  TARGET="$(resolve_target)"
  if [[ -z "${CHAT_ID}" ]]; then
    CHAT_ID="$(printf "%s\n" "${TARGET}" | sed -n '1p')"
  fi
  if [[ -z "${TOPIC_ID}" ]]; then
    TOPIC_ID="$(printf "%s\n" "${TARGET}" | sed -n '2p')"
  fi
fi

notify() {
  local text="$1"
  if [[ -n "${CHAT_ID}" && -n "${TOPIC_ID}" ]]; then
    openclaw message send \
      --channel telegram \
      --target "${CHAT_ID}:topic:${TOPIC_ID}" \
      --message "${text}" >/dev/null 2>&1 \
      || openclaw system event --mode now --text "${text}" >/dev/null 2>&1 \
      || true
  else
    openclaw system event --mode now --text "${text}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CALLBACK_SESSION_ID}" ]]; then
    openclaw agent \
      --agent "${AGENT_ID}" \
      --session-id "${CALLBACK_SESSION_ID}" \
      --message "${text}" \
      --timeout 120 >/dev/null 2>&1 || true
  fi
}

run_openclaw_with_timeout() {
  local timeout_s="$1"
  shift
  python3 - "${timeout_s}" "$@" <<'PY'
import subprocess
import sys

timeout_s = float(sys.argv[1])
cmd = sys.argv[2:]

try:
    proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout_s, check=False)
    if proc.stdout:
        sys.stdout.write(proc.stdout)
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)
except subprocess.TimeoutExpired as exc:
    out = ""
    if exc.stdout:
        out += exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode("utf-8", "ignore")
    if exc.stderr:
        out += exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode("utf-8", "ignore")
    if out:
        sys.stdout.write(out)
    print(f"[timeout] command exceeded {timeout_s:.0f}s: {' '.join(cmd)}")
    raise SystemExit(124)
PY
}

probe_ok() {
  local out="$1"
  if printf "%s" "${out}" | grep -q "RPC probe: ok"; then
    return 0
  fi
  if printf "%s" "${out}" | grep -q "Connect: ok" && printf "%s" "${out}" | grep -q "RPC: ok"; then
    return 0
  fi
  return 1
}

wait_for_probe() {
  local timeout_total="$1"
  local attempts=0
  local deadline_epoch="$(( $(date +%s) + timeout_total ))"
  while [[ "$(date +%s)" -lt "${deadline_epoch}" ]]; do
    attempts="$((attempts + 1))"
    set +e
    local out
    out="$(run_openclaw_with_timeout "${STATUS_TIMEOUT_SECONDS}" openclaw gateway probe 2>&1)"
    local rc=$?
    set -e
    if [[ -n "${out}" ]]; then
      printf "[probe][attempt=%s][rc=%s] %s\n" "${attempts}" "${rc}" "${out}" >> "${LOG_FILE}" 2>&1
    else
      printf "[probe][attempt=%s][rc=%s] <empty>\n" "${attempts}" "${rc}" >> "${LOG_FILE}" 2>&1
    fi
    if probe_ok "${out}"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

{
  echo "[restart] begin $(date -Iseconds)"
  echo "[restart] agent_id=${AGENT_ID}"
  echo "[restart] target chat=${CHAT_ID:-n/a} topic=${TOPIC_ID:-n/a}"
  echo "[restart] callback_session_id=${CALLBACK_SESSION_ID:-n/a}"
  echo "[restart] openclaw_root=${OPENCLAW_ROOT}"
  echo "[restart] timeouts: total=${TIMEOUT_SECONDS}s status=${STATUS_TIMEOUT_SECONDS}s"
} >> "${LOG_FILE}" 2>&1

# Pre-restart environment snapshot (non-blocking)
set +e
ENV_OUT="$("${OPENCLAW_ROOT}/workspace-factory/scripts/gateway-runtime-detect.sh" "${STATUS_TIMEOUT_SECONDS}" 2>&1)"
ENV_RC=$?
set -e
printf "[env][rc=%s] %s\n" "${ENV_RC}" "${ENV_OUT}" >> "${LOG_FILE}" 2>&1

# Attempt canonical restart first.
set +e
RESTART_OUT="$(run_openclaw_with_timeout 45 openclaw gateway restart 2>&1)"
RESTART_RC=$?
set -e
printf "[restart_cmd][rc=%s] %s\n" "${RESTART_RC}" "${RESTART_OUT}" >> "${LOG_FILE}" 2>&1

if wait_for_probe "${TIMEOUT_SECONDS}"; then
  notify "Gateway restart complete: RPC probe OK."
  echo "[restart] complete mode=restart rc=${RESTART_RC} at $(date -Iseconds)" >> "${LOG_FILE}" 2>&1
  exit 0
fi

# Fallback path: stop -> start when restart path does not converge.
set +e
STOP_OUT="$(run_openclaw_with_timeout 30 openclaw gateway stop 2>&1)"
STOP_RC=$?
sleep 2
START_OUT="$(run_openclaw_with_timeout 45 openclaw gateway start 2>&1)"
START_RC=$?
set -e
printf "[fallback_stop][rc=%s] %s\n" "${STOP_RC}" "${STOP_OUT}" >> "${LOG_FILE}" 2>&1
printf "[fallback_start][rc=%s] %s\n" "${START_RC}" "${START_OUT}" >> "${LOG_FILE}" 2>&1

if wait_for_probe "${TIMEOUT_SECONDS}"; then
  notify "Gateway restart complete: RPC probe OK (fallback stop/start)."
  echo "[restart] complete mode=fallback stop_rc=${STOP_RC} start_rc=${START_RC} at $(date -Iseconds)" >> "${LOG_FILE}" 2>&1
  exit 0
fi

notify "Gateway restart failed: RPC probe not ready after ${TIMEOUT_SECONDS}s."
echo "[restart] failed restart_rc=${RESTART_RC} stop_rc=${STOP_RC:-n/a} start_rc=${START_RC:-n/a} at $(date -Iseconds)" >> "${LOG_FILE}" 2>&1
exit 1
