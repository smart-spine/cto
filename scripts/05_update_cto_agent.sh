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
  echo "[ERROR] Could not resolve script directory. Run from repo root: ./scripts/05_update_cto_agent.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_HOME}/openclaw.json"
CTO_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CTO_SEED_DIR="${CTO_SEED_DIR:-${CTO_REPO_ROOT}/cto-factory}"
DEPLOY_MANIFEST="${DEPLOY_MANIFEST:-${CTO_SEED_DIR}/DEPLOY_MANIFEST.txt}"
CTO_REPO_REF="${CTO_REPO_REF:-main}"
CTO_MODEL="${CTO_MODEL:-}"
OPENCLAW_AGENT_TIMEOUT_SECONDS="${OPENCLAW_AGENT_TIMEOUT_SECONDS:-3600}"
UPDATE_REPO="${UPDATE_REPO:-true}"
FORCE_MODEL_UPDATE="${FORCE_MODEL_UPDATE:-false}"
RESTART_GATEWAY="${RESTART_GATEWAY:-true}"
SKIP_CTO_HEALTH_SMOKE="${SKIP_CTO_HEALTH_SMOKE:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

BACKUP_DIR=""

confirm_if_needed() {
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    return 0
  fi
  user_section "CTO update confirmation"
  user_step "This will update cto-factory files in ${OPENCLAW_HOME}."
  user_step "A rollback backup will be created before changes."
  read -r -p "Continue? [y/N]: " answer
  answer="$(printf "%s" "${answer}" | tr '[:upper:]' '[:lower:]')"
  [[ "${answer}" == "y" || "${answer}" == "yes" ]] || die "Update aborted by user."
}

ensure_prerequisites() {
  require_cmd git
  require_cmd rsync
  require_cmd python3
  require_cmd jq
  require_cmd openclaw
  [[ -d "${CTO_SEED_DIR}" ]] || die "CTO seed directory not found: ${CTO_SEED_DIR}"
  [[ -f "${DEPLOY_MANIFEST}" ]] || die "Missing deploy manifest: ${DEPLOY_MANIFEST}"
  [[ -f "${OPENCLAW_CONFIG_PATH}" ]] || die "Missing ${OPENCLAW_CONFIG_PATH}. Run install/deploy first."
}

verify_manifest_paths() {
  local root="$1"
  local label="$2"
  local missing=0
  local rel=""

  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if [[ ! -e "${root}/${rel}" ]]; then
      log_error "Missing required path in ${label}: ${root}/${rel}"
      missing=$((missing + 1))
    fi
  done < <(awk '!/^[[:space:]]*(#|$)/{print}' "${DEPLOY_MANIFEST}")

  if (( missing > 0 )); then
    die "Manifest verification failed for ${label}: ${missing} paths missing."
  fi
}

update_repo_if_enabled() {
  if [[ "${UPDATE_REPO}" != "true" ]]; then
    log_info "Skipping repository update because UPDATE_REPO=false."
    return 0
  fi
  [[ -d "${CTO_REPO_ROOT}/.git" ]] || die "Repository metadata missing at ${CTO_REPO_ROOT}/.git."
  if [[ -n "$(git -C "${CTO_REPO_ROOT}" status --porcelain)" ]]; then
    die "Repository has local changes. Commit/stash first or set UPDATE_REPO=false."
  fi
  log_info "Updating deployment repository to ref '${CTO_REPO_REF}'."
  git -C "${CTO_REPO_ROOT}" fetch --all --prune
  git -C "${CTO_REPO_ROOT}" checkout "${CTO_REPO_REF}"
  git -C "${CTO_REPO_ROOT}" pull --ff-only origin "${CTO_REPO_REF}"
}

create_backup() {
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_DIR="${OPENCLAW_HOME}/backups/cto-update-${ts}"
  ensure_dir "${BACKUP_DIR}"
  cp "${OPENCLAW_CONFIG_PATH}" "${BACKUP_DIR}/openclaw.json"
  if [[ -d "${OPENCLAW_HOME}/workspace-factory" ]]; then
    rsync -a "${OPENCLAW_HOME}/workspace-factory/" "${BACKUP_DIR}/workspace-factory/"
  fi
  log_info "Backup created at ${BACKUP_DIR}."
}

