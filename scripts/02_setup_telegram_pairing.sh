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
  echo "[ERROR] Could not resolve script directory. Run from repo root: ./scripts/02_setup_telegram_pairing.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
PAIRING_TELEGRAM_USER_ID="${PAIRING_TELEGRAM_USER_ID:-}"
TELEGRAM_PAIRING_TIMEOUT_SECONDS="${TELEGRAM_PAIRING_TIMEOUT_SECONDS:-90}"

ensure_telegram_plugin_enabled() {
  require_cmd openclaw
  require_cmd jq

  local plugins_json
  plugins_json="$(with_openclaw_env openclaw plugins list --json 2>/dev/null || true)"
  if [[ -z "${plugins_json}" ]]; then
    die "Failed to query OpenClaw plugins."
  fi

  if ! printf "%s" "${plugins_json}" | jq -e '.plugins[]? | select(.id=="telegram")' >/dev/null 2>&1; then
    die "Telegram plugin is not available in this OpenClaw build."
  fi

  if printf "%s" "${plugins_json}" | jq -e '.plugins[]? | select(.id=="telegram" and .enabled==true)' >/dev/null 2>&1; then
    log_info "Telegram plugin already enabled."
    return 0
  fi

  log_info "Enabling Telegram plugin."
  with_openclaw_env openclaw plugins enable telegram >/dev/null
}

