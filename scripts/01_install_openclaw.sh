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
OPENCLAW_AGENT_TIMEOUT_SECONDS="${OPENCLAW_AGENT_TIMEOUT_SECONDS:-3600}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
OPENCLAW_RUNTIME_SETUP_TOKEN="${OPENCLAW_RUNTIME_SETUP_TOKEN:-}"
RUNTIME_PROVIDER="${RUNTIME_PROVIDER:-}"
RUNTIME_AUTH_METHOD="${RUNTIME_AUTH_METHOD:-}"
RUNTIME_PROVIDER_ID=""
RUNTIME_PROFILE_ID=""
RUNTIME_AUTH_MODE=""
RUNTIME_DEFAULT_MODEL=""
RUNTIME_TARGET_MODEL=""
RUNTIME_DEFER_MODEL_PRIMARY="false"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
SKIP_GATEWAY_START="${SKIP_GATEWAY_START:-false}"
SKIP_CODEX_LOGIN="${SKIP_CODEX_LOGIN:-false}"
SKIP_CODEX_HEALTHCHECK="${SKIP_CODEX_HEALTHCHECK:-false}"
CODEX_HEALTHCHECK_RETRIES="${CODEX_HEALTHCHECK_RETRIES:-3}"
SKIP_CODE_AGENT_LOGIN="${SKIP_CODE_AGENT_LOGIN:-${SKIP_CODEX_LOGIN}}"
SKIP_CODE_AGENT_HEALTHCHECK="${SKIP_CODE_AGENT_HEALTHCHECK:-${SKIP_CODEX_HEALTHCHECK}}"
CODE_AGENT_HEALTHCHECK_RETRIES="${CODE_AGENT_HEALTHCHECK_RETRIES:-${CODEX_HEALTHCHECK_RETRIES}}"
CODE_AGENT_CLI="${CODE_AGENT_CLI:-}"
CODE_AGENT_AUTH_METHOD="${CODE_AGENT_AUTH_METHOD:-}"
SKIP_MAIN_AGENT_SMOKE="${SKIP_MAIN_AGENT_SMOKE:-false}"
MODEL_PROVIDERS_ALLOWLIST_DEFAULT="openai,openai-codex"
MODEL_PROVIDERS_ALLOWLIST="${MODEL_PROVIDERS_ALLOWLIST:-${MODEL_PROVIDERS_ALLOWLIST_DEFAULT}}"
MODEL_ALLOWLIST_STRICT="${MODEL_ALLOWLIST_STRICT:-true}"
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
    if run_as_root env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true TZ=Etc/UTC NEEDRESTART_MODE=a \
      apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=5 "$@"; then
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
    if run_as_root env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true TZ=Etc/UTC NEEDRESTART_MODE=a \
      apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=5 "$@"; then
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
  if ! run_as_root env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true TZ=Etc/UTC NEEDRESTART_MODE=a \
    bash -lc "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -" >"${setup_log}" 2>&1; then
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

has_inline_menu() {
  [[ -t 0 ]] && [[ -t 1 ]] && command -v tput >/dev/null 2>&1
}

inline_menu_select() {
  # Usage:
  #   inline_menu_select "Prompt" "value1|Label 1" "value2|Label 2"
  # Returns selected value to stdout.
  local prompt="$1"
  shift
  local -a entries=("$@")
  local -a values=()
  local -a labels=()
  local i=0
  for i in "${!entries[@]}"; do
    values+=("${entries[$i]%%|*}")
    labels+=("${entries[$i]#*|}")
  done

  local selected=0
  local key=""
  local esc=""
  local c1=""
  local c2=""
  local line_count=$(( ${#labels[@]} + 2 ))

  tput civis >&2 || true
  trap 'tput cnorm >/dev/null 2>&1 || true' RETURN

  while true; do
    printf "\r%s\n" "${prompt}" >&2
    for i in "${!labels[@]}"; do
      if [[ "${i}" -eq "${selected}" ]]; then
        printf "  %s %s\n" ">" "${labels[$i]}" >&2
      else
        printf "    %s\n" "${labels[$i]}" >&2
      fi
    done
    printf "  (Use ↑/↓ and Enter)\n" >&2

    IFS= read -rsn1 key
    if [[ "${key}" == "" ]]; then
      break
    fi

    if [[ "${key}" == $'\x1b' ]]; then
      IFS= read -rsn1 -t 0.1 c1 || true
      IFS= read -rsn1 -t 0.1 c2 || true
      esc="${c1}${c2}"
      case "${esc}" in
        "[A")
          if [[ "${selected}" -gt 0 ]]; then
            selected=$((selected - 1))
          fi
          ;;
        "[B")
          if [[ "${selected}" -lt $(( ${#labels[@]} - 1 )) ]]; then
            selected=$((selected + 1))
          fi
          ;;
      esac
    elif [[ "${key}" == "k" ]]; then
      if [[ "${selected}" -gt 0 ]]; then
        selected=$((selected - 1))
      fi
    elif [[ "${key}" == "j" ]]; then
      if [[ "${selected}" -lt $(( ${#labels[@]} - 1 )) ]]; then
        selected=$((selected + 1))
      fi
    fi

    printf "\033[%dA" "${line_count}" >&2
  done

  printf "\033[%dA" "${line_count}" >&2
  printf "\033[J" >&2
  printf "%s %s\n" "${prompt}" "${labels[$selected]}" >&2

  printf "%s" "${values[$selected]}"
}

validate_code_agent_cli() {
  case "${1}" in
    codex|claude) return 0 ;;
    *) die "Invalid CODE_AGENT_CLI='${1}'. Allowed values: codex, claude." ;;
  esac
}

validate_code_agent_auth_method() {
  case "${1}" in
    api_key|subscription) return 0 ;;
    *) die "Invalid CODE_AGENT_AUTH_METHOD='${1}'. Allowed values: api_key, subscription." ;;
  esac
}

validate_runtime_provider() {
  case "${1}" in
    openai|anthropic) return 0 ;;
    *) die "Invalid RUNTIME_PROVIDER='${1}'. Allowed values: openai, anthropic." ;;
  esac
}

validate_runtime_auth_method() {
  local provider="$1"
  local method="$2"
  case "${provider}" in
    openai)
      case "${method}" in
        api_key|codex) return 0 ;;
      esac
      die "Invalid RUNTIME_AUTH_METHOD='${method}' for provider=openai. Allowed: api_key, codex."
      ;;
    anthropic)
      case "${method}" in
        api_key|oauth) return 0 ;;
      esac
      die "Invalid RUNTIME_AUTH_METHOD='${method}' for provider=anthropic. Allowed: api_key, oauth."
      ;;
    *)
      die "Unsupported runtime provider: ${provider}"
      ;;
  esac
}

