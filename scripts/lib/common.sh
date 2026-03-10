#!/usr/bin/env bash

set -euo pipefail

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_info() {
  printf "[%s] [INFO] %s\n" "$(timestamp_utc)" "$*"
}

log_warn() {
  printf "[%s] [WARN] %s\n" "$(timestamp_utc)" "$*" >&2
}

log_error() {
  printf "[%s] [ERROR] %s\n" "$(timestamp_utc)" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    require_cmd sudo
    sudo "$@"
  fi
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local optional="${3:-false}"
  local non_interactive="${NON_INTERACTIVE:-false}"
  local current_value="${!var_name:-}"

  if [[ -n "${current_value}" ]]; then
    return 0
  fi

  if [[ "${non_interactive}" == "true" ]]; then
    if [[ "${optional}" == "true" ]]; then
      return 0
    fi
    die "Missing required environment variable: ${var_name} (NON_INTERACTIVE=true)"
  fi

  local entered=""
  if [[ "${optional}" == "true" ]]; then
    read -r -s -p "${prompt_text} (optional): " entered
    echo
  else
    while [[ -z "${entered}" ]]; do
      read -r -s -p "${prompt_text}: " entered
      echo
    done
  fi
  printf -v "${var_name}" "%s" "${entered}"
}

ensure_dir() {
  local dir_path="$1"
  mkdir -p "${dir_path}"
}

backup_file() {
  local file_path="$1"
  if [[ -f "${file_path}" ]]; then
    cp "${file_path}" "${file_path}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

upsert_env_var() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  ensure_dir "$(dirname "${env_file}")"
  touch "${env_file}"
  chmod 600 "${env_file}" || true
  python3 - "$env_file" "$key" "$value" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

lines = []
if path.exists():
    lines = path.read_text(encoding="utf-8").splitlines()

pattern = re.compile(rf"^{re.escape(key)}=")
updated = False
for i, line in enumerate(lines):
    if pattern.match(line):
        lines[i] = f"{key}={value}"
        updated = True
        break

if not updated:
    lines.append(f"{key}={value}")

path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

with_openclaw_env() {
  local openclaw_home="${OPENCLAW_HOME:-$HOME/.openclaw}"
  local env_file="${openclaw_home}/.env"
  export OPENCLAW_STATE_DIR="${openclaw_home}"
  export OPENCLAW_CONFIG_PATH="${openclaw_home}/openclaw.json"
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
  "$@"
}

stop_gateway_background() {
  local openclaw_home="${OPENCLAW_HOME:-$HOME/.openclaw}"
  local pid_file="${openclaw_home}/.gateway.pid"
  if with_openclaw_env openclaw health --json >/dev/null 2>&1; then
    with_openclaw_env openclaw gateway stop >/dev/null 2>&1 || true
    sleep 1
  fi
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
      sleep 1
      if kill -0 "${pid}" >/dev/null 2>&1; then
        kill -9 "${pid}" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "${pid_file}"
  fi
}

start_gateway_background() {
  local openclaw_home="${OPENCLAW_HOME:-$HOME/.openclaw}"
  local openclaw_port="${OPENCLAW_PORT:-18789}"
  ensure_dir "${openclaw_home}/logs"
  stop_gateway_background || true
  (
    cd "${openclaw_home}"
    export OPENCLAW_STATE_DIR="${openclaw_home}"
    export OPENCLAW_CONFIG_PATH="${openclaw_home}/openclaw.json"
    if [[ -f "${openclaw_home}/.env" ]]; then
      set -a
      # shellcheck disable=SC1090
      source "${openclaw_home}/.env"
      set +a
    fi
    nohup openclaw gateway run --port "${openclaw_port}" >"${openclaw_home}/logs/gateway-run.log" 2>&1 &
    echo $! > "${openclaw_home}/.gateway.pid"
  )
}

restart_gateway_background() {
  stop_gateway_background || true
  start_gateway_background
}

wait_for_gateway_health() {
  local timeout_seconds="${1:-60}"
  local start_epoch
  start_epoch="$(date +%s)"
  while true; do
    if with_openclaw_env openclaw health --json >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start_epoch >= timeout_seconds )); then
      return 1
    fi
    sleep 1
  done
}
