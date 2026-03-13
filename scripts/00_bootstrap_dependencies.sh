#!/usr/bin/env bash

set -euo pipefail

BOOTSTRAP_TZ="${BOOTSTRAP_TZ:-America/New_York}"

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
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      die "sudo is required when not running as root."
    fi
  fi
}

apt_retry() {
  local attempt=1
  local max_attempts=5
  local delay=5
  while (( attempt <= max_attempts )); do
    if run_as_root env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true TZ="${BOOTSTRAP_TZ}" NEEDRESTART_MODE=a \
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

configure_bootstrap_timezone() {
  [[ -n "${BOOTSTRAP_TZ}" ]] || return 0
  if ! run_as_root test -f "/usr/share/zoneinfo/${BOOTSTRAP_TZ}"; then
    log_warn "Timezone '${BOOTSTRAP_TZ}' is not available on this host; skipping timezone configuration."
    return 0
  fi

  run_as_root ln -snf "/usr/share/zoneinfo/${BOOTSTRAP_TZ}" /etc/localtime
  run_as_root bash -lc "printf '%s\n' '${BOOTSTRAP_TZ}' > /etc/timezone"
  if command -v dpkg-reconfigure >/dev/null 2>&1; then
    run_as_root env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true TZ="${BOOTSTRAP_TZ}" \
      dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
  fi
  log_info "Default timezone set to ${BOOTSTRAP_TZ}."
}

assert_supported_os() {
  [[ -f /etc/os-release ]] || die "Missing /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      ;;
    *)
      die "Unsupported distro ID='${ID:-unknown}'. This bootstrap supports Ubuntu/Debian."
      ;;
  esac
}

