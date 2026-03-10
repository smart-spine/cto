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
  echo "[ERROR] Could not resolve script directory. Run from repo root: ./scripts/03_deploy_cto_agent.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_HOME}/openclaw.json"
CTO_REPO_URL="${CTO_REPO_URL:-https://github.com/smart-spine/cto-agent.git}"
CTO_REPO_BRANCH="${CTO_REPO_BRANCH:-main}"
CTO_MODEL="${CTO_MODEL:-openai/gpt-5.2}"
BIND_MODE="${BIND_MODE:-}"
BIND_TELEGRAM_LINK="${BIND_TELEGRAM_LINK:-}"
BIND_GROUP_ID="${BIND_GROUP_ID:-}"
BIND_TOPIC_ID="${BIND_TOPIC_ID:-}"
BIND_DIRECT_USER_ID="${BIND_DIRECT_USER_ID:-}"
TELEGRAM_ALLOWED_USER_ID="${TELEGRAM_ALLOWED_USER_ID:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

TMP_REPO_DIR=""

cleanup() {
  if [[ -n "${TMP_REPO_DIR}" && -d "${TMP_REPO_DIR}" ]]; then
    rm -rf "${TMP_REPO_DIR}"
  fi
}
trap cleanup EXIT

resolve_repo_branch() {
  local requested="$1"
  if git ls-remote --exit-code --heads "${CTO_REPO_URL}" "refs/heads/${requested}" >/dev/null 2>&1; then
    printf "%s" "${requested}"
    return 0
  fi
  if git ls-remote --exit-code --heads "${CTO_REPO_URL}" "refs/heads/main" >/dev/null 2>&1; then
    if [[ "${requested}" != "main" ]]; then
      log_warn "Requested branch '${requested}' not found. Falling back to 'main'."
    fi
    printf "main"
    return 0
  fi
  die "Could not resolve a valid branch in ${CTO_REPO_URL}."
}

clone_cto_repo() {
  local resolved_branch="$1"
  TMP_REPO_DIR="$(mktemp -d)"
  log_info "Cloning CTO repository branch '${resolved_branch}'."
  git clone --depth 1 --branch "${resolved_branch}" "${CTO_REPO_URL}" "${TMP_REPO_DIR}" >/dev/null
  [[ -d "${TMP_REPO_DIR}/workspace-factory" ]] || die "workspace-factory not found in cloned repo."
}

sync_cto_workspace() {
  local source_workspace="${TMP_REPO_DIR}/workspace-factory"
  local target_workspace="${OPENCLAW_HOME}/workspace-factory"
  ensure_dir "${target_workspace}"

  local target_has_memory="false"
  if [[ -d "${target_workspace}/.cto-brain" ]]; then
    target_has_memory="true"
  fi

  log_info "Syncing workspace-factory files."
  rsync -a --delete --exclude '.cto-brain/' "${source_workspace}/" "${target_workspace}/"

  if [[ -d "${source_workspace}/.cto-brain" ]]; then
    ensure_dir "${target_workspace}/.cto-brain"
    if [[ "${target_has_memory}" == "true" ]]; then
      log_info "Merging source memory into existing target .cto-brain without overwriting existing notes."
      rsync -a --ignore-existing "${source_workspace}/.cto-brain/" "${target_workspace}/.cto-brain/"
    else
      log_info "Copying .cto-brain memory seed from source repository."
      rsync -a "${source_workspace}/.cto-brain/" "${target_workspace}/.cto-brain/"
    fi
  else
    log_warn "Source repository does not contain .cto-brain (git-ignored). Existing target memory was preserved."
  fi
}

