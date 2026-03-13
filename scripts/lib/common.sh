#!/usr/bin/env bash

set -euo pipefail

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

init_terminal_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
  else
    C_RESET=""
    C_BOLD=""
    C_CYAN=""
    C_GREEN=""
    C_YELLOW=""
  fi
}

init_terminal_colors

log_info() {
  printf "[%s] [INFO] %s\n" "$(timestamp_utc)" "$*"
}

log_warn() {
  printf "[%s] [WARN] %s\n" "$(timestamp_utc)" "$*" >&2
}

log_error() {
  printf "[%s] [ERROR] %s\n" "$(timestamp_utc)" "$*" >&2
}

user_section() {
  printf "\n%s%s%s\n" "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}"
}

user_step() {
  printf "%s%s%s\n" "${C_GREEN}" "$*" "${C_RESET}"
}

user_command() {
  printf "  %s%s%s\n" "${C_YELLOW}" "$*" "${C_RESET}"
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

sync_allowed_models_from_provider_catalog() {
  local config_path="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_HOME:-$HOME/.openclaw}/openclaw.json}"
  local providers_csv="${MODEL_PROVIDERS_ALLOWLIST:-openai,openai-codex}"
  local strict_mode="${MODEL_ALLOWLIST_STRICT:-true}"

  [[ -f "${config_path}" ]] || die "Cannot sync models: missing config ${config_path}"
  require_cmd python3
  require_cmd openclaw

  local sync_out=""
  if ! sync_out="$(python3 - "${config_path}" "${providers_csv}" "${strict_mode}" <<'PY'
import json
import pathlib
import subprocess
import sys

config_path = pathlib.Path(sys.argv[1])
providers = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
strict_mode = str(sys.argv[3]).strip().lower() in {"1", "true", "yes", "on"}

if not providers:
    raise SystemExit("MODEL_PROVIDERS_ALLOWLIST is empty.")

data = json.loads(config_path.read_text(encoding="utf-8"))
agents = data.setdefault("agents", {})
if isinstance(agents, list):
    agents = {"list": agents}
    data["agents"] = agents
defaults = agents.setdefault("defaults", {})
model_cfg = defaults.setdefault("model", {})
if not isinstance(model_cfg, dict):
    model_cfg = {}
    defaults["model"] = model_cfg
primary = str(model_cfg.get("primary") or "").strip()

existing_models = defaults.get("models")
if not isinstance(existing_models, dict):
    existing_models = {}

collected = []
missing = []

for provider in providers:
    cmd = ["openclaw", "models", "list", "--all", "--provider", provider, "--plain"]
    try:
        output = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        output = ""
    provider_models = []
    for raw in output.splitlines():
        item = raw.strip()
        if not item:
            continue
        if item.startswith(provider + "/"):
            provider_models.append(item)
    if provider_models:
        collected.extend(provider_models)
    else:
        missing.append(provider)

seen = set()
ordered = []
for model in collected:
    if model in seen:
        continue
    seen.add(model)
    ordered.append(model)

if primary and primary not in seen:
    ordered.insert(0, primary)
    seen.add(primary)

if not ordered:
    raise SystemExit("No models discovered for configured providers.")

new_models = {}
for model in ordered:
    prev = existing_models.get(model, {})
    if isinstance(prev, dict):
        new_models[model] = prev
    else:
        new_models[model] = {}

if strict_mode:
    prefixes = tuple(p + "/" for p in providers)
    new_models = {k: v for k, v in new_models.items() if k.startswith(prefixes)}
    if primary and primary not in new_models:
        new_models[primary] = {}

if not new_models:
    raise SystemExit("Model allowlist is empty after strict filtering.")

defaults["models"] = new_models
config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print(json.dumps({
    "count": len(new_models),
    "providers": providers,
    "missingProviders": missing,
    "strict": strict_mode
}))
PY
)"; then
    die "Failed to sync allowed models from provider catalog."
  fi

  local count
  count="$(printf "%s" "${sync_out}" | jq -r '.count // 0' 2>/dev/null || printf "0")"
  if [[ -z "${count}" || "${count}" == "0" ]]; then
    die "Model sync produced an empty allowlist."
  fi
  log_info "Synced ${count} allowed models from providers: ${providers_csv}."

  local missing
  missing="$(printf "%s" "${sync_out}" | jq -r '.missingProviders // [] | join(",")' 2>/dev/null || true)"
  if [[ -n "${missing}" && "${missing}" != "null" ]]; then
    log_warn "No models discovered for providers: ${missing}"
  fi
}
