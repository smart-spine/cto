#!/usr/bin/env bash

set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [[ -n "${SCRIPT_SOURCE}" && "${SCRIPT_SOURCE}" != "bash" && "${SCRIPT_SOURCE}" != "-" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
elif [[ -f "./scripts/lib/common.sh" ]]; then
  SCRIPT_DIR="$(cd "./scripts" && pwd)"
elif [[ -f "./lib/common.sh" ]]; then
  SCRIPT_DIR="$(pwd)"
else
  echo "[ERROR] Could not resolve script directory. Run from repo root: ./scripts/01_install_openclaw.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
GATEWAY_TOKEN_MODE="${GATEWAY_TOKEN_MODE:-prompt}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
SKIP_GATEWAY_START="${SKIP_GATEWAY_START:-false}"
SKIP_CODEX_LOGIN="${SKIP_CODEX_LOGIN:-false}"
SKIP_MAIN_AGENT_SMOKE="${SKIP_MAIN_AGENT_SMOKE:-false}"

apt_retry() {
  local attempt=1
  local max_attempts=5
  local delay=5
  while (( attempt <= max_attempts )); do
    if run_as_root apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=5 "$@"; then
      return 0
    fi
    if (( attempt == max_attempts )); then
      break
    fi
    log_warn "apt-get failed (attempt ${attempt}/${max_attempts}), retrying in ${delay}s"
    sleep "${delay}"
    attempt=$((attempt + 1))
  done
  die "apt-get failed after ${max_attempts} attempts: apt-get $*"
}

install_node_22() {
  local node_major=""
  if command -v node >/dev/null 2>&1; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
  fi
  if [[ "${node_major}" == "22" ]]; then
    log_info "Node.js 22 is already installed."
    return 0
  fi
  log_info "Installing Node.js 22."
  run_as_root bash -lc "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
  apt_retry install -y -qq nodejs
}

generate_gateway_token() {
  local token=""
  if command -v openssl >/dev/null 2>&1; then
    token="$(openssl rand -hex 32 2>/dev/null || true)"
  fi
  if [[ -z "${token}" ]]; then
    token="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
  fi
  [[ -n "${token}" ]] || die "Failed to generate OPENCLAW_GATEWAY_TOKEN."
  printf "%s" "${token}"
}

resolve_gateway_token() {
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN}" ]]; then
    log_info "Using OPENCLAW_GATEWAY_TOKEN from environment."
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    case "${GATEWAY_TOKEN_MODE}" in
      auto|prompt|"")
        OPENCLAW_GATEWAY_TOKEN="$(generate_gateway_token)"
        log_info "Generated OPENCLAW_GATEWAY_TOKEN automatically (non-interactive mode)."
        ;;
      manual)
        die "GATEWAY_TOKEN_MODE=manual requires OPENCLAW_GATEWAY_TOKEN to be set."
        ;;
      *)
        die "Invalid GATEWAY_TOKEN_MODE='${GATEWAY_TOKEN_MODE}'. Use: prompt, auto, or manual."
        ;;
    esac
    return 0
  fi

  case "${GATEWAY_TOKEN_MODE}" in
    auto)
      OPENCLAW_GATEWAY_TOKEN="$(generate_gateway_token)"
      log_info "Generated OPENCLAW_GATEWAY_TOKEN automatically."
      ;;
    manual)
      prompt_secret OPENCLAW_GATEWAY_TOKEN "Enter OPENCLAW_GATEWAY_TOKEN"
      ;;
    prompt|"")
      echo "Choose OPENCLAW_GATEWAY_TOKEN setup:"
      echo "  1) Auto-generate now (recommended)"
      echo "  2) Enter manually"
      local choice=""
      read -r -p "Choice [1/2] (default 1): " choice
      if [[ "${choice}" == "2" ]]; then
        prompt_secret OPENCLAW_GATEWAY_TOKEN "Enter OPENCLAW_GATEWAY_TOKEN"
      else
        OPENCLAW_GATEWAY_TOKEN="$(generate_gateway_token)"
        log_info "Generated OPENCLAW_GATEWAY_TOKEN automatically."
      fi
      ;;
    *)
      die "Invalid GATEWAY_TOKEN_MODE='${GATEWAY_TOKEN_MODE}'. Use: prompt, auto, or manual."
      ;;
  esac
}

