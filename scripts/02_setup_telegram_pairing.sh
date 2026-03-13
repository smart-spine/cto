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
TELEGRAM_ALLOWED_USER_ID="${TELEGRAM_ALLOWED_USER_ID:-}"
BIND_MODE="${BIND_MODE:-}"
BIND_TELEGRAM_LINK="${BIND_TELEGRAM_LINK:-}"
BIND_GROUP_ID="${BIND_GROUP_ID:-}"
BIND_TOPIC_ID="${BIND_TOPIC_ID:-}"
BIND_DIRECT_USER_ID="${BIND_DIRECT_USER_ID:-}"

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

normalize_bind_mode() {
  local raw="${1:-}"
  raw="$(printf "%s" "${raw}" | tr '[:upper:]' '[:lower:]' | xargs || true)"
  case "${raw}" in
    topic|group)
      printf "topic"
      ;;
    direct|dm|chat)
      printf "direct"
      ;;
    "")
      printf ""
      ;;
    *)
      die "Unsupported BIND_MODE='${1}'. Use: topic or direct."
      ;;
  esac
}

parse_telegram_topic_link() {
  local link="$1"
  local token="$2"
  local parsed_json=""
  parsed_json="$(python3 - "${link}" "${token}" <<'PY'
import json
import re
import sys
from urllib.parse import urlparse
from urllib.request import Request, urlopen

raw = (sys.argv[1] or "").strip()
bot_token = (sys.argv[2] or "").strip()

if not raw:
    raise SystemExit("Telegram link is empty.")

if not re.match(r"^https?://", raw, flags=re.I):
    raw = "https://" + raw

parsed = urlparse(raw)
host = parsed.netloc.lower()
if host not in {"t.me", "www.t.me", "telegram.me", "www.telegram.me"}:
    raise SystemExit("Unsupported Telegram host in link.")

parts = [p for p in parsed.path.split("/") if p]
if len(parts) < 2:
    raise SystemExit("Invalid Telegram link format.")

group_id = ""
topic_id = ""
username = ""

if parts[0] == "c":
    if len(parts) < 3:
        raise SystemExit("Invalid t.me/c link: missing topic ID.")
    topic_id = parts[2]
    if parts[1].isdigit():
        group_id = f"-100{parts[1]}"
    else:
        username = parts[1]
else:
    if len(parts) < 2:
        raise SystemExit("Invalid Telegram topic link.")
    username = parts[0]
    topic_id = parts[1]

if not topic_id.isdigit():
    raise SystemExit("Topic ID must be numeric.")

if not group_id:
    if not username:
        raise SystemExit("Could not resolve group identifier from link.")
    if not bot_token:
        raise SystemExit(
            "This link uses a group username. Configure TELEGRAM_BOT_TOKEN first, or use t.me/c/<numeric>/<topic>."
        )
    url = f"https://api.telegram.org/bot{bot_token}/getChat?chat_id=@{username}"
    req = Request(url, headers={"Accept": "application/json"})
    with urlopen(req, timeout=15) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if not payload.get("ok"):
        desc = payload.get("description") or "Telegram API getChat failed."
        raise SystemExit(desc)
    chat_id = str(payload.get("result", {}).get("id", "")).strip()
    if not chat_id:
        raise SystemExit("Telegram API getChat did not return group id.")
    group_id = chat_id

print(json.dumps({"group_id": group_id, "topic_id": topic_id}))
PY
)" || return 1

  BIND_GROUP_ID="$(printf "%s" "${parsed_json}" | jq -r '.group_id')"
  BIND_TOPIC_ID="$(printf "%s" "${parsed_json}" | jq -r '.topic_id')"
  [[ -n "${BIND_GROUP_ID}" && -n "${BIND_TOPIC_ID}" ]]
}

show_group_topic_mini_guide() {
  user_section "Recommended: bind CTO to a group topic"
  user_step "Quick guide:"
  user_step "1) Create a Telegram group."
  user_step "2) Open Group Settings -> enable Topics."
  user_step "3) Add your bot into the group."
  user_step "4) Promote bot to admin (at minimum: send messages)."
  user_step "5) Open target topic and copy its link."
  user_step "   Example: https://t.me/c/<group_numeric_without_-100>/<topic_id>"
  user_step "6) Paste the link below; script resolves group/topic IDs automatically."
}