rollback_from_backup() {
  local exit_code="$1"
  set +e
  log_error "Update failed. Rolling back from ${BACKUP_DIR}."
  if [[ -f "${BACKUP_DIR}/openclaw.json" ]]; then
    cp "${BACKUP_DIR}/openclaw.json" "${OPENCLAW_CONFIG_PATH}"
  fi
  if [[ -d "${BACKUP_DIR}/workspace-factory" ]]; then
    rm -rf "${OPENCLAW_HOME}/workspace-factory"
    ensure_dir "${OPENCLAW_HOME}/workspace-factory"
    rsync -a "${BACKUP_DIR}/workspace-factory/" "${OPENCLAW_HOME}/workspace-factory/"
  fi
  if [[ "${RESTART_GATEWAY}" == "true" ]]; then
    restart_gateway_background || true
    wait_for_gateway_health 60 || true
  fi
  exit "${exit_code}"
}

on_error() {
  local ec="$?"
  rollback_from_backup "${ec}"
}

sync_workspace_files() {
  local source_workspace="${CTO_SEED_DIR}"
  local target_workspace="${OPENCLAW_HOME}/workspace-factory"
  local target_has_memory="false"

  verify_manifest_paths "${source_workspace}" "seed"

  if [[ -d "${target_workspace}/.cto-brain" ]]; then
    target_has_memory="true"
  fi

  ensure_dir "${target_workspace}"
  log_info "Syncing CTO workspace files."
  rsync -a --delete --exclude '.cto-brain/' "${source_workspace}/" "${target_workspace}/"

  if [[ -d "${source_workspace}/.cto-brain" ]]; then
    ensure_dir "${target_workspace}/.cto-brain"
    if [[ "${target_has_memory}" == "true" ]]; then
      log_info "Merging source memory seed into existing target .cto-brain (no overwrite)."
      rsync -a --ignore-existing "${source_workspace}/.cto-brain/" "${target_workspace}/.cto-brain/"
    else
      rsync -a "${source_workspace}/.cto-brain/" "${target_workspace}/.cto-brain/"
    fi
  else
    log_warn "Source .cto-brain not found (expected when git-ignored). Existing target memory preserved."
  fi

  verify_manifest_paths "${target_workspace}" "target"
}

