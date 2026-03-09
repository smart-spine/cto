# CTO Factory Skill Index

Purpose:
- provide a single skill inventory for `cto-factory`,
- define mandatory routing expectations,
- reduce overlap/conflicts between skills.

## Inventory

| Skill | Responsibility |
| --- | --- |
| `factory-intake` | Intake survey, critical input collection, requirements sign-off gate. |
| `factory-preflight` | Environment/provider/model preflight checks. |
| `factory-backup` | Git rollback checkpoint creation. |
| `factory-codegen` | Codex-based implementation orchestration for complex logic. |
| `factory-create-agent` | New agent workspace creation + registration contract. |
| `factory-skill-creator` | Skill package generation/consistency for created agents. |
| `factory-ux-designer` | Telegram interactive UX safety (buttons/commands/cancel/status). |
| `factory-test-agent` | QA suite (white-box/black-box/chaos scenarios). |
| `factory-smoke` | Functional smoke scenarios and runtime delivery checks. |
| `factory-config-qa` | `openclaw config validate --json` gate + error parsing. |
| `factory-config-diff` | Human-readable config mutation summary. |
| `factory-apply` | Apply gate handling and controlled live mutations. |
| `factory-rollback` | Rollback to backup state. |
| `factory-openclaw-ops` | Operational `openclaw ...` command execution protocol. |
| `factory-gateway-restart` | Detached gateway restart with callback confirmation. |
| `factory-keepalive` | Progress updates for long-running tasks. |
| `factory-context-compress` | Context summarization checkpoints. |
| `factory-memory-garden` | Long-term memory hygiene and organization. |
| `factory-research` | Research/verification for uncertain external facts. |
| `factory-report` | Final report packaging with evidence. |

## Mandatory Routing Rules

1. New agent creation MUST use `factory-create-agent` + `factory-skill-creator`.
2. Interactive Telegram UX (buttons/menus/command flows) MUST use `factory-ux-designer` before CODE.
3. Any `openclaw.json` mutation MUST pass `factory-config-qa`.
4. Any major behavior change MUST pass `factory-test-agent` + `factory-smoke`.
5. CODE/CONFIG mutation MUST NOT start before `factory-intake` sign-off approval.

See routing matrix: `../SKILL_ROUTING.md`.
