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
CTO_REPO_URL="${CTO_REPO_URL:-https://github.com/no-name-labs/cto.git}"
CTO_REPO_BRANCH="${CTO_REPO_BRANCH:-}"
CTO_MODEL="${CTO_MODEL:-}"
BIND_MODE="${BIND_MODE:-}"
BIND_TELEGRAM_LINK="${BIND_TELEGRAM_LINK:-}"
BIND_GROUP_ID="${BIND_GROUP_ID:-}"
BIND_TOPIC_ID="${BIND_TOPIC_ID:-}"
BIND_DIRECT_USER_ID="${BIND_DIRECT_USER_ID:-}"
TELEGRAM_ALLOWED_USER_ID="${TELEGRAM_ALLOWED_USER_ID:-}"
LAST_PAIRED_TELEGRAM_USER_ID="${LAST_PAIRED_TELEGRAM_USER_ID:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
MODEL_PROVIDERS_ALLOWLIST="${MODEL_PROVIDERS_ALLOWLIST:-}"
MODEL_ALLOWLIST_STRICT="${MODEL_ALLOWLIST_STRICT:-true}"

TMP_REPO_DIR=""
SOURCE_FACTORY_DIR=""

detect_local_repo_branch() {
  local candidate=""
  if git -C "${SCRIPT_DIR}/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    candidate="$(git -C "${SCRIPT_DIR}/.." rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    candidate="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  if [[ -n "${candidate}" && "${candidate}" != "HEAD" ]]; then
    printf "%s" "${candidate}"
    return 0
  fi

  printf "main"
}

load_binding_defaults_from_env() {
  local env_file="${OPENCLAW_HOME}/.env"
  [[ -f "${env_file}" ]] || return 0
  local cur_bind_mode="${BIND_MODE}"
  local cur_bind_link="${BIND_TELEGRAM_LINK}"
  local cur_bind_group="${BIND_GROUP_ID}"
  local cur_bind_topic="${BIND_TOPIC_ID}"
  local cur_bind_direct="${BIND_DIRECT_USER_ID}"
  local cur_allowed_uid="${TELEGRAM_ALLOWED_USER_ID}"
  local cur_last_paired_uid="${LAST_PAIRED_TELEGRAM_USER_ID}"
  # shellcheck disable=SC1090
  source "${env_file}"
  [[ -n "${cur_bind_mode}" ]] && BIND_MODE="${cur_bind_mode}"
  [[ -n "${cur_bind_link}" ]] && BIND_TELEGRAM_LINK="${cur_bind_link}"
  [[ -n "${cur_bind_group}" ]] && BIND_GROUP_ID="${cur_bind_group}"
  [[ -n "${cur_bind_topic}" ]] && BIND_TOPIC_ID="${cur_bind_topic}"
  [[ -n "${cur_bind_direct}" ]] && BIND_DIRECT_USER_ID="${cur_bind_direct}"
  [[ -n "${cur_allowed_uid}" ]] && TELEGRAM_ALLOWED_USER_ID="${cur_allowed_uid}"
  [[ -n "${cur_last_paired_uid}" ]] && LAST_PAIRED_TELEGRAM_USER_ID="${cur_last_paired_uid}"
  return 0
}

resolve_model_provider_allowlist() {
  if [[ -n "${MODEL_PROVIDERS_ALLOWLIST}" ]]; then
    return 0
  fi

  local runtime_provider_id="${OPENCLAW_RUNTIME_PROVIDER_ID:-}"
  local runtime_provider="${OPENCLAW_RUNTIME_PROVIDER:-}"

  if [[ -z "${runtime_provider_id}" || -z "${runtime_provider}" ]]; then
    local env_file="${OPENCLAW_HOME}/.env"
    if [[ -f "${env_file}" ]]; then
      runtime_provider_id="${runtime_provider_id:-$(grep -E '^OPENCLAW_RUNTIME_PROVIDER_ID=' "${env_file}" | tail -n1 | cut -d= -f2- || true)}"
      runtime_provider="${runtime_provider:-$(grep -E '^OPENCLAW_RUNTIME_PROVIDER=' "${env_file}" | tail -n1 | cut -d= -f2- || true)}"
    fi
  fi

  case "${runtime_provider_id:-${runtime_provider}}" in
    anthropic)
      MODEL_PROVIDERS_ALLOWLIST="anthropic"
      ;;
    openai-codex)
      MODEL_PROVIDERS_ALLOWLIST="openai,openai-codex"
      ;;
    openai|"")
      MODEL_PROVIDERS_ALLOWLIST="openai,openai-codex"
      ;;
    *)
      # Safe fallback: keep the runtime provider only.
      MODEL_PROVIDERS_ALLOWLIST="${runtime_provider_id:-${runtime_provider}}"
      ;;
  esac

  log_info "Resolved MODEL_PROVIDERS_ALLOWLIST=${MODEL_PROVIDERS_ALLOWLIST}."
}

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
  if [[ -d "${TMP_REPO_DIR}/cto-factory" ]]; then
    SOURCE_FACTORY_DIR="${TMP_REPO_DIR}/cto-factory"
  elif [[ -d "${TMP_REPO_DIR}/workspace-factory" ]]; then
    SOURCE_FACTORY_DIR="${TMP_REPO_DIR}/workspace-factory"
  else
    die "Neither cto-factory nor workspace-factory found in cloned repo."
  fi
  log_info "Using source factory directory: ${SOURCE_FACTORY_DIR}"
}