resolve_runtime_profile_settings() {
  case "${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}" in
    openai:api_key)
      RUNTIME_PROVIDER_ID="openai"
      RUNTIME_PROFILE_ID="openai:api-key"
      RUNTIME_AUTH_MODE="api_key"
      RUNTIME_DEFAULT_MODEL="openai/gpt-5.2"
      RUNTIME_TARGET_MODEL="${RUNTIME_DEFAULT_MODEL}"
      RUNTIME_DEFER_MODEL_PRIMARY="false"
      ;;
    openai:codex)
      RUNTIME_PROVIDER_ID="openai-codex"
      RUNTIME_PROFILE_ID="openai-codex:oauth"
      RUNTIME_AUTH_MODE="token"
      RUNTIME_DEFAULT_MODEL="openai-codex/gpt-5.4"
      RUNTIME_TARGET_MODEL="${RUNTIME_DEFAULT_MODEL}"
      RUNTIME_DEFER_MODEL_PRIMARY="false"
      ;;
    anthropic:api_key)
      RUNTIME_PROVIDER_ID="anthropic"
      RUNTIME_PROFILE_ID="anthropic:api-key"
      RUNTIME_AUTH_MODE="api_key"
      RUNTIME_DEFAULT_MODEL="anthropic/claude-sonnet-4-5"
      RUNTIME_TARGET_MODEL="${RUNTIME_DEFAULT_MODEL}"
      RUNTIME_DEFER_MODEL_PRIMARY="false"
      ;;
    anthropic:oauth)
      RUNTIME_PROVIDER_ID="anthropic"
      RUNTIME_PROFILE_ID="anthropic:oauth"
      RUNTIME_AUTH_MODE="token"
      # Workaround: keep bootstrap model non-anthropic during setup-token auth,
      # then switch primary model to anthropic after runtime auth succeeds.
      RUNTIME_DEFAULT_MODEL="openai/gpt-5.2"
      RUNTIME_TARGET_MODEL="anthropic/claude-sonnet-4-5"
      RUNTIME_DEFER_MODEL_PRIMARY="true"
      ;;
    *)
      die "Unsupported runtime provider/auth combination: ${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}"
      ;;
  esac
}

choose_runtime_provider() {
  if [[ -n "${RUNTIME_PROVIDER}" ]]; then
    validate_runtime_provider "${RUNTIME_PROVIDER}"
    log_info "Using RUNTIME_PROVIDER=${RUNTIME_PROVIDER} from environment."
    return 0
  fi

  user_section "OpenClaw Runtime Setup"
  user_step "Select runtime provider."

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    RUNTIME_PROVIDER="openai"
    log_info "NON_INTERACTIVE=true -> defaulting RUNTIME_PROVIDER=openai."
    return 0
  fi

  if has_inline_menu; then
    local choice=""
    choice="$(inline_menu_select "Runtime provider:" \
      "openai|OpenAI" \
      "anthropic|Anthropic")"
    RUNTIME_PROVIDER="${choice}"
  else
    echo "Select OpenClaw runtime provider:"
    echo "  1) OpenAI"
    echo "  2) Anthropic"
    local choice=""
    read -r -p "Choice [1/2] (default 1): " choice
    if [[ "${choice}" == "2" ]]; then
      RUNTIME_PROVIDER="anthropic"
    else
      RUNTIME_PROVIDER="openai"
    fi
  fi

  validate_runtime_provider "${RUNTIME_PROVIDER}"
}

choose_runtime_auth_method() {
  if [[ -n "${RUNTIME_AUTH_METHOD}" ]]; then
    validate_runtime_auth_method "${RUNTIME_PROVIDER}" "${RUNTIME_AUTH_METHOD}"
    log_info "Using RUNTIME_AUTH_METHOD=${RUNTIME_AUTH_METHOD} from environment."
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    RUNTIME_AUTH_METHOD="api_key"
    log_info "NON_INTERACTIVE=true -> defaulting RUNTIME_AUTH_METHOD=api_key."
    return 0
  fi

  local option_a=""
  local option_b=""
  case "${RUNTIME_PROVIDER}" in
    openai)
      option_a="api_key|OpenAI API key"
      option_b="codex|ChatGPT/Codex OAuth (subscription)"
      ;;
    anthropic)
      option_a="api_key|Anthropic API key"
      option_b="oauth|Anthropic setup-token (OAuth-like)"
      ;;
    *)
      die "Unsupported runtime provider for auth selection: ${RUNTIME_PROVIDER}"
      ;;
  esac

  user_step "Select runtime authentication method."
  if has_inline_menu; then
    local choice=""
    choice="$(inline_menu_select "Runtime auth:" "${option_a}" "${option_b}")"
    RUNTIME_AUTH_METHOD="${choice}"
  else
    echo "Select runtime authentication method:"
    echo "  1) API key"
    if [[ "${RUNTIME_PROVIDER}" == "openai" ]]; then
      echo "  2) Codex OAuth (ChatGPT subscription)"
    else
      echo "  2) setup-token (subscription)"
    fi
    local choice=""
    read -r -p "Choice [1/2] (default 1): " choice
    if [[ "${choice}" == "2" ]]; then
      if [[ "${RUNTIME_PROVIDER}" == "openai" ]]; then
        RUNTIME_AUTH_METHOD="codex"
      else
        RUNTIME_AUTH_METHOD="oauth"
      fi
    else
      RUNTIME_AUTH_METHOD="api_key"
    fi
  fi

  validate_runtime_auth_method "${RUNTIME_PROVIDER}" "${RUNTIME_AUTH_METHOD}"
}

