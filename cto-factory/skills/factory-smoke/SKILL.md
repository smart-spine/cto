---
name: factory-smoke
description: Run post-apply sanity checks and confirm expected artifacts are operational.
---

Smoke checks should be quick and deterministic.

## PRE-APPLY FUNCTIONAL SMOKE
- Run before `READY_FOR_APPLY`.
- Goal: prove the requested behavior works before any live mutation.
- Failure handling:
  - if the implementation is wrong or incomplete, return `RETURN_TO_CODE`,
  - if runtime/channel prerequisites are missing, return `BLOCKED` with the exact prerequisite,
  - do NOT recommend rollback for work that has not been applied yet.

## POST-APPLY SMOKE
- Run only after live apply.
- Goal: prove the live runtime, delivery path, and health still work after mutation.
- Failure handling:
  - if a live regression or partial apply is detected, mark `POST_APPLY_SMOKE_FAILED` and recommend `ROLLBACK`,
  - if rollback is not appropriate, report the exact remediation path and blast radius.

Minimum required checks:
1. If a new agent workspace was created, verify the directory exists and contains at least `AGENTS.md` or `README.md`.
2. If `openclaw.json` was modified, run `openclaw config validate --json` one final time and confirm `valid: true`.
3. If the agent has a cron schedule, verify it is listed via `openclaw cron list --agent <agent-id> --json`.
4. If any tools (`.js`/`.ts`) were created or modified, run `node --check <file>` to confirm no syntax errors.
5. Report each check with PASS/FAIL status.

For newly created/modified agents (mandatory):
6. Run at least one real one-shot execution against the target agent with a bounded timeout:
   - `timeout 60 openclaw agent --agent <id> --message "<realistic user request>"`
   - on macOS use `gtimeout 60 ...` if GNU `timeout` is not available.
7. For delivery agents, verify delivery-path evidence (for example `sent=true`, no fallback) when runtime/channel is available.
7a. If intake explicitly requested `buttons` or `buttons + commands`, smoke MUST verify inline-button delivery evidence in the target chat/topic:
   - one message-tool send (or agent-generated send) includes inline keyboard payload,
   - provider response confirms send success (`sent=true` or equivalent message id evidence),
   - text-only fallback menu does NOT satisfy this requirement.
7b. For interactive button agents, smoke MUST run runtime UX gate:
   - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_interactive_agent_gate.py" --workspace "$OPENCLAW_ROOT/workspace-<agent_id>" --menu-command <menu_command> --callback-namespace <namespace>`
   - treat non-zero exit as hard smoke failure.
8. If runtime/channel prerequisites are missing, report `BLOCKED` with exact prerequisite and do not claim `READY_FOR_APPLY`.
9. Scope boundary:
   - `factory-smoke` is fast and task-focused.
   - for broad behavioral regression/comparative checks, hand off to `factory-test-agent`.

If any pre-apply smoke check fails, block `READY_FOR_APPLY` and route to `RETURN_TO_CODE` or `BLOCKED`.
If any post-apply smoke check fails, block `DONE` and route to `ROLLBACK` or an explicitly documented live remediation path.
