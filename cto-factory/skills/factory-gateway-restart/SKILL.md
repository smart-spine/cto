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
3. Default restart path is detached dispatcher script:
   - `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/gateway-restart-callback.sh`
4. Dispatcher script must send completion callback:
   - primary transport: `openclaw message send` to the bound Telegram group/topic,
   - fallback transport: `openclaw system event --mode now --text ...`.
5. Callback success text: `Gateway restart complete: RPC probe OK.`
6. Callback failure text: `Gateway restart failed: RPC probe not ready after timeout.`

Required ACT command (recommended):
```bash
nohup /usr/bin/env bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/gateway-restart-callback.sh --agent-id cto-factory >/dev/null 2>&1 &
```

If explicit chat/topic targeting is needed:
```bash
nohup /usr/bin/env bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/gateway-restart-callback.sh --agent-id cto-factory --chat <chat_id> --topic <topic_id> >/dev/null 2>&1 &
```

Post-dispatch verification:
- After dispatching the restart, inform the user that the restart is running detached and that a callback message will arrive in the Telegram topic.
- If no callback arrives within 60 seconds, proactively inspect the latest log file at `$HOME/.openclaw/logs/cto-gateway-restart-*.log` using:
  ```bash
  ls -t $HOME/.openclaw/logs/cto-gateway-restart-*.log | head -1 | xargs tail -20
  ```
- Report the log contents to the user with a summary of what happened.

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
- include where to inspect logs:
  - `$HOME/.openclaw/logs/cto-gateway-restart-*.log`.

Forbidden:
- pre-acknowledgement without tool execution in the same assistant turn,
- text-only completion for an imperative restart request,
- native `gateway` tool call with `action="restart"` (must use detached dispatcher command),
- direct blocking `openclaw gateway restart` without detached callback flow,
- restart command chaining in one step (for example `openclaw gateway restart && openclaw gateway status`).