configure_runtime_model_allowlist() {
  # Respect explicit override. Auto-adjust only when still on default.
  if [[ "${MODEL_PROVIDERS_ALLOWLIST}" == "${MODEL_PROVIDERS_ALLOWLIST_DEFAULT}" ]]; then
    MODEL_PROVIDERS_ALLOWLIST="${RUNTIME_PROVIDER_ID}"
    log_info "Using MODEL_PROVIDERS_ALLOWLIST=${MODEL_PROVIDERS_ALLOWLIST} based on selected runtime provider."
  fi
}

choose_runtime_provider_and_auth() {
  choose_runtime_provider
  choose_runtime_auth_method
  validate_runtime_provider "${RUNTIME_PROVIDER}"
  validate_runtime_auth_method "${RUNTIME_PROVIDER}" "${RUNTIME_AUTH_METHOD}"
  resolve_runtime_profile_settings
  configure_runtime_model_allowlist
}

choose_code_agent_cli() {
  if [[ -n "${CODE_AGENT_CLI}" ]]; then
    validate_code_agent_cli "${CODE_AGENT_CLI}"
    log_info "Using CODE_AGENT_CLI=${CODE_AGENT_CLI} from environment."
    return 0
  fi

  user_section "Code Agent Setup"
  user_step "Select coding CLI."

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    CODE_AGENT_CLI="codex"
    log_info "NON_INTERACTIVE=true -> defaulting CODE_AGENT_CLI=codex."
    return 0
  fi

  if has_inline_menu; then
    local choice=""
    choice="$(inline_menu_select "Coding CLI:" \
      "codex|OpenAI Codex CLI" \
      "claude|Anthropic Claude Code CLI")"
    CODE_AGENT_CLI="${choice}"
  else
    echo "Select coding CLI:"
    echo "  1) Codex (OpenAI)"
    echo "  2) Claude Code (Anthropic)"
    local choice=""
    read -r -p "Choice [1/2] (default 1): " choice
    if [[ "${choice}" == "2" ]]; then
      CODE_AGENT_CLI="claude"
    else
      CODE_AGENT_CLI="codex"
    fi
  fi

  validate_code_agent_cli "${CODE_AGENT_CLI}"
}

choose_code_agent_auth_method() {
  if [[ -n "${CODE_AGENT_AUTH_METHOD}" ]]; then
    validate_code_agent_auth_method "${CODE_AGENT_AUTH_METHOD}"
    log_info "Using CODE_AGENT_AUTH_METHOD=${CODE_AGENT_AUTH_METHOD} from environment."
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    CODE_AGENT_AUTH_METHOD="api_key"
    log_info "NON_INTERACTIVE=true -> defaulting CODE_AGENT_AUTH_METHOD=api_key."
    return 0
  fi

  local subscription_label api_key_label
  if [[ "${CODE_AGENT_CLI}" == "codex" ]]; then
    subscription_label="ChatGPT Plus/Pro login (browser/device flow)"
    api_key_label="OpenAI API key"
  else
    subscription_label="Claude subscription login (Anthropic account)"
    api_key_label="Anthropic API key"
  fi

  user_step "Select authentication method."
  if has_inline_menu; then
    local choice=""
    choice="$(inline_menu_select "Auth method:" \
      "subscription|${subscription_label}" \
      "api_key|${api_key_label}")"
    CODE_AGENT_AUTH_METHOD="${choice}"
  else
    echo "Authentication method:"
    echo "  1) Subscription login"
    echo "  2) API key"
    local choice=""
    read -r -p "Choice [1/2] (default 1): " choice
    if [[ "${choice}" == "2" ]]; then
      CODE_AGENT_AUTH_METHOD="api_key"
    else
      CODE_AGENT_AUTH_METHOD="subscription"
    fi
  fi

  validate_code_agent_auth_method "${CODE_AGENT_AUTH_METHOD}"

  if [[ "${NON_INTERACTIVE}" == "true" && "${CODE_AGENT_AUTH_METHOD}" == "subscription" ]]; then
    die "Subscription login is interactive. Use CODE_AGENT_AUTH_METHOD=api_key for NON_INTERACTIVE=true."
  fi
}

install_selected_code_agent_cli() {
  local -a packages=()
  case "${CODE_AGENT_CLI}" in
    codex)
      packages=(openclaw@latest @openai/codex)
      npm_global_install_with_retry "${packages[@]}"
      require_cmd openclaw
      require_cmd codex
      ;;
    claude)
      packages=(openclaw@latest @anthropic-ai/claude-code)
      npm_global_install_with_retry "${packages[@]}"
      require_cmd openclaw
      require_cmd claude
      ;;
    *)
      die "Unsupported code agent CLI: ${CODE_AGENT_CLI}"
      ;;
  esac
}