rewrite_hardcoded_paths() {
  local target_workspace="${OPENCLAW_HOME}/workspace-factory"
  log_info "Rewriting hardcoded local paths in copied CTO files."
  python3 - "${target_workspace}" "${OPENCLAW_HOME}" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
openclaw_home = sys.argv[2]
needle = "/Users/uladzislaupraskou/.openclaw"
extensions = {".md", ".sh", ".txt", ".json", ".yaml", ".yml"}
updated = 0

for path in root.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix not in extensions:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        continue
    if needle not in text:
        continue
    path.write_text(text.replace(needle, openclaw_home), encoding="utf-8")
    updated += 1

print(updated)
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
token = (
    default.get("botToken")
    or telegram.get("botToken")
    or ""
)
print(str(token).strip())
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
        # Accept non-standard links like /c/<username>/<topic>.
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

upsert_cto_agent_config() {
  local config_path="${OPENCLAW_CONFIG_PATH}"
  backup_file "${config_path}"
  python3 - "${config_path}" "${OPENCLAW_HOME}" "${CTO_MODEL}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
openclaw_home = pathlib.Path(sys.argv[2])
cto_model = sys.argv[3]

data = json.loads(config_path.read_text(encoding="utf-8"))

agents = data.setdefault("agents", {})
if isinstance(agents, list):
    agents = {"list": agents}
    data["agents"] = agents

defaults = agents.setdefault("defaults", {})
try:
    timeout_seconds = int(defaults.get("timeoutSeconds") or 0)
except Exception:
    timeout_seconds = 0
if timeout_seconds < 3600:
    defaults["timeoutSeconds"] = 3600

agent_list = agents.setdefault("list", [])
cto_payload = {
    "id": "cto-factory",
    "default": False,
    "name": "CTO Factory",
    "workspace": str(openclaw_home / "workspace-factory"),
    "agentDir": str(openclaw_home / "agents/cto-factory/agent"),
    "model": {"primary": cto_model},
    "heartbeat": {
        "every": "5m",
        "prompt": "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK.",
        "target": "none",
        "ackMaxChars": 300,
    },
    "identity": {
        "name": "CTO Factory Agent",
        "theme": "engineering",
        "emoji": "factory",
    },
}

found = False
for i, item in enumerate(agent_list):
    if isinstance(item, dict) and item.get("id") == "cto-factory":
        agent_list[i] = cto_payload
        found = True
        break
if not found:
    agent_list.append(cto_payload)

tools = data.setdefault("tools", {})
sessions = tools.setdefault("sessions", {})
sessions["visibility"] = "all"

agent_to_agent = tools.setdefault("agentToAgent", {})
agent_to_agent["enabled"] = True
allow = agent_to_agent.get("allow", [])
if not isinstance(allow, list):
    allow = []
for name in ("cto-factory", "main"):
    if name not in allow:
        allow.append(name)
agent_to_agent["allow"] = allow

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

apply_cto_binding() {
  local bind_mode="$1"
  local group_id="$2"
  local topic_id="$3"
  local direct_user_id="$4"
  local config_path="${OPENCLAW_CONFIG_PATH}"
  backup_file "${config_path}"
  python3 - "${config_path}" "${bind_mode}" "${group_id}" "${topic_id}" "${TELEGRAM_ALLOWED_USER_ID}" "${TELEGRAM_BOT_TOKEN:-}" "${direct_user_id}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
bind_mode = sys.argv[2].strip()
group_id = sys.argv[3].strip()
topic_id = sys.argv[4].strip()
allowed_uid = sys.argv[5].strip()
telegram_bot_token = sys.argv[6]
direct_user_id = sys.argv[7].strip()

data = json.loads(config_path.read_text(encoding="utf-8"))

bindings = data.setdefault("bindings", [])
bindings = [b for b in bindings if not (isinstance(b, dict) and b.get("agentId") == "cto-factory")]

if bind_mode == "topic":
    if not group_id or not topic_id:
        raise SystemExit("Topic binding requires group_id and topic_id.")
    peer = {"kind": "group", "id": f"{group_id}:topic:{topic_id}"}
elif bind_mode == "direct":
    if not direct_user_id:
        direct_user_id = allowed_uid
    peer = {"kind": "direct", "id": direct_user_id}
else:
    raise SystemExit(f"Unsupported bind mode: {bind_mode}")

bindings.append({"agentId": "cto-factory", "match": {"channel": "telegram", "accountId": "default", "peer": peer}})
data["bindings"] = bindings

channels = data.setdefault("channels", {})
telegram = channels.setdefault("telegram", {})
telegram["enabled"] = True
telegram.setdefault("commands", {})["native"] = True
default_account = telegram.setdefault("accounts", {}).setdefault("default", {})
if telegram_bot_token:
    default_account["botToken"] = telegram_bot_token
telegram.setdefault("groupPolicy", "allowlist")
default_account.setdefault("groupPolicy", "allowlist")

if bind_mode == "direct" and not allowed_uid and direct_user_id:
    allowed_uid = direct_user_id

if not allowed_uid:
    # Auto-seed from existing allowlists so a newly bound route does not become unreachable.
    account_allow = default_account.get("groupAllowFrom", [])
    global_allow = telegram.get("groupAllowFrom", [])
    for candidate in list(account_allow) + list(global_allow):
        candidate = str(candidate).strip()
        if candidate:
            allowed_uid = candidate
            break

if bind_mode == "direct" and not direct_user_id:
    # Fall back to DM allowlists if direct user id was not explicitly provided.
    dm_candidates = []
    dm_candidates.extend(default_account.get("allowFrom", []) or [])
    dm_candidates.extend(telegram.get("allowFrom", []) or [])
    dm_candidates.extend(default_account.get("groupAllowFrom", []) or [])
    dm_candidates.extend(telegram.get("groupAllowFrom", []) or [])
    for candidate in dm_candidates:
        candidate = str(candidate).strip()
        if candidate and candidate != "*":
            direct_user_id = candidate
            break
    if not direct_user_id:
        raise SystemExit(
            "Direct binding requires Telegram user ID. Set BIND_DIRECT_USER_ID or TELEGRAM_ALLOWED_USER_ID."
        )
    peer["id"] = direct_user_id
    if not allowed_uid:
        allowed_uid = direct_user_id

group_cfg = None
if bind_mode == "topic":
    groups = telegram.setdefault("groups", {})
    group_cfg = groups.setdefault(group_id, {})
    group_cfg.setdefault("groupPolicy", "allowlist")
    topics = group_cfg.setdefault("topics", {})
    topic_cfg = topics.setdefault(topic_id, {})
    topic_cfg.setdefault("requireMention", False)
    topic_cfg.setdefault("groupPolicy", "allowlist")

if allowed_uid:
    global_allow = set(str(x) for x in telegram.get("groupAllowFrom", []) if str(x).strip())
    global_allow.add(allowed_uid)
    telegram["groupAllowFrom"] = sorted(global_allow)
    account_allow = set(str(x) for x in default_account.get("groupAllowFrom", []) if str(x).strip())
    account_allow.add(allowed_uid)
    default_account["groupAllowFrom"] = sorted(account_allow)

    dm_allow = set(str(x) for x in telegram.get("allowFrom", []) if str(x).strip())
    dm_allow.add(allowed_uid)
    telegram["allowFrom"] = sorted(dm_allow)
    account_dm_allow = set(str(x) for x in default_account.get("allowFrom", []) if str(x).strip())
    account_dm_allow.add(allowed_uid)
    default_account["allowFrom"] = sorted(account_dm_allow)

    if bind_mode == "topic" and group_cfg is not None:
      group_allow = set(str(x) for x in group_cfg.get("allowFrom", []) if str(x).strip())
      group_allow.add(allowed_uid)
      group_cfg["allowFrom"] = sorted(group_allow)

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

run_health_checks() {
  log_info "Running deployment health checks."
  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed after CTO deployment."
  fi

  codex --version >/dev/null

  local cto_output=""
  if ! cto_output="$(with_openclaw_env openclaw agent --local --agent cto-factory --message "Reply with CTO_FACTORY_OK and one sentence status." --json --timeout 240 2>&1)"; then
    printf "%s\n" "${cto_output}" >&2
    die "CTO agent local call failed."
  fi
  if ! printf "%s" "${cto_output}" | grep -q "CTO_FACTORY_OK"; then
    log_warn "CTO local call succeeded but did not return CTO_FACTORY_OK marker."
  fi
}

collect_binding_inputs() {
  if [[ -z "${BIND_MODE}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      BIND_MODE="topic"
    else
      read -r -p "Bind CTO bot to [topic/direct] (default: topic): " BIND_MODE
      BIND_MODE="${BIND_MODE:-topic}"
    fi
  fi
  BIND_MODE="$(normalize_bind_mode "${BIND_MODE}")"

  if [[ "${BIND_MODE}" == "topic" ]]; then
    if [[ -z "${BIND_TELEGRAM_LINK}" && -z "${BIND_GROUP_ID}" && -z "${BIND_TOPIC_ID}" && "${NON_INTERACTIVE}" != "true" ]]; then
      read -r -p "Telegram topic link (example: https://t.me/c/1234567890/42): " BIND_TELEGRAM_LINK
    fi

    if [[ -n "${BIND_TELEGRAM_LINK}" ]]; then
      local telegram_token="${TELEGRAM_BOT_TOKEN:-}"
      if [[ -z "${telegram_token}" ]]; then
        telegram_token="$(load_telegram_bot_token_from_config)"
      fi
      if ! parse_telegram_topic_link "${BIND_TELEGRAM_LINK}" "${telegram_token}"; then
        die "Failed to parse Telegram link '${BIND_TELEGRAM_LINK}'. Use t.me/c/<group>/<topic> or provide explicit IDs."
      fi
      log_info "Parsed Telegram link -> group ${BIND_GROUP_ID}, topic ${BIND_TOPIC_ID}."
    fi

    if [[ "${NON_INTERACTIVE}" == "true" && ( -z "${BIND_GROUP_ID}" || -z "${BIND_TOPIC_ID}" ) ]]; then
      die "For topic binding with NON_INTERACTIVE=true set BIND_TELEGRAM_LINK or BIND_GROUP_ID and BIND_TOPIC_ID."
    fi

    if [[ -z "${BIND_GROUP_ID}" && "${NON_INTERACTIVE}" != "true" ]]; then
      read -r -p "Group ID (e.g. -1001234567890): " BIND_GROUP_ID
    fi
    if [[ -z "${BIND_TOPIC_ID}" && "${NON_INTERACTIVE}" != "true" ]]; then
      read -r -p "Topic ID (e.g. 42): " BIND_TOPIC_ID
    fi
    [[ -n "${BIND_GROUP_ID}" ]] || die "Group ID is required for topic binding."
    [[ -n "${BIND_TOPIC_ID}" ]] || die "Topic ID is required for topic binding."

    if [[ -z "${TELEGRAM_ALLOWED_USER_ID}" && "${NON_INTERACTIVE}" != "true" ]]; then
      read -r -p "Telegram user ID to allow (optional; blank = auto from existing allowlist): " TELEGRAM_ALLOWED_USER_ID
    fi
    return 0
  fi

  if [[ -z "${BIND_DIRECT_USER_ID}" && -n "${TELEGRAM_ALLOWED_USER_ID}" ]]; then
    BIND_DIRECT_USER_ID="${TELEGRAM_ALLOWED_USER_ID}"
  fi
  if [[ -z "${BIND_DIRECT_USER_ID}" && "${NON_INTERACTIVE}" != "true" ]]; then
    read -r -p "Telegram user ID for direct-chat binding (optional; blank = auto from existing allowlist): " BIND_DIRECT_USER_ID
  fi
  if [[ -z "${TELEGRAM_ALLOWED_USER_ID}" ]]; then
    TELEGRAM_ALLOWED_USER_ID="${BIND_DIRECT_USER_ID}"
  fi
}

main() {
  require_cmd git
  require_cmd rsync
  require_cmd jq
  require_cmd python3
  require_cmd openclaw
  require_cmd codex

  [[ -f "${OPENCLAW_CONFIG_PATH}" ]] || die "Missing ${OPENCLAW_CONFIG_PATH}. Run Script 1 first."

  log_info "Stage 1/7: Resolving repository branch."
  local resolved_branch
  resolved_branch="$(resolve_repo_branch "${CTO_REPO_BRANCH}")"
  log_info "Using CTO source branch: ${resolved_branch}"

  log_info "Stage 2/7: Cloning CTO repository."
  clone_cto_repo "${resolved_branch}"

  log_info "Stage 3/7: Syncing CTO workspace files."
  sync_cto_workspace
  rewrite_hardcoded_paths
  ensure_dir "${OPENCLAW_HOME}/agents/cto-factory/agent"

  log_info "Stage 4/7: Applying CTO agent config patch."
  upsert_cto_agent_config

  log_info "Stage 5/7: Restarting gateway before health checks."
  restart_gateway_background
  if ! wait_for_gateway_health 90; then
    die "Gateway health check timed out during CTO deployment."
  fi

  log_info "Stage 6/7: Validating CTO deployment health."
  run_health_checks

  log_info "Stage 7/7: Applying Telegram binding for CTO."
  echo "Deploy ready. Choose how to bind CTO bot: Telegram topic link or direct chat."
  collect_binding_inputs
  apply_cto_binding "${BIND_MODE}" "${BIND_GROUP_ID}" "${BIND_TOPIC_ID}" "${BIND_DIRECT_USER_ID}"

  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed after binding update."
  fi

  restart_gateway_background
  if ! wait_for_gateway_health 90; then
    die "Gateway health check timed out after binding update."
  fi

  log_info "CTO agent deployment completed successfully."
  if [[ "${BIND_MODE}" == "topic" ]]; then
    log_info "Bound target: ${BIND_GROUP_ID}:topic:${BIND_TOPIC_ID}"
  else
    log_info "Bound target: direct:${BIND_DIRECT_USER_ID:-auto-from-allowlist}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
