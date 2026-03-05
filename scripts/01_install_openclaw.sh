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
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
SKIP_GATEWAY_START="${SKIP_GATEWAY_START:-false}"
SKIP_CODEX_LOGIN="${SKIP_CODEX_LOGIN:-false}"
SKIP_CODEX_HEALTHCHECK="${SKIP_CODEX_HEALTHCHECK:-false}"
CODEX_HEALTHCHECK_RETRIES="${CODEX_HEALTHCHECK_RETRIES:-3}"
SKIP_MAIN_AGENT_SMOKE="${SKIP_MAIN_AGENT_SMOKE:-false}"
GATEWAY_TOKEN_GENERATED="false"

cleanup_nodesource_repo() {
  # Remove NodeSource apt entries to avoid stale metadata blocking apt update.
  run_as_root rm -f \
    /etc/apt/sources.list.d/nodesource.list \
    /etc/apt/sources.list.d/nodesource.sources \
    /etc/apt/sources.list.d/nodesource.list.save \
    /etc/apt/keyrings/nodesource.gpg \
    /usr/share/keyrings/nodesource.gpg || true
}

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

apt_retry_soft() {
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
  return 1
}

install_node_22_tarball() {
  local arch uname_arch node_arch node_version tarball_url tmpdir
  uname_arch="$(uname -m)"
  case "${uname_arch}" in
    x86_64|amd64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    *)
      die "Unsupported CPU architecture for Node.js tarball: ${uname_arch}"
      ;;
  esac

  node_version="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r 'map(select(.version|startswith("v22.")))[0].version')"
  [[ -n "${node_version}" && "${node_version}" != "null" ]] || die "Failed to resolve latest Node.js v22 version."
  tarball_url="https://nodejs.org/dist/${node_version}/node-${node_version}-linux-${node_arch}.tar.xz"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  log_info "Installing Node.js ${node_version} from official tarball (${node_arch})."
  curl -fsSL "${tarball_url}" -o "${tmpdir}/node.tar.xz"
  run_as_root tar -xJf "${tmpdir}/node.tar.xz" -C /usr/local --strip-components=1
  rm -rf "${tmpdir}"
  trap - RETURN
}

install_node_22_nodesource() {
  local setup_log
  setup_log="$(mktemp)"
  trap 'rm -f "${setup_log}"' RETURN

  log_info "Installing Node.js 22 via NodeSource."
  cleanup_nodesource_repo
  if ! run_as_root bash -lc "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -" >"${setup_log}" 2>&1; then
    log_warn "NodeSource setup script failed."
    tail -n 20 "${setup_log}" >&2 || true
    rm -f "${setup_log}"
    trap - RETURN
    return 1
  fi
  rm -f "${setup_log}"
  trap - RETURN

  if ! apt_retry_soft update -qq; then
    return 1
  fi
  if ! apt_retry_soft install -y -qq nodejs; then
    return 1
  fi
  return 0
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
  if ! install_node_22_nodesource; then
    log_warn "NodeSource install failed. Falling back to official Node.js tarball."
    install_node_22_tarball
  fi

  if ! command -v node >/dev/null 2>&1; then
    die "Node.js installation failed: node binary not found."
  fi
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
  if [[ "${node_major}" != "22" ]]; then
    die "Node.js installation failed: expected major 22, got '${node_major:-unknown}'."
  fi
}

ensure_npm_available() {
  if command -v npm >/dev/null 2>&1; then
    return 0
  fi
  log_warn "npm not found after Node.js install. Attempting fallback apt install for npm."
  apt_retry install -y -qq npm || true
  require_cmd npm
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

  OPENCLAW_GATEWAY_TOKEN="$(generate_gateway_token)"
  GATEWAY_TOKEN_GENERATED="true"
  log_info "Generated OPENCLAW_GATEWAY_TOKEN automatically."
}