collect_binding_preferences() {
  if [[ -z "${BIND_MODE}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      BIND_MODE="topic"
    elif has_inline_menu; then
      BIND_MODE="$(inline_menu_select "Where to bind CTO? (saved for Script 3)" \
        "topic|Group topic (recommended)" \
        "direct|Direct chat")"
    else
      echo "Where to bind CTO? (saved for Script 3)"
      echo "  1) Group topic (recommended)"
      echo "  2) Direct chat"
      local choice=""
      read -r -p "Choice [1/2] (default 1): " choice
      if [[ "${choice}" == "2" ]]; then
        BIND_MODE="direct"
      else
        BIND_MODE="topic"
      fi
    fi
  fi
  BIND_MODE="$(normalize_bind_mode "${BIND_MODE}")"
  [[ -n "${BIND_MODE}" ]] || BIND_MODE="topic"

  if [[ "${BIND_MODE}" == "topic" ]]; then
    show_group_topic_mini_guide
    if [[ -z "${BIND_TELEGRAM_LINK}" && ( -z "${BIND_GROUP_ID}" || -z "${BIND_TOPIC_ID}" ) ]]; then
      if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        die "For topic binding with NON_INTERACTIVE=true set BIND_TELEGRAM_LINK or BIND_GROUP_ID and BIND_TOPIC_ID."
      fi
      read -r -p "Enter Telegram topic link: " BIND_TELEGRAM_LINK
    fi

    if [[ -n "${BIND_TELEGRAM_LINK}" ]]; then
      if ! parse_telegram_topic_link "${BIND_TELEGRAM_LINK}" "${TELEGRAM_BOT_TOKEN}"; then
        die "Failed to parse Telegram topic link '${BIND_TELEGRAM_LINK}'."
      fi
      log_info "Parsed link -> group ${BIND_GROUP_ID}, topic ${BIND_TOPIC_ID}."
    fi

    if [[ -z "${BIND_GROUP_ID}" || -z "${BIND_TOPIC_ID}" ]]; then
      if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        die "Topic binding requires BIND_GROUP_ID and BIND_TOPIC_ID."
      fi
      read -r -p "Group ID (example: -1001234567890): " BIND_GROUP_ID
      read -r -p "Topic ID (example: 42): " BIND_TOPIC_ID
    fi

    [[ -n "${BIND_GROUP_ID}" ]] || die "Group ID is required for topic binding."
    [[ -n "${BIND_TOPIC_ID}" ]] || die "Topic ID is required for topic binding."
  else
    if [[ -z "${BIND_DIRECT_USER_ID}" ]]; then
      BIND_DIRECT_USER_ID="${PAIRING_TELEGRAM_USER_ID}"
    fi
    if [[ -z "${BIND_DIRECT_USER_ID}" ]]; then
      if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        die "Direct binding requires BIND_DIRECT_USER_ID or PAIRING_TELEGRAM_USER_ID."
      fi
      read -r -p "Telegram user ID for direct binding: " BIND_DIRECT_USER_ID
    fi
    [[ -n "${BIND_DIRECT_USER_ID}" ]] || die "Direct binding requires Telegram user ID."
    TELEGRAM_ALLOWED_USER_ID="${BIND_DIRECT_USER_ID}"
  fi
}

persist_binding_preferences_to_env() {
  upsert_env_var "${OPENCLAW_HOME}/.env" "BIND_MODE" "${BIND_MODE}"
  if [[ "${BIND_MODE}" == "topic" ]]; then
    upsert_env_var "${OPENCLAW_HOME}/.env" "BIND_GROUP_ID" "${BIND_GROUP_ID}"
    upsert_env_var "${OPENCLAW_HOME}/.env" "BIND_TOPIC_ID" "${BIND_TOPIC_ID}"
    if [[ -n "${BIND_TELEGRAM_LINK}" ]]; then
      upsert_env_var "${OPENCLAW_HOME}/.env" "BIND_TELEGRAM_LINK" "${BIND_TELEGRAM_LINK}"
    fi
  else
    upsert_env_var "${OPENCLAW_HOME}/.env" "BIND_DIRECT_USER_ID" "${BIND_DIRECT_USER_ID}"
    if [[ -n "${TELEGRAM_ALLOWED_USER_ID}" ]]; then
      upsert_env_var "${OPENCLAW_HOME}/.env" "TELEGRAM_ALLOWED_USER_ID" "${TELEGRAM_ALLOWED_USER_ID}"
    fi
  fi
}

main() {
  require_cmd openclaw
  require_cmd jq
  require_cmd python3

  [[ -f "${OPENCLAW_HOME}/openclaw.json" ]] || die "Missing ${OPENCLAW_HOME}/openclaw.json. Run Script 1 first."
  [[ -f "${OPENCLAW_HOME}/.env" ]] || die "Missing ${OPENCLAW_HOME}/.env. Run Script 1 first."

  log_info "Stage 1/8: Collecting Telegram bot token."
  user_section "User input required"
  user_step "Paste your Telegram bot token when prompted."
  user_step "Variable: TELEGRAM_BOT_TOKEN"
  prompt_secret TELEGRAM_BOT_TOKEN "Enter TELEGRAM_BOT_TOKEN"
  upsert_env_var "${OPENCLAW_HOME}/.env" "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}"

  log_info "Stage 2/8: Ensuring Telegram plugin is enabled."
  ensure_telegram_plugin_enabled

  log_info "Stage 3/8: Configuring Telegram channel account."
  with_openclaw_env openclaw channels add --channel telegram --account default --token "${TELEGRAM_BOT_TOKEN}" >/dev/null

  log_info "Stage 4/8: Ensuring telegram config in openclaw.json."
  ensure_telegram_config

  log_info "Stage 5/8: Validating config and restarting gateway."
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

  log_info "Stage 6/8: Waiting for pairing trigger from user."
  user_section "User action required for Telegram pairing"
  user_step "1) Open direct chat with your Telegram bot."
  user_step "2) If this is the first time, press Start in Telegram."
  user_step "3) Send any message to the bot."
  user_step "4) Wait for the 'pairing required' reply."
  user_step "5) Return to this terminal and press ENTER to continue."
  if [[ "${AUTO_CONFIRM}" != "true" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      die "AUTO_CONFIRM must be true when NON_INTERACTIVE=true."
    fi
    read -r
  fi

  log_info "Stage 7/8: Attempting automatic pairing approval."
  local pending_json=""
  local paired_user_id=""
  local pairing_code=""
  if ! pairing_code="$(wait_for_pairing_code)"; then
    log_warn "No pending pairing code found within ${TELEGRAM_PAIRING_TIMEOUT_SECONDS}s."
    user_section "Manual pairing fallback"
    user_step "When the Telegram pairing code appears, run:"
    user_command "openclaw pairing approve telegram <PAIRING_CODE>"
    exit 0
  fi
  pending_json="$(fetch_pairing_requests_json)"
  paired_user_id="$(extract_pairing_user_id "${pending_json}" "${PAIRING_TELEGRAM_USER_ID}")"

  with_openclaw_env openclaw pairing approve telegram "${pairing_code}" --notify >/dev/null
  allow_group_user "${paired_user_id}"
  if [[ -n "${paired_user_id}" ]]; then
    PAIRING_TELEGRAM_USER_ID="${paired_user_id}"
  fi

  log_info "Stage 8/8: Collecting and saving preferred CTO binding target."
  collect_binding_preferences
  persist_binding_preferences_to_env

  restart_gateway_background || true
  wait_for_gateway_health 90 || true
  log_info "Pairing approved successfully for Telegram."
  if [[ -n "${paired_user_id}" ]]; then
    log_info "Added Telegram user ${paired_user_id} to group allowlists."
  fi
  if [[ "${BIND_MODE}" == "topic" ]]; then
    log_info "Saved preferred binding: ${BIND_GROUP_ID}:topic:${BIND_TOPIC_ID}"
  else
    log_info "Saved preferred binding: direct:${BIND_DIRECT_USER_ID}"
  fi
  log_info "Script 3 will reuse this saved binding if explicit BIND_* variables are not provided."
}

main "$@"
