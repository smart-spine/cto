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

If any smoke check fails, block `DONE` and route to `ROLLBACK`.
