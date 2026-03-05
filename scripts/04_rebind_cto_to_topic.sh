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
  echo "[ERROR] Could not resolve script directory. Run from repo root: ./scripts/04_rebind_cto_to_topic.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_HOME}/openclaw.json"
BIND_TELEGRAM_LINK="${BIND_TELEGRAM_LINK:-}"
BIND_GROUP_ID="${BIND_GROUP_ID:-}"
BIND_TOPIC_ID="${BIND_TOPIC_ID:-}"
TELEGRAM_ALLOWED_USER_ID="${TELEGRAM_ALLOWED_USER_ID:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

load_telegram_bot_token_from_config() {
  python3 - "${OPENCLAW_CONFIG_PATH}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("")
    raise SystemExit(0)

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)

channels = data.get("channels") or {}
telegram = channels.get("telegram") or {}
accounts = telegram.get("accounts") or {}
default = accounts.get("default") or {}

print(str(default.get("botToken") or telegram.get("botToken") or "").strip())
PY
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

collect_topic_inputs() {
  if [[ -z "${BIND_TELEGRAM_LINK}" && -z "${BIND_GROUP_ID}" && -z "${BIND_TOPIC_ID}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      die "For NON_INTERACTIVE=true set BIND_TELEGRAM_LINK or both BIND_GROUP_ID and BIND_TOPIC_ID."
    fi
    user_section "User input required"
    user_step "Provide Telegram topic route as a link or IDs."
    read -r -p "Telegram topic link (example: https://t.me/c/1234567890/42): " BIND_TELEGRAM_LINK
  fi

  if [[ -n "${BIND_TELEGRAM_LINK}" ]]; then
    local telegram_token="${TELEGRAM_BOT_TOKEN:-}"
    if [[ -z "${telegram_token}" ]]; then
      telegram_token="$(load_telegram_bot_token_from_config)"
    fi
    if ! parse_telegram_topic_link "${BIND_TELEGRAM_LINK}" "${telegram_token}"; then
      die "Failed to parse Telegram link '${BIND_TELEGRAM_LINK}'. Use t.me/c/<group>/<topic> or explicit IDs."
    fi
    log_info "Parsed Telegram link -> group ${BIND_GROUP_ID}, topic ${BIND_TOPIC_ID}."
  fi

  if [[ -z "${BIND_GROUP_ID}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      die "BIND_GROUP_ID is required for NON_INTERACTIVE topic binding."
    fi
    read -r -p "Group ID (example: -1001234567890): " BIND_GROUP_ID
  fi

  if [[ -z "${BIND_TOPIC_ID}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      die "BIND_TOPIC_ID is required for NON_INTERACTIVE topic binding."
    fi
    read -r -p "Topic ID (example: 42): " BIND_TOPIC_ID
  fi

  [[ -n "${BIND_GROUP_ID}" ]] || die "Group ID is required."
  [[ -n "${BIND_TOPIC_ID}" ]] || die "Topic ID is required."

  if [[ -z "${TELEGRAM_ALLOWED_USER_ID}" && "${NON_INTERACTIVE}" != "true" ]]; then
    read -r -p "Telegram user ID to allow (optional; blank = keep existing allowlists): " TELEGRAM_ALLOWED_USER_ID
  fi
}

apply_cto_topic_binding() {
  local config_path="${OPENCLAW_CONFIG_PATH}"
  backup_file "${config_path}"
  python3 - "${config_path}" "${BIND_GROUP_ID}" "${BIND_TOPIC_ID}" "${TELEGRAM_ALLOWED_USER_ID}" "${TELEGRAM_BOT_TOKEN:-}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
group_id = (sys.argv[2] or "").strip()
topic_id = (sys.argv[3] or "").strip()
allowed_uid = (sys.argv[4] or "").strip()
telegram_bot_token = sys.argv[5]

if not group_id or not topic_id:
    raise SystemExit("Group and topic IDs are required.")

data = json.loads(config_path.read_text(encoding="utf-8"))

channels = data.setdefault("channels", {})
telegram = channels.setdefault("telegram", {})
telegram["enabled"] = True
telegram.setdefault("commands", {})["native"] = True
telegram.setdefault("groupPolicy", "allowlist")
default_account = telegram.setdefault("accounts", {}).setdefault("default", {})
default_account.setdefault("groupPolicy", "allowlist")
if telegram_bot_token:
    default_account["botToken"] = telegram_bot_token

if not allowed_uid:
    candidates = []
    candidates.extend(default_account.get("allowFrom", []) or [])
    candidates.extend(telegram.get("allowFrom", []) or [])
    candidates.extend(default_account.get("groupAllowFrom", []) or [])
    candidates.extend(telegram.get("groupAllowFrom", []) or [])
    for candidate in candidates:
        candidate = str(candidate).strip()
        if candidate and candidate != "*":
            allowed_uid = candidate
            break

bindings = data.setdefault("bindings", [])
bindings = [b for b in bindings if not (isinstance(b, dict) and b.get("agentId") == "cto-factory")]
bindings.append(
    {
        "agentId": "cto-factory",
        "match": {
            "channel": "telegram",
            "accountId": "default",
            "peer": {"kind": "group", "id": f"{group_id}:topic:{topic_id}"},
        },
    }
)
data["bindings"] = bindings

groups = telegram.setdefault("groups", {})
group_cfg = groups.setdefault(group_id, {})
group_cfg.setdefault("groupPolicy", "allowlist")
topics = group_cfg.setdefault("topics", {})
topic_cfg = topics.setdefault(topic_id, {})
topic_cfg.setdefault("requireMention", False)
topic_cfg.setdefault("groupPolicy", "allowlist")

if allowed_uid:
    for key in ("allowFrom", "groupAllowFrom"):
        global_allow = {str(x).strip() for x in telegram.get(key, []) if str(x).strip()}
        global_allow.add(allowed_uid)
        telegram[key] = sorted(global_allow)

        account_allow = {str(x).strip() for x in default_account.get(key, []) if str(x).strip()}
        account_allow.add(allowed_uid)
        default_account[key] = sorted(account_allow)

    group_allow = {str(x).strip() for x in group_cfg.get("allowFrom", []) if str(x).strip()}
    group_allow.add(allowed_uid)
    group_cfg["allowFrom"] = sorted(group_allow)

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

main() {
  require_cmd openclaw
  require_cmd jq
  require_cmd python3

  [[ -f "${OPENCLAW_CONFIG_PATH}" ]] || die "Missing ${OPENCLAW_CONFIG_PATH}. Run Scripts 1 and 3 first."

  log_info "Stage 1/3: Collecting topic binding inputs."
  collect_topic_inputs

  log_info "Stage 2/3: Applying CTO topic binding."
  apply_cto_topic_binding

  log_info "Stage 3/3: Validating config and restarting gateway."
  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed after topic binding update."
  fi

  restart_gateway_background
  if ! wait_for_gateway_health 90; then
    die "Gateway health check timed out after topic binding update."
  fi

  log_info "CTO topic rebind completed successfully."
  log_info "Bound target: ${BIND_GROUP_ID}:topic:${BIND_TOPIC_ID}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
