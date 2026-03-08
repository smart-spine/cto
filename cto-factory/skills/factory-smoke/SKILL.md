---
name: factory-smoke
description: Run post-apply sanity checks and confirm expected artifacts are operational.
---

Smoke checks should be quick and deterministic.

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
8. If runtime/channel prerequisites are missing, report `BLOCKED` with exact prerequisite and do not claim `READY_FOR_APPLY`.
9. Scope boundary:
   - `factory-smoke` is fast and task-focused.
   - for broad behavioral regression/comparative checks, hand off to `factory-test-agent`.

If any smoke check fails, block `DONE` and route to `ROLLBACK`.
