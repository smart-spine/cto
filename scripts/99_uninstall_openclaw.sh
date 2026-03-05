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
  echo "[ERROR] Could not resolve script directory. Run from repo root: ./scripts/99_uninstall_openclaw.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
REMOVE_REPO="${REMOVE_REPO:-false}"
WIPE_NODE_STACK="${WIPE_NODE_STACK:-true}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

confirm_destructive_action() {
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    return 0
  fi
  user_section "Destructive operation confirmation"
  user_step "This will remove local OpenClaw state, services, and optionally Node/Codex binaries."
  read -r -p "Type YES to continue: " answer
  [[ "${answer}" == "YES" ]] || die "Uninstall aborted by user."
}

stop_services() {
  log_info "Stopping OpenClaw services and processes."
  run_as_root systemctl stop openclaw.service 2>/dev/null || true
  run_as_root systemctl stop openclaw-gateway.service 2>/dev/null || true
  run_as_root systemctl disable openclaw.service 2>/dev/null || true
  run_as_root systemctl disable openclaw-gateway.service 2>/dev/null || true
  pkill -f openclaw-gateway || true
  pkill -f "openclaw gateway" || true
}

remove_state_dirs() {
  log_info "Removing OpenClaw state directories."
  rm -rf "${OPENCLAW_HOME}" "$HOME/.codex"
  run_as_root rm -rf /root/.openclaw /root/.codex

  if [[ "${REMOVE_REPO}" == "true" ]]; then
    log_info "REMOVE_REPO=true -> removing ~/cto repository clone."
    rm -rf "$HOME/cto"
  fi
}

remove_service_artifacts() {
  log_info "Removing service definitions and env files."
  run_as_root rm -f /etc/systemd/system/openclaw.service /etc/systemd/system/openclaw-gateway.service
  run_as_root rm -f /opt/openclaw.env /etc/openclaw.env
  run_as_root systemctl daemon-reload || true
}

remove_node_and_cli_stack() {
  if [[ "${WIPE_NODE_STACK}" != "true" ]]; then
    log_warn "Skipping Node stack removal because WIPE_NODE_STACK=false."
    return 0
  fi

  log_info "Removing OpenClaw/Codex/Node runtime stack."
  if command -v npm >/dev/null 2>&1; then
    run_as_root npm uninstall -g openclaw @openai/codex clawhub corepack npm >/dev/null 2>&1 || true
  fi

  run_as_root rm -f /usr/bin/openclaw /usr/bin/codex /usr/bin/node /usr/bin/npm /usr/bin/npx /usr/bin/corepack
  run_as_root rm -f /usr/local/bin/openclaw /usr/local/bin/codex /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
  run_as_root rm -rf /usr/lib/node_modules /usr/local/lib/node_modules /usr/include/node /usr/local/include/node

  run_as_root rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.sources
  run_as_root rm -f /etc/apt/keyrings/nodesource.gpg /usr/share/keyrings/nodesource.gpg

  run_as_root apt-get purge -y nodejs npm >/dev/null 2>&1 || true
  run_as_root apt-get autoremove -y >/dev/null 2>&1 || true
}

print_verification() {
  log_info "Verification summary."
  for c in openclaw codex node npm npx; do
    if command -v "$c" >/dev/null 2>&1; then
      printf "STILL_PRESENT:%s:%s\n" "$c" "$(command -v "$c")"
    else
      printf "REMOVED:%s\n" "$c"
    fi
  done

  [[ -d "${OPENCLAW_HOME}" ]] && echo "STILL_PRESENT:${OPENCLAW_HOME}" || echo "REMOVED:${OPENCLAW_HOME}"
  [[ -d "$HOME/.codex" ]] && echo "STILL_PRESENT:$HOME/.codex" || echo "REMOVED:$HOME/.codex"

  pgrep -af "openclaw|codex|gateway" || echo "NO_OPENCLAW_RELATED_PROCESSES"
}

main() {
  confirm_destructive_action
  stop_services
  remove_state_dirs
  remove_service_artifacts
  remove_node_and_cli_stack
  print_verification
  user_section "Uninstall completed"
  user_step "Host is cleaned from OpenClaw/CTO artifacts (within script scope)."
}

main "$@"