cleanup_stale_nodesource() {
  # Some hosts keep stale NodeSource entries without keys, which breaks apt update.
  local stale_files=""
  stale_files="$(
    run_as_root bash -lc "grep -RIl 'deb\\.nodesource\\.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true"
  )"
  if [[ -n "${stale_files}" ]]; then
    log_warn "Removing stale NodeSource apt entries."
    while IFS= read -r file; do
      [[ -n "${file}" ]] || continue
      if [[ "${file}" == /etc/apt/sources.list.d/* ]]; then
        # For deb822 .sources files, line editing can leave malformed stanzas. Remove file fully.
        run_as_root rm -f "${file}" || true
      else
        run_as_root sed -i '/deb\.nodesource\.com/d' "${file}" || true
        run_as_root sed -i '/nodesource\.com/d' "${file}" || true
      fi
    done <<< "${stale_files}"
  fi
  run_as_root rm -f \
    /etc/apt/sources.list.d/nodesource.list \
    /etc/apt/sources.list.d/nodesource.sources \
    /etc/apt/sources.list.d/nodesource.list.save \
    /etc/apt/keyrings/nodesource.gpg \
    /usr/share/keyrings/nodesource.gpg || true
}

resolve_default_repo_dir() {
  local base_home="${HOME:-/root}"
  if [[ "$(id -u)" -eq 0 ]]; then
    local sudo_user="${SUDO_USER:-}"
    if [[ -n "${sudo_user}" && "${sudo_user}" != "root" ]]; then
      local sudo_home=""
      if command -v getent >/dev/null 2>&1; then
        sudo_home="$(getent passwd "${sudo_user}" | cut -d: -f6 || true)"
      fi
      if [[ -z "${sudo_home}" && -d "/home/${sudo_user}" ]]; then
        sudo_home="/home/${sudo_user}"
      fi
      if [[ -n "${sudo_home}" ]]; then
        base_home="${sudo_home}"
      fi
    fi
  fi
  printf "%s/cto-agent" "${base_home}"
}

resolve_repo_branch() {
  local repo_url="$1"
  local requested="$2"

  if git ls-remote --exit-code --heads "${repo_url}" "refs/heads/${requested}" >/dev/null 2>&1; then
    printf "%s" "${requested}"
    return 0
  fi
  if git ls-remote --exit-code --heads "${repo_url}" "refs/heads/main" >/dev/null 2>&1; then
    printf "main"
    return 0
  fi
  printf ""
}

clone_or_update_repo() {
  local repo_url="$1"
  local branch="$2"
  local repo_dir="$3"

  if [[ -e "${repo_dir}" && ! -d "${repo_dir}/.git" ]]; then
    die "Target path exists but is not a git repository: ${repo_dir}"
  fi

  if [[ -d "${repo_dir}/.git" ]]; then
    log_info "Repository already exists: ${repo_dir}. Updating."
    git -C "${repo_dir}" fetch --all --prune
    git -C "${repo_dir}" checkout "${branch}"
    git -C "${repo_dir}" pull --ff-only origin "${branch}"
    return 0
  fi

  log_info "Cloning ${repo_url} (branch: ${branch}) into ${repo_dir}"
  git clone --depth 1 --branch "${branch}" "${repo_url}" "${repo_dir}"
}

print_next_steps() {
  local repo_dir="$1"
  user_section "Bootstrap completed successfully."
  user_step "Next steps:"
  user_step "1) ./scripts/01_install_openclaw.sh"
  user_step "2) ./scripts/02_setup_telegram_pairing.sh"
  user_step "3) ./scripts/03_deploy_cto_agent.sh"
  user_step "Optional advanced:"
  user_step "- ./scripts/05_update_cto_agent.sh      (pull and apply CTO updates safely)"
  user_step "- ./scripts/04_rebind_cto_to_topic.sh   (bind CTO to Telegram group topic)"
  user_step "- ./scripts/99_uninstall_openclaw.sh     (remove OpenClaw/CTO from this host)"
  user_step "If your shell did not switch automatically, run:"
  user_command "cd ${repo_dir}"
}

print_manual_cd_instructions() {
  local repo_dir="$1"
  user_section "Manual step required"
  user_step "Auto-switch to repository shell is not available in this context."
  user_step "Run the command below and continue:"
  user_command "cd ${repo_dir}"
}

enter_repo_shell_if_interactive() {
  local repo_dir="$1"
  local auto_enter="${AUTO_ENTER_REPO_SHELL:-true}"

  if [[ "${auto_enter}" != "true" ]]; then
    return 0
  fi
  if [[ ! -d "${repo_dir}" ]]; then
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 || ! -r /dev/tty || ! -w /dev/tty ]]; then
    log_warn "Skipping auto-shell switch because no interactive TTY is available."
    print_manual_cd_instructions "${repo_dir}"
    return 0
  fi

  log_info "Opening interactive shell in ${repo_dir} (type 'exit' to return)."
  cd "${repo_dir}" || return 0
  if ! exec < /dev/tty > /dev/tty 2>&1; then
    log_warn "Could not attach to /dev/tty for shell handoff."
    print_manual_cd_instructions "${repo_dir}"
    return 0
  fi
  exec "${SHELL:-/bin/bash}" -i
}

main() {
  local repo_url="${CTO_REPO_URL:-https://github.com/no-name-labs/cto.git}"
  local requested_branch="${CTO_REPO_BRANCH:-main}"
  local default_repo_dir
  default_repo_dir="$(resolve_default_repo_dir)"
  local repo_dir="${CTO_REPO_DIR:-$default_repo_dir}"
  local auto_clone="${AUTO_CLONE_REPO:-true}"

  require_cmd bash
  require_cmd apt-get
  assert_supported_os

  log_info "Stage 1/4: Installing base OS dependencies."
  cleanup_stale_nodesource
  apt_retry update -qq
  apt_retry install -y -qq \
    ca-certificates curl git jq python3 python3-venv rsync sudo gnupg lsb-release \
    unzip xz-utils tar procps
  configure_bootstrap_timezone

  log_info "Stage 2/4: Verifying required commands."
  require_cmd curl
  require_cmd git
  require_cmd jq
  require_cmd python3
  require_cmd rsync

  if [[ "${auto_clone}" != "true" ]]; then
    log_info "AUTO_CLONE_REPO=false, skipping repository clone."
    return 0
  fi

  log_info "Stage 3/4: Resolving repository branch."
  local resolved_branch
  resolved_branch="$(resolve_repo_branch "${repo_url}" "${requested_branch}")"
  [[ -n "${resolved_branch}" ]] || die "Unable to resolve branch for ${repo_url}"
  log_info "Using branch: ${resolved_branch}"

  log_info "Stage 4/4: Cloning/updating repository."
  clone_or_update_repo "${repo_url}" "${resolved_branch}" "${repo_dir}"

  if [[ -f "${repo_dir}/scripts/00_bootstrap_dependencies.sh" ]]; then
    chmod +x "${repo_dir}/scripts/00_bootstrap_dependencies.sh" || true
  fi
  if [[ -f "${repo_dir}/scripts/01_install_openclaw.sh" ]]; then
    chmod +x "${repo_dir}/scripts/01_install_openclaw.sh" || true
  fi
  if [[ -f "${repo_dir}/scripts/02_setup_telegram_pairing.sh" ]]; then
    chmod +x "${repo_dir}/scripts/02_setup_telegram_pairing.sh" || true
  fi
  if [[ -f "${repo_dir}/scripts/03_deploy_cto_agent.sh" ]]; then
    chmod +x "${repo_dir}/scripts/03_deploy_cto_agent.sh" || true
  fi
  if [[ -f "${repo_dir}/scripts/05_update_cto_agent.sh" ]]; then
    chmod +x "${repo_dir}/scripts/05_update_cto_agent.sh" || true
  fi
  if [[ -f "${repo_dir}/scripts/04_rebind_cto_to_topic.sh" ]]; then
    chmod +x "${repo_dir}/scripts/04_rebind_cto_to_topic.sh" || true
  fi
  if [[ -f "${repo_dir}/scripts/99_uninstall_openclaw.sh" ]]; then
    chmod +x "${repo_dir}/scripts/99_uninstall_openclaw.sh" || true
  fi
  if [[ -f "${repo_dir}/scripts/lib/common.sh" ]]; then
    chmod +x "${repo_dir}/scripts/lib/common.sh" || true
  fi

  print_next_steps "${repo_dir}"
  enter_repo_shell_if_interactive "${repo_dir}"
}

main "$@"
