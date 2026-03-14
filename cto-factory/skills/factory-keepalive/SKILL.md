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
- NEVER require user ping to continue reporting progress/completion.

Preferred flow:
1. Preflight estimate:
   - announce expected duration and update plan in one short message.
2. Async dispatch when the runtime can deliver callbacks safely:
   - start long command in background:
     - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" start --task-id <id> --cmd "<command>" --cwd <path> --callback-agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-${OPENCLAW_SESSION_ID:-}}" --callback-message "ASYNC_TASK_COMPLETE task_id={task_id} status={status} exit_code={exit_code}"`
   - if `CTO_SESSION_ID` is not exposed in env, provide explicit `--callback-session-id <current_session_id>`.
   - return `task_id` immediately.
   - this is the DEFAULT path for any task expected to exceed 90 seconds.
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
   - if callback sending fails, keep retrying and emit fallback status in active session every <= 90s.
5. Completion:
   - callback path MUST wake CTO session on completion (success or failure),
   - report final status (`completed`/`failed`) with exit code and next action.

Codex-specific guardrail (mandatory):
- for `codex_guarded_exec.py`, if expected runtime > 90s you MUST wrap it with `cto_async_task.py` (callback heartbeats enabled).
- for short codex runs (<=90s expected), foreground is allowed with built-in heartbeat (`[codex-guard] still running ...`).
- DO NOT use raw `exec` with `background=true` for direct Codex guarded runs.
- if tool returns `Command still running (session ...)` during an interactive turn, switch into explicit `process poll` loop with `timeout=45000` until completion/failure.
- do NOT use poll timeout `>=120000` in interactive turns.
- long polls are allowed only in detached async supervisor mode, not while holding current user turn.
- send one status note before each poll call and one status note immediately after each poll result.
- callback timeout for background completion signals SHOULD be >= 90 seconds; NEVER set callback timeout below 30 seconds.

Fallback when async callback delivery is unavailable or unsafe for this task:
- explicitly warn before blocking command:
  - `This may take a few minutes; starting now and I will report right after completion.`
- do NOT allow silent waits >90s. If async callbacks are unavailable, you MUST emit manual status updates every <=90s.
- still follow `PLAN -> ACT -> OBSERVE -> REACT`.

Heartbeat cadence (mandatory while task is running):
- update at least every 90 seconds,
- include: current step, last completed step, next step, blockers.

Hard constraints:
- do not rely on engine-level streaming changes,
- require `OPENCLAW_ROOT` to be resolved/exported before using helper scripts,
- do not claim periodic push updates if runtime cannot send them,
- keep updates short and concrete.
