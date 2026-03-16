---
name: factory-openclaw-ops
description: Execute OpenClaw operational commands with deterministic pre/post reporting.
---

Use this skill for every command that starts with `openclaw `.

Scope:
- `openclaw gateway start|stop|restart|status`
- `openclaw config validate --json`
- `openclaw secrets *`
- `openclaw system event --mode now --text "..."`
- `openclaw message send --channel <channel> --target <target> --message "..."`
- `openclaw cron list|update|edit`
- `openclaw agents list`
- other OpenClaw runtime diagnostics and health checks

Mandatory loop for each command:
1. `PLAN`: Explain the next command and why it is needed.
2. `ACT`: Execute exactly one operational command per step.
3. `OBSERVE`: Report exit code + 1-3 key result lines (not raw dumps).
4. `REACT`: Decide next step or remediation.

Hard requirements:
- Never execute naked OpenClaw commands without `PLAN` and `OBSERVE`.
- For critical operations, do not chain multiple commands via `&&`; run step-by-step.
- If a command fails, report the failure immediately with the exact failing command and the next corrective action.
- Keep secret values redacted.
- For imperative requests ("restart/start/stop/status now"), pre-acknowledgement is not completion: execute `ACT` in the same turn.
- For imperative requests, the first assistant response must include at least one executable tool call. Text-only responses are `PROTOCOL_VIOLATION`.
- For gateway lifecycle commands (`openclaw gateway start|stop|restart`), MUST run runtime detection first:
  - `"$OPENCLAW_ROOT/workspace-factory/scripts/gateway-runtime-detect.sh" 12`

Error classification and retry guidance:
- Exit code 0: success. Proceed to `REACT`.
- Exit code 1: command error. Report the error message and attempt a corrective action (e.g., fix config, re-check prerequisites).
- Exit code 2: invalid arguments or usage. Double-check command syntax and flags before retrying.
- Exit code 124: timeout. Report timeout and suggest increasing timeout or checking the service health.
- Exit code 127: command not found (`openclaw` binary missing or not in PATH). Report immediately and block; do not retry.
- For any non-zero exit code, do NOT silently continue. Always explain the failure to the user.
- Maximum 2 automatic retries per command. If still failing after 2 retries, report to the user and ask for guidance.

Restart-specific guard:
- Gateway restart requests must hand off to `factory-gateway-restart`.
- Never run direct blocking `openclaw gateway restart` as a single silent action.
- Always use pre-acknowledgement, detached restart dispatcher script, health verification, and callback event.
- Before restart, MUST detect current runtime/tooling:
  - `"$OPENCLAW_ROOT/workspace-factory/scripts/gateway-runtime-detect.sh" 12`
  - extract `restart_tool` from JSON and use it as the dispatcher path.
- Preferred canonical command:
  - `OPENCLAW_ROOT="$OPENCLAW_ROOT" nohup /usr/bin/env bash "$OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh" --agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-${OPENCLAW_SESSION_ID:-}}" >/dev/null 2>&1 &`
- If runtime-detect script is unavailable, report this explicitly and fall back to:
  - dispatcher path `"$OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh"` with `OPENCLAW_ROOT` already exported/resolved by the caller.
- Forbidden for restart: native `gateway` tool call with `action="restart"` (too easy to lose post-restart reply on chat channels).

Reporting template:
- `PLAN: <what and why>`
- `ACT: <command>`
- `OBSERVE: exit=<code> | <key lines>`
- `REACT: <next action>`
