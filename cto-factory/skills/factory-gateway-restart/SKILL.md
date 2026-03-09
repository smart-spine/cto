---
name: factory-gateway-restart
description: Restart OpenClaw gateway with deterministic user feedback (pre-ack + post-restart callback).
---

Purpose:
- Avoid silent restarts that drop the current reply channel.
- Must be executed under the `factory-openclaw-ops` reporting loop.

Mandatory protocol:
1. Pre-ack and execution are a single operational step. Text-only acknowledgement is forbidden.
2. In the same assistant turn, execute a tool action that dispatches restart immediately.
3. Resolve runtime before dispatch:
   - `"$OPENCLAW_ROOT/workspace-factory/scripts/gateway-runtime-detect.sh" 12`
   - use `restart_tool` from detector output when present.
4. Default restart path is detached dispatcher script:
   - `${OPENCLAW_ROOT}/workspace-factory/scripts/gateway-restart-callback.sh`
5. Dispatcher script must send completion callback:
   - primary transport: `openclaw message send` to the bound Telegram group/topic,
   - fallback transport: `openclaw system event --mode now --text ...`.
6. Callback success text: `Gateway restart complete: RPC probe OK.`
7. Callback failure text: `Gateway restart failed: RPC probe not ready after timeout.`

Required ACT command (recommended):
```bash
OPENCLAW_ROOT="$OPENCLAW_ROOT" nohup /usr/bin/env bash "$OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh" --agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" >/dev/null 2>&1 &
```

If explicit chat/topic targeting is needed:
```bash
OPENCLAW_ROOT="$OPENCLAW_ROOT" nohup /usr/bin/env bash "$OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh" --agent-id cto-factory --chat <chat_id> --topic <topic_id> --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" >/dev/null 2>&1 &
```

Post-dispatch verification:
- After dispatching the restart, inform the user that the restart is running detached and that a callback message will arrive in the Telegram topic.
- If no callback arrives within 60 seconds, proactively inspect the latest log file at `$OPENCLAW_ROOT/logs/cto-gateway-restart-*.log` using:
  ```bash
  ls -t "$OPENCLAW_ROOT"/logs/cto-gateway-restart-*.log | head -1 | xargs tail -20
  ```
- Report the log contents to the user with a summary of what happened.
- In addition to topic callback, ALWAYS send a status/fallback summary in the current CTO session after restart outcome is known.

Edge cases:
- If the dispatcher script itself fails to launch (exit code != 0 from `nohup`), report immediately and fall back to manual restart steps:
  1. `openclaw gateway stop`
  2. Wait 2 seconds.
  3. `openclaw gateway start`
  4. `openclaw gateway status` (verify `RPC probe: ok`).
  5. Report result to user.
- If `openclaw gateway status` shows the gateway was already stopped before restart, skip restart and run `openclaw gateway start` directly.

Reporting requirements:
- include the pre-ack text,
- include the exact dispatcher command used,
- include the dispatcher command exit code from `ACT`,
- include expected callback transport (`message send` with fallback `system event`),
- include session wake callback status when `--callback-session-id` was provided,
- include "no-callback fallback report sent in current session" status when callback did not appear in the expected window,
- include where to inspect logs:
  - `$OPENCLAW_ROOT/logs/cto-gateway-restart-*.log`.

Forbidden:
- pre-acknowledgement without tool execution in the same assistant turn,
- text-only completion for an imperative restart request,
- native `gateway` tool call with `action="restart"` (must use detached dispatcher command),
- direct blocking `openclaw gateway restart` without detached callback flow,
- restart command chaining in one step (for example `openclaw gateway restart && openclaw gateway status`).