ensure_telegram_config() {
  local config_path="${OPENCLAW_HOME}/openclaw.json"
  backup_file "${config_path}"
  python3 - "${config_path}" "${TELEGRAM_BOT_TOKEN}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
telegram_bot_token = sys.argv[2]
data = json.loads(config_path.read_text(encoding="utf-8"))

channels = data.setdefault("channels", {})
telegram = channels.setdefault("telegram", {})
telegram["enabled"] = True
telegram.setdefault("commands", {})["native"] = True

accounts = telegram.setdefault("accounts", {})
default_account = accounts.setdefault("default", {})
default_account["botToken"] = telegram_bot_token

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

extract_pairing_code() {
  local raw="${1:-}"
  local target_uid="${2:-}"
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  printf "%s" "${raw}" | jq -r --arg uid "${target_uid}" '
    def reqs:
      if type == "array" then .
      elif type == "object" then (.requests // [])
      else [] end;
    if ($uid | length) > 0
    then (reqs | map(select((.id | tostring) == $uid)) | .[0].code // empty)
    else (reqs[0].code // empty)
    end
  ' 2>/dev/null || true
}

extract_pairing_user_id() {
  local raw="${1:-}"
  local target_uid="${2:-}"
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  printf "%s" "${raw}" | jq -r --arg uid "${target_uid}" '
    def reqs:
      if type == "array" then .
      elif type == "object" then (.requests // [])
      else [] end;
    if ($uid | length) > 0
    then (reqs | map(select((.id | tostring) == $uid)) | .[0].id // empty)
    else (reqs[0].id // empty)
    end
  ' 2>/dev/null || true
}

fetch_pairing_requests_json() {
  local out
  out="$(with_openclaw_env openclaw pairing list --channel telegram --json 2>/dev/null || true)"
  if printf "%s" "${out}" | jq -e . >/dev/null 2>&1; then
    printf "%s" "${out}"
    return 0
  fi

  out="$(with_openclaw_env openclaw pairing list telegram --json 2>/dev/null || true)"
  if printf "%s" "${out}" | jq -e . >/dev/null 2>&1; then
    printf "%s" "${out}"
    return 0
  fi

  printf ""
}

wait_for_pairing_code() {
  local timeout="${TELEGRAM_PAIRING_TIMEOUT_SECONDS}"
  local started
  started="$(date +%s)"
  while (( "$(date +%s)" - started < timeout )); do
    local pending_json
    pending_json="$(fetch_pairing_requests_json)"
    local code
    code="$(extract_pairing_code "${pending_json}" "${PAIRING_TELEGRAM_USER_ID}")"
    if [[ -n "${code}" ]]; then
      printf "%s" "${code}"
      return 0
    fi
    sleep 2
  done
  return 1
}

allow_group_user() {
  local telegram_user_id="${1:-}"
  if [[ -z "${telegram_user_id}" ]]; then
    return 0
  fi
  local config_path="${OPENCLAW_HOME}/openclaw.json"
  backup_file "${config_path}"
  python3 - "${config_path}" "${telegram_user_id}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
uid = str(sys.argv[2]).strip()
if not uid:
    raise SystemExit(0)

data = json.loads(config_path.read_text(encoding="utf-8"))
channels = data.setdefault("channels", {})
telegram = channels.setdefault("telegram", {})

telegram.setdefault("groupPolicy", "allowlist")
global_allow = {str(x).strip() for x in telegram.get("groupAllowFrom", []) if str(x).strip()}
global_allow.add(uid)
telegram["groupAllowFrom"] = sorted(global_allow)

accounts = telegram.setdefault("accounts", {})
default_account = accounts.setdefault("default", {})
default_account.setdefault("groupPolicy", "allowlist")
account_allow = {str(x).strip() for x in default_account.get("groupAllowFrom", []) if str(x).strip()}
account_allow.add(uid)
default_account["groupAllowFrom"] = sorted(account_allow)

groups = telegram.get("groups", {})
if isinstance(groups, dict):
    for _, group_cfg in groups.items():
        if isinstance(group_cfg, dict):
            group_cfg.setdefault("groupPolicy", "allowlist")
            allow = {str(x).strip() for x in group_cfg.get("allowFrom", []) if str(x).strip()}
            allow.add(uid)
            group_cfg["allowFrom"] = sorted(allow)

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

main() {
  require_cmd openclaw
  require_cmd jq
  require_cmd python3

  [[ -f "${OPENCLAW_HOME}/openclaw.json" ]] || die "Missing ${OPENCLAW_HOME}/openclaw.json. Run Script 1 first."
  [[ -f "${OPENCLAW_HOME}/.env" ]] || die "Missing ${OPENCLAW_HOME}/.env. Run Script 1 first."

  log_info "Stage 1/7: Collecting Telegram bot token."
  prompt_secret TELEGRAM_BOT_TOKEN "Enter TELEGRAM_BOT_TOKEN"
  upsert_env_var "${OPENCLAW_HOME}/.env" "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}"

  log_info "Stage 2/7: Ensuring Telegram plugin is enabled."
  ensure_telegram_plugin_enabled

  log_info "Stage 3/7: Configuring Telegram channel account."
  with_openclaw_env openclaw channels add --channel telegram --account default --token "${TELEGRAM_BOT_TOKEN}" >/dev/null

  log_info "Stage 4/7: Ensuring telegram config in openclaw.json."
  ensure_telegram_config

  log_info "Stage 5/7: Validating config and restarting gateway."
  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed after Telegram setup."
  fi

  restart_gateway_background
  if ! wait_for_gateway_health 90; then
    die "Gateway health check timed out after Telegram setup."
  fi

  log_info "Stage 6/7: Waiting for pairing trigger from user."
  echo "Please send any message to your Telegram bot. Press ENTER here when you receive the 'pairing required' message from the bot."
  if [[ "${AUTO_CONFIRM}" != "true" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      die "AUTO_CONFIRM must be true when NON_INTERACTIVE=true."
    fi
    read -r
  fi

  log_info "Stage 7/7: Attempting automatic pairing approval."
  local pending_json=""
  local paired_user_id=""
  local pairing_code=""
  if ! pairing_code="$(wait_for_pairing_code)"; then
    log_warn "No pending pairing code found within ${TELEGRAM_PAIRING_TIMEOUT_SECONDS}s."
    log_warn "Run manually when you receive a code: openclaw pairing approve telegram <PAIRING_CODE>"
    exit 0
  fi
  pending_json="$(fetch_pairing_requests_json)"
  paired_user_id="$(extract_pairing_user_id "${pending_json}" "${PAIRING_TELEGRAM_USER_ID}")"

  with_openclaw_env openclaw pairing approve telegram "${pairing_code}" --notify >/dev/null
  allow_group_user "${paired_user_id}"
  restart_gateway_background || true
  wait_for_gateway_health 90 || true
  log_info "Pairing approved successfully for Telegram."
  if [[ -n "${paired_user_id}" ]]; then
    log_info "Added Telegram user ${paired_user_id} to group allowlists."
  fi
}

main "$@"
