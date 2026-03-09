---
name: factory-keepalive
description: Provide non-silent progress behavior for long tasks using async status tooling without engine changes.
---

Use this skill when a task is likely to run longer than ~60 seconds.

Goal:
- avoid silent waits,
- keep user informed with short progress updates,
- do it without OpenClaw core modifications.
- enforce heartbeat cadence from `$OPENCLAW_ROOT/workspace-factory/HEARTBEAT.md`.

Preferred flow:
1. Preflight estimate:
   - announce expected duration and update plan in one short message.
2. Async dispatch when the runtime can deliver callbacks safely:
   - start long command in background:
     - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" start --task-id <id> --cmd "<command>" --cwd <path> --callback-agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" --callback-message "ASYNC_TASK_COMPLETE task_id={task_id} status={status} exit_code={exit_code}"`
   - if `CTO_SESSION_ID` is not exposed in env, provide explicit `--callback-session-id <current_session_id>`.
   - return `task_id` immediately.
2a. Codex-specific guard:
   - for `codex_guarded_exec.py`, prefer foreground run with built-in heartbeat (`[codex-guard] still running ...`).
   - do NOT default to `background=true` for Codex runs.
   - if tool returns `Command still running (session ...)`, switch into explicit `process poll` loop and keep user updates <=90s cadence until completion/failure.
3. Status polling:
   - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" status --task-id <id> --stuck-threshold 300`
   - optional logs:
     - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" tail --task-id <id> --lines 40`
4. Watchdog (non-killing):
   - if `status.task.stuck=true` (no log progress for threshold window), MUST send user warning immediately:
     - what is still running,
     - last log update timestamp / idle seconds,
     - next checkpoint time.
   - do NOT kill the task automatically just because it is long-running.
5. Completion:
   - callback path MUST wake CTO session on completion (success or failure),
   - report final status (`completed`/`failed`) with exit code and next action.

Fallback when async callback delivery is unavailable or unsafe for this task:
- explicitly warn before blocking command:
  - `This may take a few minutes; starting now and I will report right after completion.`
- do NOT promise mid-run push updates in this mode; only promise the next local checkpoint after the blocking action completes.
- still follow `PLAN -> ACT -> OBSERVE -> REACT`.

Heartbeat cadence (mandatory while task is running):
- update at least every 90 seconds,
- include: current step, last completed step, next step, blockers.

Hard constraints:
- do not rely on engine-level streaming changes,
- require `OPENCLAW_ROOT` to be resolved/exported before using helper scripts,
- avoid invalid shell pattern where env var is assigned inline and expanded in same command (`VAR=... cmd "$VAR/path"`),
- do not claim periodic push updates if runtime cannot send them,
- keep updates short and concrete.