cleanup_stale_npm_temp_dirs() {
  local npm_root=""
  npm_root="$(npm root -g 2>/dev/null || true)"
  if [[ -z "${npm_root}" || ! -d "${npm_root}" ]]; then
    return 0
  fi
  # npm leaves hidden temp folders like .openclaw-abc123 on interrupted upgrades.
  run_as_root find "${npm_root}" -maxdepth 2 -mindepth 1 -type d -name '.*-*' -exec rm -rf {} + >/dev/null 2>&1 || true
}

npm_global_install_with_retry() {
  local -a specs=("$@")
  local attempt=1
  local max_attempts=3
  while (( attempt <= max_attempts )); do
    if run_as_root npm install -g "${specs[@]}"; then
      return 0
    fi
    if (( attempt == max_attempts )); then
      break
    fi
    log_warn "npm global install failed (attempt ${attempt}/${max_attempts}); cleaning stale npm temp dirs and retrying."
    cleanup_stale_npm_temp_dirs
    sleep 2
    attempt=$((attempt + 1))
  done
  die "npm global install failed after ${max_attempts} attempts: npm install -g ${specs[*]}"
}

extract_claude_oauth_token_from_log() {
  local log_path="$1"
  [[ -f "${log_path}" ]] || return 1
  local cleaned=""
  local token=""
  local raw=""
  cleaned="$(tr -d '\r' <"${log_path}" | sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g')"

  # Preferred path: capture the real OAuth token, including wrapped lines.
  token="$(
    printf "%s\n" "${cleaned}" | awk '
      BEGIN { collect=0; tok="" }
      {
        line=$0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (collect == 1) {
          if (line ~ /^[A-Za-z0-9._-]+$/) {
            tok = tok line
            next
          }
          collect = 0
        }
        if (line ~ /^sk-ant-oat[A-Za-z0-9._-]*$/) {
          tok = line
          collect = 1
          next
        }
      }
      END {
        if (tok != "") {
          print tok
        }
      }
    ' | tail -n1 || true
  )"
  if [[ -n "${token}" ]]; then
    printf "%s" "${token}"
    return 0
  fi

  # Fallback path: capture assignment form (can be placeholder).
  raw="$(printf "%s\n" "${cleaned}" | grep -oE 'CLAUDE_CODE_OAUTH_TOKEN=[^[:space:]]+' | tail -n1 || true)"
  if [[ -z "${raw}" ]]; then
    return 1
  fi
  token="${raw#CLAUDE_CODE_OAUTH_TOKEN=}"
  if [[ "${token}" == "<token>" ]]; then
    return 1
  fi
  printf "%s" "${token}"
}

