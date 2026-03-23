---
read_when:
  - Before creating a new agent workspace
  - When resolving path or registration issues
  - Before any CODE or CONFIG delegation
---

# Workspace Contracts

## Path Anchor Contract

- `OPENCLAW_ROOT` = directory that contains root `openclaw.json`.
- `CTO_WORKSPACE` = `${OPENCLAW_ROOT}/workspace-factory`.
- ALL generated agent workspaces MUST be rooted at `${OPENCLAW_ROOT}/workspace-<agent_name>`.
- Generated workspaces MUST NOT be created under `${CTO_WORKSPACE}`.

## Code Agent Delegation

→ Full rules in `CODE_AGENT_PROTOCOLS.md` (single source of truth).

Hard prohibitions (NO EXCEPTIONS):
- MUST NEVER use `write`, `edit`, or any equivalent direct file-mutation tool for project files.
- Code-agent delegation MUST NOT target any file under `workspace-factory/`.
- Allowed write targets: `${OPENCLAW_ROOT}/workspace-<agent_name>/`.
- If remembered code agent cannot execute after bounded retries → `BLOCKED: CODE_AGENT_EXEC_FAILED`.
- Violations of write scope → `BLOCKED: WORKSPACE_SCOPE_VIOLATION`, restore from git.

## Skill Routing Contract

→ Full routing matrix in `SKILL_ROUTING.md`.

- `SKILL_ROUTING` is mandatory for every non-trivial task.
- For any CODE/CONFIG mutation path:
  - `factory-backup` MUST be selected before `CODE`,
  - `factory-apply` MUST be selected before `READY_FOR_APPLY`/`APPLY`,
  - `factory-report` MUST summarize which skills were selected and why.
- If two skills overlap, record one primary skill and justify any secondary skills.

## New Agent Workspace Contract

- New agents MUST be isolated in `${OPENCLAW_ROOT}/workspace-<agent_name>/`.
- Base profile files MUST be at workspace root (NOT in `agent/`):
  - `IDENTITY.md`, `TOOLS.md`, `PROMPTS.md`, `AGENTS.md` or `README.md`
- Required subfolders: `config/`, `tools/`, `tests/`, `skills/` (with `skills/SKILL_INDEX.md` and at least one skill), `docs/`.
- `AGENTS.md` MUST be ≤100 lines — thin table of contents only. Detailed protocols go in `docs/`.
- Root `openclaw.json` registration is MANDATORY with absolute paths:
  - `workspace = ${OPENCLAW_ROOT}/workspace-<agent_name>`
  - `agentDir = ${OPENCLAW_ROOT}/workspace-<agent_name>`
- If a nested path like `${CTO_WORKSPACE}/workspace-<agent_name>` is detected → treat as failed.
- If a new agent includes interactive Telegram UX → `factory-ux-designer` MUST run before CODE.
- If intake classifies agent as `COMPLEX_INTERACTIVE=YES` → UX mode MUST be `buttons`.

## Config QA Rules

- `openclaw config validate --json` is MANDATORY when config changes.
- Canonical root config: `${OPENCLAW_ROOT}/openclaw.json`.
- NEVER assume config lives under `workspace-factory/`.
- If validation fails, delegate fix to remembered code agent and re-run.
- NEVER return `READY_FOR_APPLY` with failing config validation.
- **Cron jobs MUST be managed via `openclaw cron add|edit|rm` CLI — NEVER by writing `cron.jobs` directly into `openclaw.json`.** The `cron.jobs` key is a legacy format and will fail validation. Delegate cron mutations through `factory-openclaw-ops` skill.

## Safety

- Secret handling MUST use SecretRef. NEVER print plaintext credentials.
- Rollback path MUST be valid before apply.
- Work strictly inside allowed workspace scope.
- No fake capability claims.
