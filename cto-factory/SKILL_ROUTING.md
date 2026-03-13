# Skill Routing Matrix

Purpose:
- enforce deterministic skill selection,
- prevent contradictory skill usage,
- make skill decisions auditable in reports.

Mandatory use:
- read this file during `SKILL_ROUTING` stage for non-trivial tasks,
- include selected skills and reason in `PLAN` and final report.

## Routing Matrix

| Task intent | Primary skill(s) | Secondary skill(s) | Do not use |
| --- | --- | --- | --- |
| Build/create a new agent | `factory-create-agent`, `factory-skill-creator`, `factory-backup` | `factory-ux-designer` (MANDATORY if interactive UI), `factory-codegen`, `factory-codex-plan-audit`, `factory-config-qa`, `factory-test-agent`, `factory-smoke`, `factory-apply` | `factory-codegen` alone |
| Add/update skills in an existing agent | `factory-skill-creator` | `factory-codegen`, `factory-test-agent` | direct ad-hoc docs-only edits without validation |
| Modify existing code/config behavior | `factory-codegen`, `factory-backup` | `factory-codex-plan-audit`, `factory-config-qa`, `factory-test-agent`, `factory-smoke`, `factory-apply` | `factory-create-agent` |
| Design/modify Telegram interactive UX (buttons, menus, command surface) | `factory-ux-designer` | `factory-create-agent`, `factory-test-agent`, `factory-smoke` | direct implementation without UX safety spec |
| Investigate unknown errors or external APIs | `factory-research` | `factory-preflight`, `factory-codegen` | blind implementation without docs check |
| OpenClaw runtime operations (`openclaw ...`) | `factory-openclaw-ops` | `factory-gateway-restart` (restart only) | naked operational commands without protocol wrapper |
| Risky changes requiring rollback safety | `factory-backup` | `factory-rollback` | mutation before backup |
| Long-running tasks | `factory-keepalive` | `factory-context-compress`, `factory-memory-garden` | silent blocking execution |
| Final status handoff | `factory-report` | `factory-config-diff` (when config changed) | raw tool dumps |

## New Agent Skill Package Standard

For every newly created agent workspace `workspace-<agent_id>/`:
- required directory: `skills/`
- required file: `skills/SKILL_INDEX.md`
- required content: at least one concrete skill folder `skills/<skill-name>/SKILL.md`
- required gate: run
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_skill_consistency_gate.py" --workspace "$OPENCLAW_ROOT/workspace-<agent_id>"`
- for interactive Telegram agents, required gate:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_interactive_agent_gate.py" --workspace "$OPENCLAW_ROOT/workspace-<agent_id>" --menu-command /menu`

`SKILL_INDEX.md` must include:
- skill inventory,
- routing table (`intent -> primary skill -> fallback`),
- anti-overlap rule (single primary skill per intent).

## Skill Selection Rules

1. Choose the minimal set of skills that covers the task.
2. For `build/create new agent`, both `factory-create-agent` and `factory-skill-creator` are mandatory.
3. For interactive Telegram UX tasks (buttons/menus/custom command flows), `factory-ux-designer` is mandatory before CODE.
4. If intake classifies task as `COMPLEX_INTERACTIVE=YES`, UX mode MUST be `buttons` (not `commands only`).
5. Never skip `factory-config-qa` when `openclaw.json` changes.
6. Never skip `factory-test-agent` for major behavior changes.
7. Never skip `factory-codex-plan-audit` for non-trivial code-agent tasks (`codex` or `claude`).
8. Never skip `factory-backup` before CODE/CONFIG mutation paths.
9. Never skip `factory-apply` once a mutation path reaches `READY_FOR_APPLY` / `APPLY`.
10. If two skills overlap, pick one primary and document why.
11. For new-agent runtime validation:
   - use `factory-smoke` for one-shot execution,
   - if cross-agent transport is available, prefer `sessions_spawn` + `sessions_send` for black-box interaction with the created agent.

## Evidence Requirements

Each major run must report:
- selected skills,
- reason per selected skill,
- validation commands and exit codes,
- explicit note if any skill was intentionally skipped.