normalize_claude_oauth_token_input() {
  local token="$1"
  token="$(printf "%s" "${token}" | tr -d '\r\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  token="${token#export }"
  token="${token#CLAUDE_CODE_OAUTH_TOKEN=}"
  token="${token%\"}"
  token="${token#\"}"
  printf "%s" "${token}"
}

is_valid_claude_oauth_token() {
  local token="$1"
  [[ "${token}" =~ ^sk-ant-oat[0-9A-Za-z._-]+$ ]]
}

probe_claude_oauth_token_live() {
  local token="$1"
  local out=""
  out="$(CLAUDE_CODE_OAUTH_TOKEN="${token}" claude -p "Reply exactly: CLAUDE_AUTH_OK" --output-format text --permission-mode default 2>&1 || true)"
  if printf "%s" "${out}" | grep -q "CLAUDE_AUTH_OK"; then
    return 0
  fi
  printf "%s\n" "${out}" >&2
  return 1
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
  python3 - "${config_path}" "${OPENCLAW_HOME}" "${OPENCLAW_PORT}" "${OPENCLAW_GATEWAY_TOKEN}" "${OPENCLAW_AGENT_TIMEOUT_SECONDS}" "${RUNTIME_PROVIDER_ID}" "${RUNTIME_PROFILE_ID}" "${RUNTIME_AUTH_MODE}" "${RUNTIME_DEFAULT_MODEL}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
openclaw_home = pathlib.Path(sys.argv[2])
port = int(sys.argv[3])
gateway_token = sys.argv[4]
agent_timeout_seconds = int(sys.argv[5])
runtime_provider_id = sys.argv[6]
runtime_profile_id = sys.argv[7]
runtime_auth_mode = sys.argv[8]
runtime_default_model = sys.argv[9]

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
profile = profiles.get(runtime_profile_id)
if not isinstance(profile, dict):
    profiles[runtime_profile_id] = {"provider": runtime_provider_id, "mode": runtime_auth_mode}
else:
    profile["provider"] = runtime_provider_id
    profile["mode"] = runtime_auth_mode

order = auth.setdefault("order", {})
provider_order = order.setdefault(runtime_provider_id, [])
if runtime_profile_id not in provider_order:
    provider_order.append(runtime_profile_id)

agents = data.setdefault("agents", {})
if isinstance(agents, list):
    agents = {"list": agents}
    data["agents"] = agents

defaults = agents.setdefault("defaults", {})
default_model = defaults.setdefault("model", {})
if not isinstance(default_model, dict):
    defaults["model"] = {"primary": runtime_default_model}
else:
    existing_primary = str(default_model.get("primary") or "").strip()
    bootstrap_default_models = {
        "openai/gpt-5.2",
        "openai-codex/gpt-5.4",
        "anthropic/claude-sonnet-4-5",
    }
    if not existing_primary or existing_primary in bootstrap_default_models:
        default_model["primary"] = runtime_default_model
try:
    existing_timeout = int(defaults.get("timeoutSeconds") or 0)
except Exception:
    existing_timeout = 0
defaults["timeoutSeconds"] = max(existing_timeout, agent_timeout_seconds, 3600)

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

apply_runtime_target_model_primary() {
  if [[ -z "${RUNTIME_TARGET_MODEL}" ]]; then
    return 0
  fi
  python3 - "${OPENCLAW_HOME}/openclaw.json" "${RUNTIME_TARGET_MODEL}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
target_model = sys.argv[2]

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

existing = str(model_cfg.get("primary") or "").strip()
bootstrap_defaults = {"openai/gpt-5.2", "openai-codex/gpt-5.4", "anthropic/claude-sonnet-4-5"}
if not existing or existing in bootstrap_defaults:
    model_cfg["primary"] = target_model

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

run_runtime_auth_probe() {
  local marker="RUNTIME_AUTH_OK"
  local output=""
  output="$(with_openclaw_env openclaw agent --local --agent main --message "Reply with ${marker} only" --json --timeout 180 2>&1 || true)"
  if printf "%s" "${output}" | grep -q "${marker}"; then
    return 0
  fi
  printf "%s\n" "${output}" >&2
  return 1
}

run_claude_setup_token_and_capture() {
  local setup_log=""
  local extracted_token=""
  if command -v script >/dev/null 2>&1; then
    setup_log="$(mktemp)"
    if ! script -q -e -c "claude setup-token" "${setup_log}"; then
      rm -f "${setup_log}"
      return 1
    fi
    extracted_token="$(extract_claude_oauth_token_from_log "${setup_log}" || true)"
    rm -f "${setup_log}"
    extracted_token="$(normalize_claude_oauth_token_input "${extracted_token}")"
    if [[ -n "${extracted_token}" ]] && is_valid_claude_oauth_token "${extracted_token}"; then
      OPENCLAW_RUNTIME_SETUP_TOKEN="${extracted_token}"
    fi
  else
    claude setup-token || return 1
  fi
  return 0
}

resolve_runtime_setup_token() {
  OPENCLAW_RUNTIME_SETUP_TOKEN="$(normalize_claude_oauth_token_input "${OPENCLAW_RUNTIME_SETUP_TOKEN}")"
  if is_valid_claude_oauth_token "${OPENCLAW_RUNTIME_SETUP_TOKEN}"; then
    return 0
  fi

  CLAUDE_CODE_OAUTH_TOKEN="$(normalize_claude_oauth_token_input "${CLAUDE_CODE_OAUTH_TOKEN}")"
  if is_valid_claude_oauth_token "${CLAUDE_CODE_OAUTH_TOKEN}"; then
    OPENCLAW_RUNTIME_SETUP_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}"
    log_info "Reusing CLAUDE_CODE_OAUTH_TOKEN for OpenClaw runtime setup-token."
    return 0
  fi

  user_step "Step 1: claude setup-token"
  user_step "If OpenClaw asks for token input, paste the token printed by claude setup-token."
  if ! run_claude_setup_token_and_capture; then
    die "claude setup-token failed."
  fi
  OPENCLAW_RUNTIME_SETUP_TOKEN="$(normalize_claude_oauth_token_input "${OPENCLAW_RUNTIME_SETUP_TOKEN}")"
  if is_valid_claude_oauth_token "${OPENCLAW_RUNTIME_SETUP_TOKEN}"; then
    return 0
  fi

  local token_attempt=0
  while (( token_attempt < 3 )); do
    token_attempt=$((token_attempt + 1))
    user_step "Paste setup-token value (starts with sk-ant-oat...)."
    user_step "If you see this prompt, the token was already printed above by claude setup-token."
    prompt_secret OPENCLAW_RUNTIME_SETUP_TOKEN "Enter OpenClaw runtime setup-token"
    OPENCLAW_RUNTIME_SETUP_TOKEN="$(normalize_claude_oauth_token_input "${OPENCLAW_RUNTIME_SETUP_TOKEN}")"
    if is_valid_claude_oauth_token "${OPENCLAW_RUNTIME_SETUP_TOKEN}"; then
      return 0
    fi
    log_warn "Invalid setup-token format. Retry ${token_attempt}/3."
    OPENCLAW_RUNTIME_SETUP_TOKEN=""
  done

  die "Could not capture a valid Anthropic setup-token after 3 attempts."
}

apply_runtime_setup_token_via_openclaw() {
  local token="$1"
  local out=""
  if [[ -n "${token}" ]]; then
    out="$(printf "%s\n" "${token}" | with_openclaw_env openclaw models auth paste-token --provider anthropic --profile-id "${RUNTIME_PROFILE_ID}" --expires-in 365d 2>&1 || true)"
  else
    out="$(with_openclaw_env openclaw models auth paste-token --provider anthropic --profile-id "${RUNTIME_PROFILE_ID}" --expires-in 365d 2>&1 || true)"
  fi
  printf "%s\n" "${out}"
  if printf "%s" "${out}" | grep -qiE "Failed to read config|Error:|authentication_error|Invalid"; then
    return 1
  fi
  return 0
}

ensure_claude_cli_for_runtime_oauth() {
  if command -v claude >/dev/null 2>&1; then
    return 0
  fi
  log_info "Runtime setup-token requires Claude CLI. Installing @anthropic-ai/claude-code."
  npm_global_install_with_retry @anthropic-ai/claude-code
  require_cmd claude
}

run_codex_healthcheck() {
  local retries attempt
  local hc_root="${OPENCLAW_HOME}/workspace/.codex-healthcheck"
  local hc_file="${hc_root}/probe.py"
  local hc_log=""
  local sandbox_mode=""

  retries="${CODE_AGENT_HEALTHCHECK_RETRIES}"
  if ! [[ "${retries}" =~ ^[0-9]+$ ]] || [[ "${retries}" -lt 1 ]]; then
    retries=3
  fi

  ensure_dir "${hc_root}"

  for attempt in $(seq 1 "${retries}"); do
    for sandbox_mode in workspace-write danger-full-access; do
      rm -f "${hc_file}" "${hc_root}/attempt-${attempt}-${sandbox_mode}.log"
      hc_log="${hc_root}/attempt-${attempt}-${sandbox_mode}.log"
      log_info "Codex healthcheck attempt ${attempt}/${retries} (sandbox=${sandbox_mode})."

      if codex exec --ephemeral --skip-git-repo-check --sandbox "${sandbox_mode}" --cd "${hc_root}" \
        "Create a file named probe.py with exactly this content:
def _codex_ping():
    return \"ok\"

Do not modify any other files." >"${hc_log}" 2>&1; then
        if [[ -f "${hc_file}" ]] && grep -q '^def _codex_ping():' "${hc_file}" && grep -q 'return "ok"' "${hc_file}"; then
          log_info "Codex healthcheck passed."
          rm -rf "${hc_root}"
          return 0
        fi
        log_warn "Codex healthcheck command succeeded but probe file validation failed (sandbox=${sandbox_mode})."
        tail -n 20 "${hc_log}" >&2 || true
      else
        log_warn "Codex healthcheck command failed (sandbox=${sandbox_mode})."
        tail -n 20 "${hc_log}" >&2 || true
      fi

      # If non-root-safe sandbox failed with Landlock restriction, fallback to danger-full-access immediately.
      if [[ "${sandbox_mode}" == "workspace-write" ]] && grep -qi "LandlockRestrict" "${hc_log}"; then
        log_warn "Codex workspace-write sandbox is restricted in this environment; retrying with danger-full-access."
        continue
      fi
      # Do not repeat danger-full-access twice within same attempt loop.
      if [[ "${sandbox_mode}" == "danger-full-access" ]]; then
        break
      fi
    done

    sleep 3
  done

  rm -rf "${hc_root}"
  die "Codex healthcheck failed after ${retries} attempt(s)."
}

run_claude_healthcheck() {
  local retries attempt
  local hc_root="${OPENCLAW_HOME}/workspace/.claude-healthcheck"
  local hc_log=""
  local prompt='Reply with exactly: CLAUDE_OK'
  local output=""

  retries="${CODE_AGENT_HEALTHCHECK_RETRIES}"
  if ! [[ "${retries}" =~ ^[0-9]+$ ]] || [[ "${retries}" -lt 1 ]]; then
    retries=3
  fi

  ensure_dir "${hc_root}"

  for attempt in $(seq 1 "${retries}"); do
    hc_log="${hc_root}/attempt-${attempt}.log"
    rm -f "${hc_log}"
    log_info "Claude Code healthcheck attempt ${attempt}/${retries}."

    if [[ "${CODE_AGENT_AUTH_METHOD}" == "api_key" ]]; then
      output="$(ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" claude -p "${prompt}" --output-format text --permission-mode default 2>&1 || true)"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN}" ]]; then
      output="$(CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}" claude -p "${prompt}" --output-format text --permission-mode default 2>&1 || true)"
    else
      output="$(claude -p "${prompt}" --output-format text --permission-mode default 2>&1 || true)"
    fi
    printf "%s\n" "${output}" >"${hc_log}"

    if printf "%s" "${output}" | grep -q "CLAUDE_OK"; then
      log_info "Claude Code healthcheck passed."
      rm -rf "${hc_root}"
      return 0
    fi

    log_warn "Claude Code healthcheck failed."
    tail -n 20 "${hc_log}" >&2 || true
    sleep 3
  done

  rm -rf "${hc_root}"
  die "Claude Code healthcheck failed after ${retries} attempt(s)."
}

