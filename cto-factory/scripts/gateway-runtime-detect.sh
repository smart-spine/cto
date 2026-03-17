#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
TIMEOUT_SECONDS="${1:-12}"

run_with_timeout() {
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

STATUS_OUT="$(run_with_timeout "${TIMEOUT_SECONDS}" openclaw gateway status 2>&1 || true)"
STATUS_RC=$?
PROBE_OUT="$(run_with_timeout "${TIMEOUT_SECONDS}" openclaw gateway probe 2>&1 || true)"
PROBE_RC=$?

SERVICE_LINE="$(printf '%s\n' "${STATUS_OUT}" | grep -m1 '^Service:' || true)"
RUNTIME_LINE="$(printf '%s\n' "${STATUS_OUT}" | grep -m1 '^Runtime:' || true)"
PROBE_TARGET_LINE="$(printf '%s\n' "${STATUS_OUT}" | grep -m1 '^Probe target:' || true)"

CONNECT_OK=false
RPC_OK=false
if printf '%s\n' "${PROBE_OUT}" | grep -q 'Connect: ok'; then
  CONNECT_OK=true
fi
if printf '%s\n' "${PROBE_OUT}" | grep -q 'RPC: ok'; then
  RPC_OK=true
fi

python3 - <<'PY' "${OPENCLAW_ROOT}" "${STATUS_RC}" "${PROBE_RC}" "${CONNECT_OK}" "${RPC_OK}" "${SERVICE_LINE}" "${RUNTIME_LINE}" "${PROBE_TARGET_LINE}" "${STATUS_OUT}" "${PROBE_OUT}"
import json
import sys

openclaw_root = sys.argv[1]
status_rc = int(sys.argv[2])
probe_rc = int(sys.argv[3])
connect_ok = sys.argv[4].lower() == "true"
rpc_ok = sys.argv[5].lower() == "true"
service_line = sys.argv[6]
runtime_line = sys.argv[7]
probe_target = sys.argv[8]
status_out = sys.argv[9]
probe_out = sys.argv[10]

payload = {
    "ok": True,
    "openclaw_root": openclaw_root,
    "status_rc": status_rc,
    "probe_rc": probe_rc,
    "service_line": service_line,
    "runtime_line": runtime_line,
    "probe_target": probe_target,
    "connect_ok": connect_ok,
    "rpc_ok": rpc_ok,
    "restart_tool": f"{openclaw_root}/workspace-factory/scripts/gateway-restart-callback.sh",
    "recommended_restart_command": (
        'OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}" '
        '&& nohup /usr/bin/env bash "$OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh" '
        '--agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-${OPENCLAW_SESSION_ID:-}}" >/dev/null 2>&1 &'
    ),
    "status_excerpt": "\n".join(status_out.splitlines()[:20]),
    "probe_excerpt": "\n".join(probe_out.splitlines()[:20]),
}
print(json.dumps(payload, ensure_ascii=False))
PY