print_gateway_token_notice() {
  cat <<EOF

Gateway token is configured.

Token value:
${OPENCLAW_GATEWAY_TOKEN}

Stored in:
${OPENCLAW_HOME}/.env

Recommended next step:
- save this token in a password manager.

EOF
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

run_codex_healthcheck() {
  local retries attempt
  local hc_root="${OPENCLAW_HOME}/workspace/.codex-healthcheck"
  local hc_file="${hc_root}/probe.py"
  local hc_log=""

  retries="${CODEX_HEALTHCHECK_RETRIES}"
  if ! [[ "${retries}" =~ ^[0-9]+$ ]] || [[ "${retries}" -lt 1 ]]; then
    retries=3
  fi

  ensure_dir "${hc_root}"

  for attempt in $(seq 1 "${retries}"); do
    rm -f "${hc_file}" "${hc_root}/attempt-${attempt}.log"
    hc_log="${hc_root}/attempt-${attempt}.log"
    log_info "Codex healthcheck attempt ${attempt}/${retries}."

    if codex exec --ephemeral --skip-git-repo-check --sandbox workspace-write --cd "${hc_root}" \
      "Create a file named probe.py with exactly this content:
def _codex_ping():
    return \"ok\"

Do not modify any other files." >"${hc_log}" 2>&1; then
      if [[ -f "${hc_file}" ]] && grep -q '^def _codex_ping():' "${hc_file}" && grep -q 'return "ok"' "${hc_file}"; then
        log_info "Codex healthcheck passed."
        rm -rf "${hc_root}"
        return 0
      fi
      log_warn "Codex healthcheck command succeeded but probe file validation failed."
      tail -n 20 "${hc_log}" >&2 || true
    else
      log_warn "Codex healthcheck command failed."
      tail -n 20 "${hc_log}" >&2 || true
    fi

    sleep 3
  done

  rm -rf "${hc_root}"
  die "Codex healthcheck failed after ${retries} attempt(s)."
}

main() {
  log_info "Stage 1/9: Installing base packages."
  cleanup_nodesource_repo
  apt_retry update -qq
  apt_retry install -y -qq ca-certificates curl git jq python3 python3-venv gnupg lsb-release rsync

  log_info "Stage 2/9: Installing Node.js runtime."
  install_node_22
  require_cmd node
  ensure_npm_available
  require_cmd npm

  log_info "Stage 3/9: Installing OpenClaw CLI and Codex CLI."
  run_as_root npm install -g openclaw@latest @openai/codex
  require_cmd openclaw
  require_cmd codex

  log_info "Stage 4/9: Collecting secrets."
  prompt_secret OPENAI_API_KEY "Enter OPENAI_API_KEY"
  resolve_gateway_token

  log_info "Stage 5/9: Authenticating Codex CLI with OpenAI API key."
  if [[ "${SKIP_CODEX_LOGIN}" == "true" ]]; then
    log_warn "Skipping Codex login because SKIP_CODEX_LOGIN=true."
  elif ! printf "%s" "${OPENAI_API_KEY}" | codex login --with-api-key >/dev/null 2>&1; then
    die "Codex CLI authentication failed. Verify OPENAI_API_KEY and retry."
  fi

  log_info "Stage 6/9: Running Codex connectivity healthcheck."
  if [[ "${SKIP_CODEX_HEALTHCHECK}" == "true" ]]; then
    log_warn "Skipping Codex healthcheck because SKIP_CODEX_HEALTHCHECK=true."
  elif [[ "${SKIP_CODEX_LOGIN}" == "true" ]]; then
    log_warn "Skipping Codex healthcheck because SKIP_CODEX_LOGIN=true."
  else
    run_codex_healthcheck
  fi

  log_info "Stage 7/9: Writing OpenClaw runtime files."
  ensure_dir "${OPENCLAW_HOME}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENAI_API_KEY" "${OPENAI_API_KEY}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_GATEWAY_TOKEN" "${OPENCLAW_GATEWAY_TOKEN}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_PORT" "${OPENCLAW_PORT}"
  ensure_openclaw_config
  ensure_dir "${OPENCLAW_HOME}/workspace"
  ensure_dir "${OPENCLAW_HOME}/agents/main/agent"

  log_info "Stage 8/9: Validating OpenClaw config."
  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed."
  fi

  if [[ "${SKIP_GATEWAY_START}" != "true" ]]; then
    log_info "Stage 9/9: Starting gateway and running smoke test."
    restart_gateway_background
    if ! wait_for_gateway_health 90; then
      die "Gateway health check timed out. See ${OPENCLAW_HOME}/logs/gateway-run.log"
    fi
  else
    log_info "Stage 9/9: Gateway start skipped by SKIP_GATEWAY_START=true."
  fi

  if [[ "${SKIP_MAIN_AGENT_SMOKE}" == "true" ]]; then
    log_warn "Skipping main-agent smoke test because SKIP_MAIN_AGENT_SMOKE=true."
  else
    run_main_agent_smoke
  fi

  log_info "OpenClaw installation completed successfully."
  log_info "Gateway log: ${OPENCLAW_HOME}/logs/gateway-run.log"
  if [[ "${GATEWAY_TOKEN_GENERATED}" == "true" ]]; then
    print_gateway_token_notice
  fi
}

main "$@"