run_selected_code_agent_healthcheck() {
  case "${CODE_AGENT_CLI}" in
    codex) run_codex_healthcheck ;;
    claude) run_claude_healthcheck ;;
    *) die "Unsupported code agent CLI for healthcheck: ${CODE_AGENT_CLI}" ;;
  esac
}

collect_code_agent_auth_secrets() {
  if [[ "${CODE_AGENT_AUTH_METHOD}" != "api_key" ]]; then
    return 0
  fi

  user_section "Code Agent API Key"
  case "${CODE_AGENT_CLI}" in
    codex)
      user_step "Enter OpenAI API key for Codex login."
      user_step "Variable: OPENAI_API_KEY"
      prompt_secret OPENAI_API_KEY "Enter OPENAI_API_KEY"
      ;;
    claude)
      user_step "Enter Anthropic API key for Claude login."
      user_step "Variable: ANTHROPIC_API_KEY"
      prompt_secret ANTHROPIC_API_KEY "Enter ANTHROPIC_API_KEY"
      ;;
    *)
      die "Unsupported code agent CLI for API key collection: ${CODE_AGENT_CLI}"
      ;;
  esac
}

collect_runtime_and_agent_secrets() {
  user_section "User input required"
  case "${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}" in
    openai:api_key)
      user_step "OpenClaw runtime provider: OpenAI (API key)"
      user_step "Variable: OPENAI_API_KEY"
      prompt_secret OPENAI_API_KEY "Enter OPENAI_API_KEY"
      ;;
    openai:codex)
      user_step "OpenClaw runtime provider: OpenAI Codex OAuth"
      user_step "No runtime API key is required for this mode."
      ;;
    anthropic:api_key)
      user_step "OpenClaw runtime provider: Anthropic (API key)"
      user_step "Variable: ANTHROPIC_API_KEY"
      prompt_secret ANTHROPIC_API_KEY "Enter ANTHROPIC_API_KEY"
      ;;
    anthropic:oauth)
      user_step "OpenClaw runtime provider: Anthropic setup-token mode"
      user_step "You will complete setup-token authentication in the next stage."
      ;;
    *)
      die "Unsupported runtime provider/auth selection: ${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}"
      ;;
  esac

  resolve_gateway_token
}

