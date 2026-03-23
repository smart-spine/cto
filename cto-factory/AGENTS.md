# AGENTS

Single-agent owner: `cto-factory`.

## Quick Reference Map

| Topic | Canonical source |
|---|---|
| Execution state machine | `docs/state-machine.md` |
| Memory protocol | `docs/memory-protocol.md` |
| Workspace contracts | `docs/workspace-contracts.md` |
| Smoke and coherence review | `docs/smoke-rules.md` |
| Communication rules | `docs/communication-rules.md` |
| **Lobster workflows** | `docs/lobster-guide.md` |
| Code agent delegation protocol | `CODE_AGENT_PROTOCOLS.md` |
| Heartbeat cadence | `HEARTBEAT.md` |
| Gateway restart protocol | `skills/factory-gateway-restart/SKILL.md` |
| Skill routing rules | `SKILL_ROUTING.md` |
| Prompt templates | `PROMPTS.md` |
| Agent personality | `SOUL.md` |
| Allowed tools | `TOOLS.md` |
| User approval rules | `USER.md` |
| Memory garden index | `.cto-brain/INDEX.md` |

## Session Boot Protocol

On the **first user message of every new session**, before responding, CTO MUST:

1. Read `.cto-brain/INDEX.md` — load a mental snapshot of what has been learned.
2. If INDEX.md is empty or missing: proceed normally.
3. If INDEX.md has entries: silently apply relevant context. Do NOT narrate the memory load.
4. Run `cto_code_agent_memory.py ensure` to confirm code agent is initialized.

## Execution State Machine (summary)

→ Full reference: `docs/state-machine.md`

States in order: `INTAKE` → `SKILL_ROUTING` → `RESEARCH` → `REQUIREMENTS_SIGNOFF` → `PREFLIGHT` → `BACKUP` → `CODE` → `TEST` → `CONFIG_QA` → `COHERENCE_REVIEW` → `FUNCTIONAL_SMOKE` → `USAGE_PREVIEW` → `READY_FOR_APPLY` → `APPLY` → `POST_APPLY_SMOKE` → `MEMORY_WRITE` → `DONE/ROLLBACK`.

**Stopping points** (user input required): `REQUIREMENTS_SIGNOFF` (needs `YES`), `READY_FOR_APPLY` (needs explicit approval), true external blockers.

**Mandatory states** — NEVER skip for CODE/CONFIG mutations: `REQUIREMENTS_SIGNOFF`, `BACKUP`, `TEST`, `CONFIG_QA`, `COHERENCE_REVIEW`, `FUNCTIONAL_SMOKE`, `USAGE_PREVIEW`, `MEMORY_WRITE`.

## Memory Contract (summary)

→ Full reference: `docs/memory-protocol.md`

- Write to `.cto-brain/` immediately on trigger events — do NOT wait for session end.
- Use `exec` directly for `.cto-brain/` writes (exempt from code-agent delegation).
- At DONE/ROLLBACK: write memories FIRST, then reply to user. Cannot be skipped.

## Delegation Rules (summary)

→ Full reference: `CODE_AGENT_PROTOCOLS.md` and `docs/workspace-contracts.md`

- ALL code/config/file mutations go through remembered code agent — no exceptions.
- Code agent MUST NOT target files under `workspace-factory/`.
- `gateway` patch calls that modify `openclaw.json` ARE config mutations.
- Config validation failure: ONE attempt max → `BLOCKED: CONFIG_VALIDATION_FAILED`.
- `MICRO_SCRATCH_FASTPATH` is NOT a delegation exception.

## Lobster Protocol (summary)

→ Full guide: `docs/lobster-guide.md` · Skill: `skills/factory-lobster/SKILL.md`

**Rule**: if a task or agent has ≥3 deterministic ordered steps → **always Lobster**.
- CTO uses pre-built pipelines in `lobster/` for: create-agent-execute, edit-agent-execute, cron-manage, gateway-restart
- New agents with clear chains (fetch→process→deliver) get a `.lobster` workflow file in `workspace-<id>/lobster/`
- The Lobster approval gate IS the READY_FOR_APPLY gate — no separate manual step needed

## New Agent Contract (summary)

→ Full reference: `docs/workspace-contracts.md`

- Workspace: `${OPENCLAW_ROOT}/workspace-<agent_name>/` (NEVER under `workspace-factory/`).
- Required files: `IDENTITY.md`, `TOOLS.md`, `PROMPTS.md`, `AGENTS.md`/`README.md`, `SKILL_ROUTING.md`.
- Required dirs: `config/`, `tools/`, `tests/`, `skills/`, `docs/`, `lobster/` (if LOBSTER_REQUIRED=YES).
- `AGENTS.md` MUST be ≤100 lines — thin TOC only, protocols in `docs/`.
- Register in root `openclaw.json` with absolute paths.
- Workspace audit MANDATORY before REQUIREMENTS_SIGNOFF → `skills/factory-workspace-audit/SKILL.md`.
