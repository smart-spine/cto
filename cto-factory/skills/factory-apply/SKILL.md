---
name: factory-apply
description: Apply validated changes locally after READY_FOR_APPLY gate.
---

Apply only when:
- tests passed,
- CONFIG_QA passed,
- apply is explicitly requested.
- for new-agent workflows: artifact gate passed with exit code `0` using
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_agent_artifact_gate.py" --root "$OPENCLAW_ROOT" --agent-id <agent_id> --require-binding`.
- for interactive Telegram agents, interactive runtime gate passed with exit code `0`:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_interactive_agent_gate.py" --workspace "$OPENCLAW_ROOT/workspace-<agent_id>" --menu-command <menu_command> --callback-namespace <namespace>`.

Pending apply state (mandatory):
- Before presenting `A/B/C` options, persist pending state:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_apply_state.py" set --request-id <id> --summary "<summary>" --option-a "<action>" --option-b "<action>" --option-c "<action>"`.
- On next user turn, resolve shorthand approvals:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_apply_state.py" resolve --message "<user message>"`.
- Treat these as explicit approvals if a pending state exists:
  - `A`, `B`, `C`, `READY_FOR_APPLY - A`.
- Never ask "what does A mean?" when resolve returns a valid option.
- After apply/decline/cancel, clear pending state:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_apply_state.py" clear`.

Pre-apply confirmation (mandatory):
- Before executing any mutating operation, emit a final confirmation prompt to the user that lists:
  1. All files that will be created, modified, or deleted.
  2. Any `openclaw.json` changes (new agents, bindings, config patches).
  3. Any cron/gateway mutations.
  4. Post-apply usage handoff:
     - target agent id and binding target (chat/topic/direct),
     - exact first interaction step after apply,
     - short commands/buttons quick sheet,
     - expected callback text + expected window (~60s) for restart/apply operations.
- Wait for explicit user approval before proceeding.
- If user declines, route to `ROLLBACK` or `DONE` without applying.
- If artifact gate is required and missing/failing, block apply with `BLOCKED: ARTIFACT_GATE_FAILED` and return to CODE.
- Do NOT present `A/B/C` approval without the usage handoff block.

Gateway restart-specific rule:
- If apply includes `openclaw gateway restart`, route through `factory-openclaw-ops` → `factory-gateway-restart` and use restart handshake:
  1. Send pre-restart acknowledgement.
  2. Detect runtime first:
     - `"$OPENCLAW_ROOT/workspace-factory/scripts/gateway-runtime-detect.sh" 12`
  3. Trigger detached restart workflow via `factory-gateway-restart` using:
     - `OPENCLAW_ROOT="$OPENCLAW_ROOT" nohup /usr/bin/env bash "$OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh" --agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" >/dev/null 2>&1 &`
  4. Require post-restart callback event with success/failure status.
  5. If no callback is observed within 60s, MUST inspect restart log and post fallback status in current session:
     - `ls -t "$OPENCLAW_ROOT"/logs/cto-gateway-restart-*.log | head -1 | xargs tail -20`
  6. Do NOT use native `gateway` tool `action=restart`.
