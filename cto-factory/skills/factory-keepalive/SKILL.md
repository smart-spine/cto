---
name: factory-keepalive
description: Provide non-silent progress behavior for long tasks using async status tooling without engine changes.
---

Use this skill when a task is likely to run longer than ~60 seconds.

Goal:
- avoid silent waits,
- keep user informed with short progress updates,
- do it without OpenClaw core modifications.
- enforce heartbeat cadence from `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/HEARTBEAT.md`.

Preferred flow:
1. Preflight estimate:
   - announce expected duration and update plan in one short message.
2. Async dispatch when feasible:
   - start long command in background:
     - `python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/cto_async_task.py start --task-id <id> --cmd "<command>" --cwd <path>`
   - return `task_id` immediately.
3. Status polling:
   - `python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/cto_async_task.py status --task-id <id>`
   - optional logs:
     - `python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/cto_async_task.py tail --task-id <id> --lines 40`
4. Completion:
   - report final status (`completed`/`failed`) with exit code and next action.

Fallback when async is not safe for this task:
- explicitly warn before blocking command:
  - `This may take a few minutes; starting now and I will report right after completion.`
- still follow `PLAN -> ACT -> OBSERVE -> REACT`.

Heartbeat cadence (mandatory while task is running):
- update at least every 90 seconds,
- include: current step, last completed step, next step, blockers.

Hard constraints:
- do not rely on engine-level streaming changes,
- do not claim periodic updates if runtime cannot send them,
- keep updates short and concrete.
