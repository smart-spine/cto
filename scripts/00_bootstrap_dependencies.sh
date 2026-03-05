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
  printf "%s/cto" "${base_home}"
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
  cat <<EOF

Bootstrap completed successfully.

Next steps:
1) cd ${repo_dir}
2) chmod +x scripts/lib/common.sh scripts/01_install_openclaw.sh scripts/02_setup_telegram_pairing.sh scripts/03_deploy_cto_agent.sh
3) ./scripts/01_install_openclaw.sh
4) ./scripts/02_setup_telegram_pairing.sh
5) ./scripts/03_deploy_cto_agent.sh
EOF
}

main() {
  local repo_url="${CTO_REPO_URL:-https://github.com/smart-spine/cto.git}"
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
  if [[ -f "${repo_dir}/scripts/lib/common.sh" ]]; then
    chmod +x "${repo_dir}/scripts/lib/common.sh" || true
  fi

  print_next_steps "${repo_dir}"
}

main "$@"