sync_cto_workspace() {
  local source_workspace="${SOURCE_FACTORY_DIR}"
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
import re
import sys

root = pathlib.Path(sys.argv[1])
openclaw_home = sys.argv[2]
path_patterns = [
    re.compile(r"/Users/[^/\s]+/.openclaw"),
    re.compile(r"/home/[^/\s]+/.openclaw"),
    re.compile(r"/root/.openclaw"),
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
    new_text = text
    for pattern in path_patterns:
        new_text = pattern.sub(openclaw_home, new_text)
    if new_text == text:
        continue
    path.write_text(new_text, encoding="utf-8")
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
  python3 - "${config_path}" "${OPENCLAW_HOME}" "${CTO_MODEL}" "${MODEL_PROVIDERS_ALLOWLIST}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
openclaw_home = pathlib.Path(sys.argv[2])
cto_model = sys.argv[3]
providers_arg = sys.argv[4] if len(sys.argv) > 4 else ""

provider_allowlist = [p.strip() for p in providers_arg.split(",") if p.strip()]
provider_mode = "anthropic" if provider_allowlist == ["anthropic"] else "openai"


def uniq(seq):
    seen = set()
    out = []
    for item in seq:
        if not item or item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def pick_first(candidates, allowed):
    for m in candidates:
        if not m:
            continue
        if not allowed or m in allowed:
            return m
    return ""

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

defaults_models = defaults.get("models") or {}
allowed_models = [m for m in defaults_models.keys() if isinstance(m, str)] if isinstance(defaults_models, dict) else []
allowed_set = set(allowed_models)

if provider_mode == "anthropic":
    preferred_primary = [
        cto_model,
        "anthropic/claude-opus-4-6",
        "anthropic/claude-opus-4-5",
        "anthropic/claude-opus-4-1",
        "anthropic/claude-opus-4-0",
        "anthropic/claude-sonnet-4-6",
        "anthropic/claude-sonnet-4-5",
    ]
    preferred_fallbacks = [
        "anthropic/claude-opus-4-5",
        "anthropic/claude-opus-4-1",
        "anthropic/claude-opus-4-0",
        "anthropic/claude-sonnet-4-6",
        "anthropic/claude-sonnet-4-5",
        "anthropic/claude-3-7-sonnet-latest",
        "anthropic/claude-3-5-sonnet-20241022",
    ]
    preferred_heartbeat = [
        "anthropic/claude-3-5-haiku-latest",
        "anthropic/claude-3-5-haiku-20241022",
        "anthropic/claude-3-haiku-20240307",
        "anthropic/claude-haiku-4-5",
        "anthropic/claude-haiku-4-5-20251001",
    ]
else:
    preferred_primary = [
        cto_model,
        "openai/gpt-5.3-codex",
        "openai-codex/gpt-5.4",
        "openai/gpt-5.2-codex",
        "openai/gpt-5.2",
    ]
    preferred_fallbacks = [
        "openai-codex/gpt-5.4",
        "openai/gpt-5.2-codex",
        "openai/gpt-5.2",
        "openai/gpt-4.1",
    ]
    preferred_heartbeat = [
        "openai/gpt-5-nano",
        "openai/gpt-4.1-mini",
        "openai/gpt-4o-mini",
        "openai/gpt-5.2",
    ]

preferred_primary = uniq(preferred_primary)
preferred_fallbacks = uniq(preferred_fallbacks)
preferred_heartbeat = uniq(preferred_heartbeat)

selected_primary = pick_first(preferred_primary, allowed_set)
if not selected_primary and allowed_models:
    selected_primary = allowed_models[0]
if not selected_primary:
    selected_primary = cto_model or ("anthropic/claude-opus-4-5" if provider_mode == "anthropic" else "openai/gpt-5.3-codex")

selected_fallbacks = []
for m in preferred_fallbacks:
    if m == selected_primary:
        continue
    if allowed_set and m not in allowed_set:
        continue
    selected_fallbacks.append(m)
selected_fallbacks = uniq(selected_fallbacks)[:3]

if not selected_fallbacks and allowed_models:
    for m in allowed_models:
        if m == selected_primary:
            continue
        selected_fallbacks.append(m)
        if len(selected_fallbacks) >= 3:
            break
    selected_fallbacks = uniq(selected_fallbacks)

heartbeat_model = pick_first(preferred_heartbeat, allowed_set)
if not heartbeat_model:
    heartbeat_model = selected_fallbacks[-1] if selected_fallbacks else selected_primary

agent_list = agents.setdefault("list", [])
model_payload = {"primary": selected_primary}
if selected_fallbacks:
    model_payload["fallbacks"] = selected_fallbacks

cto_payload = {
    "id": "cto-factory",
    "default": False,
    "name": "CTO Factory",
    "workspace": str(openclaw_home / "workspace-factory"),
    "agentDir": str(openclaw_home / "agents/cto-factory/agent"),
    "model": model_payload,
    "heartbeat": {
        "every": "1h",
        "prompt": "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK.",
        "target": "none",
        "ackMaxChars": 300,
        "model": {"primary": heartbeat_model},
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

  local remember_cmd="${OPENCLAW_HOME}/workspace-factory/scripts/cto_code_agent_memory.py"
  [[ -x "${remember_cmd}" || -f "${remember_cmd}" ]] || die "Missing code-agent memory helper: ${remember_cmd}"

  local remember_out=""
  remember_out="$(python3 "${remember_cmd}" ensure --openclaw-root "${OPENCLAW_HOME}" 2>&1 || true)"
  if ! printf "%s" "${remember_out}" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf "%s\n" "${remember_out}" >&2
    die "Code-agent remember step failed."
  fi

  local remembered_agent remembered_ack remembered_memory_file remembered_facts_file
  remembered_agent="$(printf "%s" "${remember_out}" | jq -r '.codeAgent // empty')"
  remembered_ack="$(printf "%s" "${remember_out}" | jq -r '.ackPhrase // empty')"
  remembered_memory_file="$(printf "%s" "${remember_out}" | jq -r '.memoryFile // empty')"
  remembered_facts_file="$(printf "%s" "${remember_out}" | jq -r '.factsFile // empty')"

  case "${remembered_ack}" in
    "codex remembered"|"claudecode remembered") ;;
    *)
      printf "%s\n" "${remember_out}" >&2
      die "Unexpected code-agent remember marker: '${remembered_ack}'."
      ;;
  esac
  [[ -n "${remembered_memory_file}" && -s "${remembered_memory_file}" ]] || \
    die "Remembered memory file missing or empty: ${remembered_memory_file:-<empty>}"
  [[ -n "${remembered_facts_file}" && -s "${remembered_facts_file}" ]] || \
    die "Remembered facts file missing or empty: ${remembered_facts_file:-<empty>}"
  log_info "Remembered code agent: ${remembered_agent} (${remembered_ack})."

  local cto_output=""
  if ! cto_output="$(with_openclaw_env openclaw agent --local --agent cto-factory --message "Healthcheck: read code-agent memory and reply with exactly one marker phrase: codex remembered or claudecode remembered." --json --timeout 300 2>&1)"; then
    printf "%s\n" "${cto_output}" >&2
    die "CTO agent local call failed."
  fi

  local cto_marker=""
  cto_marker="$(python3 - "${cto_output}" <<'PY'
import re
import sys

text = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
patterns = [
    r"\bcodex\b[^a-z0-9]{0,8}\bremembered\b",
    r"\bclaudecode\b[^a-z0-9]{0,8}\bremembered\b",
]
for pat in patterns:
    m = re.search(pat, text, re.I)
    if m:
        raw = m.group(0)
        if "claudecode" in raw:
            print("claudecode remembered")
        else:
            print("codex remembered")
        raise SystemExit(0)
print("")
PY
)"
  if [[ -z "${cto_marker}" ]]; then
    printf "%s\n" "${cto_output}" >&2
    die "CTO local healthcheck did not return remembered marker phrase."
  fi
  if [[ "${cto_marker}" != "${remembered_ack}" ]]; then
    printf "%s\n" "${cto_output}" >&2
    die "CTO remember marker mismatch: expected '${remembered_ack}', got '${cto_marker}'."
  fi
  log_info "CTO remember marker validated: ${cto_marker}."
}

