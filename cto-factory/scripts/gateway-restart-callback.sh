#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="cto-factory"
CHAT_ID=""
TOPIC_ID=""
TIMEOUT_SECONDS=45
LOG_DIR="${HOME}/.openclaw/logs"

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
    --timeout)
      TIMEOUT_SECONDS="${2:-45}"
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

{
  echo "[restart] begin $(date -Iseconds)"
  echo "[restart] agent_id=${AGENT_ID}"
  echo "[restart] target chat=${CHAT_ID:-n/a} topic=${TOPIC_ID:-n/a}"
} >> "${LOG_FILE}" 2>&1

set +e
RESTART_OUT="$(run_openclaw_with_timeout 25 openclaw gateway restart 2>&1)"
RESTART_RC=$?
set -e
if [[ -n "${RESTART_OUT}" ]]; then
  printf "%s\n" "${RESTART_OUT}" >> "${LOG_FILE}" 2>&1
fi

ok=0
attempt=0
deadline_epoch="$(( $(date +%s) + TIMEOUT_SECONDS ))"
while [[ "$(date +%s)" -lt "${deadline_epoch}" ]]; do
  attempt="$((attempt + 1))"
  set +e
  STATUS_OUT="$(run_openclaw_with_timeout 2 openclaw gateway status 2>&1)"
  STATUS_RC=$?
  set -e
  if [[ -n "${STATUS_OUT}" ]]; then
    printf "[status][attempt=%s][rc=%s] %s\n" "${attempt}" "${STATUS_RC}" "${STATUS_OUT}" >> "${LOG_FILE}" 2>&1
  else
    printf "[status][attempt=%s][rc=%s] <empty>\n" "${attempt}" "${STATUS_RC}" >> "${LOG_FILE}" 2>&1
  fi
  if printf "%s" "${STATUS_OUT}" | grep -q "RPC probe: ok"; then
    ok=1
    break
  fi
  sleep 1
done

if [[ "${ok}" -eq 1 ]]; then
  notify "Gateway restart complete: RPC probe OK."
  echo "[restart] complete restart_rc=${RESTART_RC} at $(date -Iseconds)" >> "${LOG_FILE}" 2>&1
  exit 0
fi

notify "Gateway restart failed: RPC probe not ready after ${TIMEOUT_SECONDS}s."
echo "[restart] failed restart_rc=${RESTART_RC} at $(date -Iseconds)" >> "${LOG_FILE}" 2>&1
exit 1