authenticate_runtime_provider() {
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    if [[ "${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}" == "openai:codex" || "${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}" == "anthropic:oauth" ]]; then
      die "Runtime OAuth/setup-token auth is interactive. Use runtime API key mode for NON_INTERACTIVE=true."
    fi
    return 0
  fi

  case "${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}" in
    openai:codex)
      user_section "OpenClaw runtime login"
      user_step "Complete OpenAI Codex OAuth in your browser."
      with_openclaw_env openclaw models auth login --provider openai-codex || \
        die "OpenClaw runtime OpenAI Codex OAuth login failed."
      apply_runtime_target_model_primary
      if ! run_runtime_auth_probe; then
        die "OpenAI Codex runtime auth probe failed after login."
      fi
      ;;
    anthropic:oauth)
      user_section "OpenClaw runtime setup-token"
      user_step "Running official Anthropic setup-token flow."
      ensure_claude_cli_for_runtime_oauth
      resolve_runtime_setup_token

      local token_attempt=0
      local apply_out=""
      while (( token_attempt < 3 )); do
        token_attempt=$((token_attempt + 1))
        OPENCLAW_RUNTIME_SETUP_TOKEN="$(normalize_claude_oauth_token_input "${OPENCLAW_RUNTIME_SETUP_TOKEN}")"
        is_valid_claude_oauth_token "${OPENCLAW_RUNTIME_SETUP_TOKEN}" || die "Invalid runtime setup-token value."

        user_step "Step 2: applying token to OpenClaw auth profile (${RUNTIME_PROFILE_ID})."
        apply_out="$(apply_runtime_setup_token_via_openclaw "${OPENCLAW_RUNTIME_SETUP_TOKEN}" || true)"
        if printf "%s" "${apply_out}" | grep -qi "Failed to read config at"; then
          log_warn "OpenClaw reported config-read error while applying setup-token."
          printf "%s\n" "${apply_out}" >&2
        fi

        # Compatibility fallback: runtime lanes currently expect ANTHROPIC_API_KEY.
        ANTHROPIC_API_KEY="${OPENCLAW_RUNTIME_SETUP_TOKEN}"
        upsert_env_var "${OPENCLAW_HOME}/.env" "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY}"

        apply_runtime_target_model_primary
        if run_runtime_auth_probe; then
          log_info "Anthropic runtime setup-token auth probe passed."
          return 0
        fi

        log_warn "Anthropic runtime auth probe failed (attempt ${token_attempt}/3)."
        if (( token_attempt < 3 )); then
          user_step "OpenClaw could not verify auth with current token."
          user_step "Paste another setup-token (you can reuse one printed above)."
          OPENCLAW_RUNTIME_SETUP_TOKEN=""
          prompt_secret OPENCLAW_RUNTIME_SETUP_TOKEN "Enter OpenClaw runtime setup-token"
        fi
      done

      die "OpenClaw runtime Anthropic setup-token authentication failed after 3 attempts."
      ;;
    openai:api_key|anthropic:api_key)
      log_info "Runtime uses API key mode; no interactive runtime auth step required."
      apply_runtime_target_model_primary
      if ! run_runtime_auth_probe; then
        die "Runtime auth probe failed for ${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}."
      fi
      ;;
    *)
      die "Unsupported runtime auth flow: ${RUNTIME_PROVIDER}:${RUNTIME_AUTH_METHOD}"
      ;;
  esac
}

authenticate_selected_code_agent() {
  if [[ "${CODE_AGENT_AUTH_METHOD}" == "subscription" && "${NON_INTERACTIVE}" == "true" ]]; then
    die "Subscription login requires interactive terminal. Use CODE_AGENT_AUTH_METHOD=api_key for NON_INTERACTIVE=true."
  fi

  case "${CODE_AGENT_CLI}" in
    codex)
      if [[ "${CODE_AGENT_AUTH_METHOD}" == "api_key" ]]; then
        printf "%s" "${OPENAI_API_KEY}" | codex login --with-api-key >/dev/null 2>&1 || \
          die "Codex CLI API key authentication failed. Verify OPENAI_API_KEY and retry."
      else
        codex login --device-auth || codex login || \
          die "Codex CLI subscription login failed."
      fi
      ;;
    claude)
      if [[ "${CODE_AGENT_AUTH_METHOD}" == "api_key" ]]; then
        if ! ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" claude auth status --json >/dev/null 2>&1; then
          die "Claude Code API key auth probe failed."
        fi
      else
        local setup_log=""
        local extracted_token=""
        user_section "Claude subscription login"
        user_step "Claude may print a URL and wait for a one-time code."
        user_step "Open the URL in your browser, complete login, then paste the code into terminal prompt."
        if command -v script >/dev/null 2>&1; then
          setup_log="$(mktemp)"
          if ! script -q -e -c "claude setup-token" "${setup_log}"; then
            rm -f "${setup_log}"
            die "Claude Code subscription setup-token failed."
          fi
          extracted_token="$(extract_claude_oauth_token_from_log "${setup_log}" || true)"
          rm -f "${setup_log}"
          extracted_token="$(normalize_claude_oauth_token_input "${extracted_token}")"
          if [[ -n "${extracted_token}" ]] && is_valid_claude_oauth_token "${extracted_token}"; then
            CLAUDE_CODE_OAUTH_TOKEN="${extracted_token}"
          fi
        else
          if ! claude setup-token; then
            die "Claude Code subscription setup-token failed."
          fi
        fi

        # Some environments do not persist setup-token automatically.
        if ! claude auth status --json | jq -e '.loggedIn == true' >/dev/null 2>&1; then
          local token_attempt=0
          CLAUDE_CODE_OAUTH_TOKEN="$(normalize_claude_oauth_token_input "${CLAUDE_CODE_OAUTH_TOKEN}")"
          while true; do
            if is_valid_claude_oauth_token "${CLAUDE_CODE_OAUTH_TOKEN}" && probe_claude_oauth_token_live "${CLAUDE_CODE_OAUTH_TOKEN}"; then
              break
            fi
            token_attempt=$((token_attempt + 1))
            if [[ "${token_attempt}" -ge 3 ]]; then
              die "Claude Code subscription login did not complete. Token validation failed after ${token_attempt} attempt(s)."
            fi
            user_step "Paste full OAuth token value (starts with sk-ant-oat...)."
            user_step "If you see this prompt, Claude already printed the token above."
            user_step "Copy that highlighted token and paste it here."
            prompt_secret CLAUDE_CODE_OAUTH_TOKEN "Enter CLAUDE_CODE_OAUTH_TOKEN"
            CLAUDE_CODE_OAUTH_TOKEN="$(normalize_claude_oauth_token_input "${CLAUDE_CODE_OAUTH_TOKEN}")"
          done
        fi
      fi
      ;;
    *)
      die "Unsupported code agent CLI for authentication: ${CODE_AGENT_CLI}"
      ;;
  esac
}