require_any_code_agent_cli() {
  if command -v codex >/dev/null 2>&1 || command -v claude >/dev/null 2>&1; then
    return 0
  fi
  die "No supported code-agent CLI found. Install Codex or Claude Code first (run Script 1)."
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

    if [[ -z "${TELEGRAM_ALLOWED_USER_ID}" && -n "${LAST_PAIRED_TELEGRAM_USER_ID}" ]]; then
      TELEGRAM_ALLOWED_USER_ID="${LAST_PAIRED_TELEGRAM_USER_ID}"
    fi
    if [[ -z "${TELEGRAM_ALLOWED_USER_ID}" && "${NON_INTERACTIVE}" != "true" ]]; then
      read -r -p "Telegram user ID to allow (optional; blank = auto from existing allowlist): " TELEGRAM_ALLOWED_USER_ID
    fi
    return 0
  fi

  if [[ -z "${BIND_DIRECT_USER_ID}" && -n "${TELEGRAM_ALLOWED_USER_ID}" ]]; then
    BIND_DIRECT_USER_ID="${TELEGRAM_ALLOWED_USER_ID}"
  fi
  if [[ -z "${BIND_DIRECT_USER_ID}" && -n "${LAST_PAIRED_TELEGRAM_USER_ID}" ]]; then
    BIND_DIRECT_USER_ID="${LAST_PAIRED_TELEGRAM_USER_ID}"
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
  require_any_code_agent_cli

  [[ -f "${OPENCLAW_CONFIG_PATH}" ]] || die "Missing ${OPENCLAW_CONFIG_PATH}. Run Script 1 first."
  if [[ -z "${CTO_REPO_BRANCH}" ]]; then
    CTO_REPO_BRANCH="$(detect_local_repo_branch)"
    log_info "CTO_REPO_BRANCH not set; defaulting to local branch '${CTO_REPO_BRANCH}'."
  fi
  load_binding_defaults_from_env
  resolve_model_provider_allowlist

  log_info "Stage 1/8: Resolving repository branch."
  local resolved_branch
  resolved_branch="$(resolve_repo_branch "${CTO_REPO_BRANCH}")"
  log_info "Using CTO source branch: ${resolved_branch}"

  log_info "Stage 2/8: Cloning CTO repository."
  clone_cto_repo "${resolved_branch}"

  log_info "Stage 3/8: Syncing CTO workspace files."
  sync_cto_workspace
  rewrite_hardcoded_paths
  ensure_dir "${OPENCLAW_HOME}/agents/cto-factory/agent"

  log_info "Stage 4/8: Applying CTO agent config patch."
  upsert_cto_agent_config

  log_info "Stage 5/8: Syncing allowed models from provider catalog."
  sync_allowed_models_from_provider_catalog

  log_info "Stage 6/8: Restarting gateway before health checks."
  restart_gateway_background
  if ! wait_for_gateway_health 90; then
    die "Gateway health check timed out during CTO deployment."
  fi

  log_info "Stage 7/8: Validating CTO deployment health."
  run_health_checks

  log_info "Stage 8/8: Applying Telegram binding for CTO."
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
