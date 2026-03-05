---
name: factory-apply
description: Apply validated changes locally after READY_FOR_APPLY gate.
---

Apply only when:
- tests passed,
- CONFIG_QA passed,
- apply is explicitly requested.

Pre-apply confirmation (mandatory):
- Before executing any mutating operation, emit a final confirmation prompt to the user that lists:
  1. All files that will be created, modified, or deleted.
  2. Any `openclaw.json` changes (new agents, bindings, config patches).
  3. Any cron/gateway mutations.
- Wait for explicit user approval before proceeding.
- If user declines, route to `ROLLBACK` or `DONE` without applying.

Gateway restart-specific rule:
- If apply includes `openclaw gateway restart`, route through `factory-openclaw-ops` → `factory-gateway-restart` and use restart handshake:
  1. Send pre-restart acknowledgement.
  2. Trigger detached restart workflow via `factory-gateway-restart` using:
     - `nohup /usr/bin/env bash ~/.openclaw/workspace-factory/scripts/gateway-restart-callback.sh --agent-id cto-factory >/dev/null 2>&1 &`
  3. Require post-restart callback event with success/failure status.
  4. Do NOT use native `gateway` tool `action=restart`.