main() {
  log_info "Stage 1/12: Installing base packages."
  cleanup_nodesource_repo
  apt_retry update -qq
  apt_retry install -y -qq ca-certificates curl git jq python3 python3-venv gnupg lsb-release rsync

  log_info "Stage 2/12: Installing Node.js runtime."
  install_node_22
  require_cmd node
  ensure_npm_available
  require_cmd npm

  log_info "Stage 3/12: Selecting coding agent CLI and auth mode."
  choose_code_agent_cli
  choose_code_agent_auth_method
  log_info "Selected code agent: ${CODE_AGENT_CLI} (${CODE_AGENT_AUTH_METHOD})."

  log_info "Stage 4/12: Installing OpenClaw CLI and selected coding CLI."
  install_selected_code_agent_cli

  log_info "Stage 5/12: Preparing selected coding CLI authentication."
  collect_code_agent_auth_secrets

  log_info "Authenticating selected coding CLI."
  if [[ "${SKIP_CODE_AGENT_LOGIN}" == "true" ]]; then
    log_warn "Skipping code-agent login because SKIP_CODE_AGENT_LOGIN=true."
  else
    authenticate_selected_code_agent
  fi

  log_info "Stage 6/12: Running selected coding CLI healthcheck."
  if [[ "${SKIP_CODE_AGENT_HEALTHCHECK}" == "true" ]]; then
    log_warn "Skipping code-agent healthcheck because SKIP_CODE_AGENT_HEALTHCHECK=true."
  elif [[ "${SKIP_CODE_AGENT_LOGIN}" == "true" ]]; then
    log_warn "Skipping code-agent healthcheck because SKIP_CODE_AGENT_LOGIN=true."
  else
    run_selected_code_agent_healthcheck
  fi

  log_info "Stage 7/12: Collecting OpenClaw runtime secrets."
  choose_runtime_provider_and_auth
  log_info "Selected runtime provider: ${RUNTIME_PROVIDER_ID} (${RUNTIME_AUTH_MODE})."
  collect_runtime_and_agent_secrets

  log_info "Stage 8/12: Writing OpenClaw runtime files."
  ensure_dir "${OPENCLAW_HOME}"
  if [[ -n "${OPENAI_API_KEY}" ]]; then
    upsert_env_var "${OPENCLAW_HOME}/.env" "OPENAI_API_KEY" "${OPENAI_API_KEY}"
  fi
  if [[ -n "${ANTHROPIC_API_KEY}" ]]; then
    upsert_env_var "${OPENCLAW_HOME}/.env" "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY}"
  fi
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN}" ]]; then
    upsert_env_var "${OPENCLAW_HOME}/.env" "CLAUDE_CODE_OAUTH_TOKEN" "${CLAUDE_CODE_OAUTH_TOKEN}"
  fi
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_CODE_AGENT_CLI" "${CODE_AGENT_CLI}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_CODE_AGENT_AUTH_METHOD" "${CODE_AGENT_AUTH_METHOD}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_RUNTIME_PROVIDER" "${RUNTIME_PROVIDER}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_RUNTIME_AUTH_METHOD" "${RUNTIME_AUTH_METHOD}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_RUNTIME_PROVIDER_ID" "${RUNTIME_PROVIDER_ID}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_GATEWAY_TOKEN" "${OPENCLAW_GATEWAY_TOKEN}"
  upsert_env_var "${OPENCLAW_HOME}/.env" "OPENCLAW_PORT" "${OPENCLAW_PORT}"
  ensure_openclaw_config
  ensure_dir "${OPENCLAW_HOME}/workspace"
  ensure_dir "${OPENCLAW_HOME}/agents/main/agent"

  log_info "Stage 9/12: Authenticating OpenClaw runtime profile."
  authenticate_runtime_provider

  log_info "Stage 10/12: Syncing allowed models from provider catalog."
  sync_allowed_models_from_provider_catalog

  log_info "Stage 11/12: Validating OpenClaw config."
  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed."
  fi

  if [[ "${SKIP_GATEWAY_START}" != "true" ]]; then
    log_info "Stage 12/12: Starting gateway and running smoke test."
    restart_gateway_background
    if ! wait_for_gateway_health 90; then
      die "Gateway health check timed out. See ${OPENCLAW_HOME}/logs/gateway-run.log"
    fi
  else
    log_info "Stage 12/12: Gateway start skipped by SKIP_GATEWAY_START=true."
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
