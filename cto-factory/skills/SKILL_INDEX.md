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
| `factory-codegen` | Code-agent-based implementation orchestration (`codex` or `claude`) for complex logic. |
| `factory-codex-plan-audit` | Validates plan/report coverage (shared JSON markers) against intake requirements. |
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
| `factory-coherence-review` | Holistic review of all agent profile files — finds and fixes contradictions, dead refs, duplicates, bloat, scope violations. Max 3 iterations. |
| `factory-research` | Research/verification for uncertain external facts. |
| `factory-report` | Final report packaging with evidence. |

## Mandatory Routing Rules

1. New agent creation MUST use `factory-create-agent` + `factory-skill-creator`.
2. Interactive Telegram UX (buttons/menus/command flows) MUST use `factory-ux-designer` before CODE.
3. If intake marks `COMPLEX_INTERACTIVE=YES`, interaction mode MUST be `buttons` and MUST NOT be `commands only`.
4. Any `openclaw.json` mutation MUST pass `factory-config-qa`.
5. Any major behavior change MUST pass `factory-test-agent` + `factory-smoke`.
9. Any task that creates or modifies agent profile files MUST invoke `factory-coherence-review` before READY_FOR_APPLY.
6. CODE/CONFIG mutation MUST NOT start before `factory-intake` sign-off approval.
7. Non-trivial code-agent work MUST pass `factory-codex-plan-audit` (plan gate + exec-report gate) before READY.
8. Interactive Telegram agents MUST pass `cto_interactive_agent_gate.py` before READY/APPLY with `/menu` keyboard-first proof (inline buttons + callback routing).

See routing matrix: `../SKILL_ROUTING.md`.
