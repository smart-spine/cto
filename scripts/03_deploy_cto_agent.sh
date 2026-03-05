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
CTO_SEED_DIR="${CTO_SEED_DIR:-${SCRIPT_DIR}/../cto-factory}"
CTO_MODEL="${CTO_MODEL:-openai/gpt-5.2}"
SKIP_CTO_HEALTH_SMOKE="${SKIP_CTO_HEALTH_SMOKE:-false}"
BIND_DIRECT_USER_ID="${BIND_DIRECT_USER_ID:-}"
TELEGRAM_ALLOWED_USER_ID="${TELEGRAM_ALLOWED_USER_ID:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

sync_cto_workspace() {
  local source_workspace="${CTO_SEED_DIR}"
  [[ -d "${source_workspace}" ]] || die "CTO seed directory not found: ${source_workspace}"
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
needles = [
    "/Users/uladzislaupraskou/.openclaw",
    "/home/ubuntu/.openclaw",
]
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
    updated_text = text
    for needle in needles:
        if needle in updated_text:
            updated_text = updated_text.replace(needle, openclaw_home)
    if updated_text != text:
        path.write_text(updated_text, encoding="utf-8")
        updated += 1

print(updated)
PY
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

agent_list = agents.setdefault("list", [])
cto_payload = {
    "id": "cto-factory",
    "default": False,
    "name": "CTO Factory",
    "workspace": str(openclaw_home / "workspace-factory"),
    "agentDir": str(openclaw_home / "agents/cto-factory/agent"),
    "model": {"primary": cto_model},
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

apply_cto_direct_binding() {
  local direct_user_id="$1"
  local config_path="${OPENCLAW_CONFIG_PATH}"
  backup_file "${config_path}"
  python3 - "${config_path}" "${direct_user_id}" "${TELEGRAM_ALLOWED_USER_ID}" "${TELEGRAM_BOT_TOKEN:-}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
direct_user_id = (sys.argv[2] or "").strip()
allowed_uid = (sys.argv[3] or "").strip()
telegram_bot_token = sys.argv[4]

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

if not direct_user_id:
    if allowed_uid:
        direct_user_id = allowed_uid
    else:
        candidates = []
        candidates.extend(default_account.get("allowFrom", []) or [])
        candidates.extend(telegram.get("allowFrom", []) or [])
        candidates.extend(default_account.get("groupAllowFrom", []) or [])
        candidates.extend(telegram.get("groupAllowFrom", []) or [])
        for candidate in candidates:
            candidate = str(candidate).strip()
            if candidate and candidate != "*":
                direct_user_id = candidate
                break

if not direct_user_id:
    raise SystemExit(
        "Direct binding requires Telegram user ID. Set BIND_DIRECT_USER_ID or TELEGRAM_ALLOWED_USER_ID."
    )

if not allowed_uid:
    allowed_uid = direct_user_id

bindings = data.setdefault("bindings", [])
bindings = [b for b in bindings if not (isinstance(b, dict) and b.get("agentId") == "cto-factory")]
bindings.append(
    {
        "agentId": "cto-factory",
        "match": {
            "channel": "telegram",
            "accountId": "default",
            "peer": {"kind": "direct", "id": direct_user_id},
        },
    }
)
data["bindings"] = bindings

for key in ("allowFrom", "groupAllowFrom"):
    global_allow = {str(x).strip() for x in telegram.get(key, []) if str(x).strip()}
    global_allow.add(allowed_uid)
    telegram[key] = sorted(global_allow)

    account_allow = {str(x).strip() for x in default_account.get(key, []) if str(x).strip()}
    account_allow.add(allowed_uid)
    default_account[key] = sorted(account_allow)

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(direct_user_id)
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

  if [[ "${SKIP_CTO_HEALTH_SMOKE}" == "true" ]]; then
    log_warn "Skipping CTO local smoke because SKIP_CTO_HEALTH_SMOKE=true."
    return 0
  fi

  local cto_output=""
  if ! cto_output="$(with_openclaw_env openclaw agent --local --agent cto-factory --message "Reply with CTO_FACTORY_OK and one sentence status." --json --timeout 240 2>&1)"; then
    printf "%s\n" "${cto_output}" >&2
    die "CTO agent local call failed."
  fi
  if ! printf "%s" "${cto_output}" | grep -q "CTO_FACTORY_OK"; then
    log_warn "CTO local call succeeded but did not return CTO_FACTORY_OK marker."
  fi
}

collect_direct_binding_input() {
  if [[ -z "${BIND_DIRECT_USER_ID}" && -n "${TELEGRAM_ALLOWED_USER_ID}" ]]; then
    BIND_DIRECT_USER_ID="${TELEGRAM_ALLOWED_USER_ID}"
  fi

  if [[ -z "${BIND_DIRECT_USER_ID}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      die "For NON_INTERACTIVE=true set BIND_DIRECT_USER_ID or TELEGRAM_ALLOWED_USER_ID."
    fi
    user_section "User input required"
    user_step "Enter your Telegram numeric user ID for direct chat routing."
    read -r -p "Telegram user ID for direct chat binding: " BIND_DIRECT_USER_ID
  fi

  [[ -n "${BIND_DIRECT_USER_ID}" ]] || die "Telegram user ID is required for direct binding."

  if [[ -z "${TELEGRAM_ALLOWED_USER_ID}" ]]; then
    TELEGRAM_ALLOWED_USER_ID="${BIND_DIRECT_USER_ID}"
  fi
}

main() {
  require_cmd rsync
  require_cmd jq
  require_cmd python3
  require_cmd openclaw
  require_cmd codex

  [[ -f "${OPENCLAW_CONFIG_PATH}" ]] || die "Missing ${OPENCLAW_CONFIG_PATH}. Run Script 1 first."

  log_info "Stage 1/5: Syncing CTO workspace files."
  sync_cto_workspace
  rewrite_hardcoded_paths
  ensure_dir "${OPENCLAW_HOME}/agents/cto-factory/agent"

  log_info "Stage 2/5: Applying CTO agent config patch."
  upsert_cto_agent_config

  log_info "Stage 3/5: Restarting gateway before health checks."
  restart_gateway_background
  if ! wait_for_gateway_health 90; then
    die "Gateway health check timed out during CTO deployment."
  fi

  log_info "Stage 4/5: Validating CTO deployment health."
  run_health_checks

  log_info "Stage 5/5: Applying direct Telegram binding for CTO."
  user_section "Deploy ready: direct Telegram binding"
  user_step "This script binds CTO to direct chat with your Telegram user."
  collect_direct_binding_input

  local bound_user
  bound_user="$(apply_cto_direct_binding "${BIND_DIRECT_USER_ID}")"

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
  log_info "Bound target: direct:${bound_user}"
  user_section "Done"
  user_step "CTO is now reachable in direct chat with your bot."
  user_step "For topic/group routing, run: ./scripts/04_rebind_cto_to_topic.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