ensure_openclaw_config() {
  local config_path="${OPENCLAW_HOME}/openclaw.json"
  ensure_dir "${OPENCLAW_HOME}"
  backup_file "${config_path}"
  python3 - "${config_path}" "${OPENCLAW_HOME}" "${OPENCLAW_PORT}" "${OPENCLAW_GATEWAY_TOKEN}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
openclaw_home = pathlib.Path(sys.argv[2])
port = int(sys.argv[3])
gateway_token = sys.argv[4]

if config_path.exists():
    data = json.loads(config_path.read_text(encoding="utf-8"))
else:
    data = {}

gateway = data.setdefault("gateway", {})
gateway.setdefault("mode", "local")
gateway.setdefault("bind", "loopback")
gateway["port"] = port
gateway.setdefault("auth", {"mode": "token", "token": gateway_token})
if isinstance(gateway.get("auth"), dict):
    gateway["auth"].setdefault("mode", "token")
    gateway["auth"].setdefault("token", gateway_token)

auth = data.setdefault("auth", {})
profiles = auth.setdefault("profiles", {})
profiles.setdefault("openai:main", {"provider": "openai", "mode": "api_key"})
order = auth.setdefault("order", {})
openai_order = order.setdefault("openai", [])
if "openai:main" not in openai_order:
    openai_order.append("openai:main")

agents = data.setdefault("agents", {})
if isinstance(agents, list):
    agents = {"list": agents}
    data["agents"] = agents

defaults = agents.setdefault("defaults", {})
default_model = defaults.setdefault("model", {})
if not isinstance(default_model, dict):
    defaults["model"] = {"primary": "openai/gpt-5.2"}
else:
    default_model.setdefault("primary", "openai/gpt-5.2")

agent_list = agents.setdefault("list", [])
main_agent = None
for agent in agent_list:
    if isinstance(agent, dict) and agent.get("id") == "main":
        main_agent = agent
        break

if main_agent is None:
    main_agent = {
        "id": "main",
        "default": True,
        "name": "Main Agent",
        "workspace": str(openclaw_home / "workspace"),
        "agentDir": str(openclaw_home / "agents/main/agent"),
        "identity": {"name": "Main Agent"},
    }
    agent_list.append(main_agent)
else:
    main_agent.setdefault("default", True)
    main_agent.setdefault("name", "Main Agent")
    main_agent.setdefault("workspace", str(openclaw_home / "workspace"))
    main_agent.setdefault("agentDir", str(openclaw_home / "agents/main/agent"))
    main_agent.setdefault("identity", {"name": "Main Agent"})

data.setdefault("bindings", [])

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

run_main_agent_smoke() {
  local output
  output="$(with_openclaw_env openclaw agent --local --agent main --message "Reply with OPENCLAW_OK only" --json --timeout 180 2>&1 || true)"
  if ! printf "%s" "${output}" | grep -q "OPENCLAW_OK"; then
    printf "%s\n" "${output}" >&2
    die "Main agent smoke test failed: expected OPENCLAW_OK marker."
  fi
}

main() {
  log_info "Stage 1/8: Installing base packages."
  apt_retry update -qq
  apt_retry install -y -qq ca-certificates curl git jq python3 python3-venv gnupg lsb-release rsync

  log_info "Stage 2/8: Installing Node.js runtime."
  install_node_22
  require_cmd npm

  log_info "Stage 3/8: Installing OpenClaw CLI and Codex CLI."
  run_as_root npm install -g openclaw@latest @openai/codex
  require_cmd openclaw
  require_cmd codex

  log_info "Stage 4/8: Collecting secrets."
  prompt_secret OPENAI_API_KEY "Enter OPENAI_API_KEY"
  resolve_gateway_token

  log_info "Stage 5/8: Authenticating Codex CLI with OpenAI API key."
  if [[ "${SKIP_CODEX_LOGIN}" == "true" ]]; then
    log_warn "Skipping Codex login because SKIP_CODEX_LOGIN=true."
  elif ! printf "%s" "${OPENAI_API_KEY}" | codex login --with-api-key >/dev/null 2>&1; then
    die "Codex CLI authentication failed. Verify OPENAI_API_KEY and retry."
  fi

  log_info "Stage 6/8: Writing OpenClaw runtime files."
  ensure_dir "${OPENCLAW_HOME}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENAI_API_KEY" "${OPENAI_API_KEY}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_GATEWAY_TOKEN" "${OPENCLAW_GATEWAY_TOKEN}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_PORT" "${OPENCLAW_PORT}"
  ensure_openclaw_config
  ensure_dir "${OPENCLAW_HOME}/workspace"
  ensure_dir "${OPENCLAW_HOME}/agents/main/agent"

  log_info "Stage 7/8: Validating OpenClaw config."
  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed."
  fi

  if [[ "${SKIP_GATEWAY_START}" != "true" ]]; then
    log_info "Stage 8/8: Starting gateway and running smoke test."
    restart_gateway_background
    if ! wait_for_gateway_health 90; then
      die "Gateway health check timed out. See ${OPENCLAW_HOME}/logs/gateway-run.log"
    fi
  else
    log_info "Stage 8/8: Gateway start skipped by SKIP_GATEWAY_START=true."
  fi

  if [[ "${SKIP_MAIN_AGENT_SMOKE}" == "true" ]]; then
    log_warn "Skipping main-agent smoke test because SKIP_MAIN_AGENT_SMOKE=true."
  else
    run_main_agent_smoke
  fi

  log_info "OpenClaw installation completed successfully."
  log_info "Gateway log: ${OPENCLAW_HOME}/logs/gateway-run.log"
}

main "$@"