rewrite_hardcoded_paths() {
  local target_workspace="${OPENCLAW_HOME}/workspace-factory"
  log_info "Rewriting hardcoded local paths in copied files."
  python3 - "${target_workspace}" "${OPENCLAW_HOME}" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
openclaw_home = sys.argv[2]
needles = [
    "/Users/uladzislaupraskou/.openclaw",
    "/home/ubuntu/.openclaw",
]
extensions = {".md", ".sh", ".py", ".txt", ".json", ".yaml", ".yml", ".toml"}
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
  backup_file "${OPENCLAW_CONFIG_PATH}"
  python3 - "${OPENCLAW_CONFIG_PATH}" "${OPENCLAW_HOME}" "${CTO_MODEL}" "${FORCE_MODEL_UPDATE}" "${OPENCLAW_AGENT_TIMEOUT_SECONDS}" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
openclaw_home = pathlib.Path(sys.argv[2])
cto_model = sys.argv[3]
force_model_update = (sys.argv[4].strip().lower() == "true")
agent_timeout_seconds = int(sys.argv[5])

data = json.loads(config_path.read_text(encoding="utf-8"))

agents = data.setdefault("agents", {})
if isinstance(agents, list):
    agents = {"list": agents}
    data["agents"] = agents
defaults = agents.setdefault("defaults", {})
defaults["timeoutSeconds"] = agent_timeout_seconds


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


auth = data.get("auth") or {}
auth_order = auth.get("order") or {}
provider_mode = "openai"
if isinstance(auth_order, dict):
    keys = [k for k in auth_order.keys() if isinstance(k, str)]
    if keys == ["anthropic"]:
        provider_mode = "anthropic"

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

selected_primary = pick_first(preferred_primary, set())
if not selected_primary:
    selected_primary = cto_model or ("anthropic/claude-opus-4-5" if provider_mode == "anthropic" else "openai/gpt-5.3-codex")

selected_fallbacks = []
for m in preferred_fallbacks:
    if m == selected_primary:
        continue
    selected_fallbacks.append(m)
selected_fallbacks = uniq(selected_fallbacks)[:3]

if len(selected_fallbacks) < 3 and allowed_models:
    for m in allowed_models:
        if m == selected_primary:
            continue
        if m in selected_fallbacks:
            continue
        selected_fallbacks.append(m)
        if len(selected_fallbacks) >= 3:
            break
    selected_fallbacks = uniq(selected_fallbacks)

heartbeat_model = pick_first(preferred_heartbeat, set())
if not heartbeat_model:
    heartbeat_model = selected_fallbacks[-1] if selected_fallbacks else selected_primary

model_payload = {"primary": selected_primary}
if selected_fallbacks:
    model_payload["fallbacks"] = selected_fallbacks

agent_list = agents.setdefault("list", [])
cto_heartbeat = {
    "every": "1h",
    "prompt": "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK.",
    "target": "none",
    "ackMaxChars": 300,
    "model": heartbeat_model,
}
existing = None
for item in agent_list:
    if isinstance(item, dict) and item.get("id") == "cto-factory":
        existing = item
        break

if existing is None:
    existing = {
        "id": "cto-factory",
        "default": False,
        "name": "CTO Factory",
        "workspace": str(openclaw_home / "workspace-factory"),
        "agentDir": str(openclaw_home / "agents/cto-factory/agent"),
        "model": model_payload,
        "heartbeat": cto_heartbeat,
        "identity": {
            "name": "CTO Factory Agent",
            "theme": "engineering",
            "emoji": "factory",
        },
    }
    agent_list.append(existing)
else:
    existing["default"] = False
    existing["name"] = existing.get("name") or "CTO Factory"
    existing["workspace"] = str(openclaw_home / "workspace-factory")
    existing["agentDir"] = str(openclaw_home / "agents/cto-factory/agent")
    existing["heartbeat"] = cto_heartbeat
    model = existing.get("model")
    if not isinstance(model, dict):
        model = {}

    current_primary = str(model.get("primary") or "").strip()
    provider_mismatch = (
        (provider_mode == "anthropic" and not current_primary.startswith("anthropic/"))
        or (provider_mode == "openai" and current_primary.startswith("anthropic/"))
    )

    if force_model_update or provider_mismatch:
        existing["model"] = model_payload
    else:
        model.setdefault("primary", selected_primary)
        if selected_fallbacks and "fallbacks" not in model:
            model["fallbacks"] = selected_fallbacks
        existing["model"] = model

tools = data.setdefault("tools", {})
sessions = tools.setdefault("sessions", {})
sessions.setdefault("visibility", "all")

agent_to_agent = tools.setdefault("agentToAgent", {})
agent_to_agent.setdefault("enabled", True)
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

validate_config() {
  log_info "Validating OpenClaw configuration."
  local validate_out
  validate_out="$(with_openclaw_env openclaw config validate --json 2>&1 || true)"
  if ! printf "%s" "${validate_out}" | jq -e '.valid == true' >/dev/null 2>&1; then
    printf "%s\n" "${validate_out}" >&2
    die "openclaw config validate failed after update."
  fi
}

restart_gateway_if_needed() {
  if [[ "${RESTART_GATEWAY}" != "true" ]]; then
    log_warn "Skipping gateway restart because RESTART_GATEWAY=false."
    return 0
  fi
  log_info "Restarting gateway."
  restart_gateway_background
  wait_for_gateway_health 90 || die "Gateway health check failed after restart."
}

run_cto_smoke() {
  if [[ "${SKIP_CTO_HEALTH_SMOKE}" == "true" ]]; then
    log_warn "Skipping CTO smoke because SKIP_CTO_HEALTH_SMOKE=true."
    return 0
  fi
  log_info "Running CTO local smoke check."
  local out
  out="$(with_openclaw_env openclaw agent --local --agent cto-factory --message "Reply with CTO_FACTORY_OK and one sentence status." --json --timeout 240 2>&1 || true)"
  if ! printf "%s" "${out}" | grep -q "CTO_FACTORY_OK"; then
    if printf "%s" "${out}" | grep -qi "No API key found for provider"; then
      log_warn "Skipping CTO smoke failure because API credentials are not configured on this host yet."
      return 0
    fi
    printf "%s\n" "${out}" >&2
    die "CTO local smoke failed."
  fi
}

main() {
  user_section "CTO update"
  user_step "Ref: ${CTO_REPO_REF}"
  user_step "OpenClaw home: ${OPENCLAW_HOME}"

  confirm_if_needed
  ensure_prerequisites
  update_repo_if_enabled
  create_backup
  trap 'on_error' ERR

  sync_workspace_files
  rewrite_hardcoded_paths
  upsert_cto_agent_config
  validate_config
  restart_gateway_if_needed
  run_cto_smoke

  trap - ERR
  user_section "Update completed"
  user_step "Backup: ${BACKUP_DIR}"
  user_step "CTO files refreshed and validated."
}

main "$@"
