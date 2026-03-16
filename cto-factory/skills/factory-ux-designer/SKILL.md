---
name: factory-ux-designer
description: Design safe Telegram UX for interactive agents (commands/buttons/callbacks) with conflict prevention and graceful interrupts.
---

Use this skill whenever a created/updated agent has an interactive interface:
- Telegram commands,
- inline/reply keyboards,
- long-running actions triggered by user input.

## GOAL
Prevent UX breakage caused by command collisions, missing cancel paths, and unhandled callbacks.

## MANDATORY RULES
0. Complexity mode gate:
   - `COMPLEX_INTERACTIVE` classification rules → `skills/factory-intake/SKILL.md` (section 4b).
   - for `COMPLEX_INTERACTIVE`, interface mode MUST be `buttons` (button-led).
   - in `COMPLEX_INTERACTIVE`, plain command flows MUST NOT be the primary UX path.

1. Graceful interrupts:
   - any long-running action MUST expose an interrupt path (`/cancel` or equivalent),
   - include status visibility (`/status` or equivalent) for in-progress jobs,
   - interrupt must be idempotent and safe if no job is running.

2. Button safety:
   - inline button callbacks MUST use namespaced payloads (example: `ux:<agent_id>:<action>`),
   - callback payloads MUST stay short and deterministic (target <= 48 chars, hard max 64 chars),
   - DO NOT use slash-command text inside callback payloads,
   - DO NOT use reserved Telegram/OpenClaw commands as custom business actions.

3. Reserved command collision prevention:
   - treat these commands as platform-reserved unless explicitly documented otherwise:
     - `/start`, `/help`, `/new`, `/reset`, `/commands`, `/status`, `/whoami`, `/context`, `/model`, `/models`, `/think`, `/verbose`, `/stop`,
   - custom business commands MUST use non-conflicting names (for example `/pain_auto_add`, `/pain_manual_run`) or button callbacks.

4. Dual-path interaction:
   - if buttons are provided, a text-command fallback MUST exist,
   - both paths MUST map to the same validated handler logic.
   - `/menu` MUST exist for interactive agents and MUST be the primary entry command.
   - **CRITICAL**: For Telegram-bound agents, do NOT respect or check "webchat capabilities=none" to fallback to text menus. The Telegram channel natively supports inline keyboards, so assume full button capabilities for Telegram targets and force the keyboard layout.
   - `/menu` MUST be keyboard-first:
     - send inline keyboard as primary output,
     - do NOT dump a long command list in the same success response,
     - for `COMPLEX_INTERACTIVE`: menu MUST be buttons-only on success (no command list body, no command-catalog text),
     - in `buttons` mode: menu MUST be buttons-only on success (no command list body),
     - in `buttons + commands` mode: menu MAY include one short fallback hint only (`Use /<cmd>`), not full command catalog,
     - text menu is allowed only as explicit fallback when button-send tool call fails.
   - callback payloads for `/menu` buttons MUST use `callback_data` with namespace `ux:<agent_id>:<action>`.
   - canonical button-send shape for `/menu` (use this exact transport pattern; substitute target and callbacks):
     - `openclaw message send --channel telegram --target <chat_id>:topic:<topic_id> --message "<agent name>, menu:" --buttons '[[{"text":"<label>","callback_data":"ux:<agent_id>:<action>"}]]' --json`
   - **CRITICAL**: The `--buttons` argument MUST be a valid, properly serialized JSON string (a 2D array of button objects). When calling this CLI from code (e.g. Python `subprocess` or Node `child_process`), ALWAYS use the language's native JSON serialization (e.g. `json.dumps` or `JSON.stringify`) instead of trying to format it manually to avoid escaping errors that break the keyboard transport.
   - `/menu` success acknowledgement SHOULD be one short line (`Menu sent.` or equivalent); no command catalog on success.

5. Output/schema safety:
   - if business output requires specific fields (for example `Problem`, `Complaints`, `Where`, `Source URL`), encode this as explicit formatter contract,
   - tests MUST assert required fields are present in each emitted item.

6. Runtime implementation required (not docs-only):
   - interactive UX MUST be implemented in executable runtime handlers (router/command dispatcher),
   - docs/tests-only changes are NOT sufficient,
   - at least one runtime file must process `/menu` command + callback actions,
   - runtime MUST call message transport/tool with inline keyboard payload (`buttons` or `reply_markup.inline_keyboard`).

## REQUIRED DELIVERABLES
For interactive agents, produce:
- command map (user intents -> command/callback -> handler),
- button map (button label -> callback payload -> handler),
- reserved-command safety checklist,
- interrupt/cancel behavior spec,
- UX smoke checklist (at least one run covering button + text fallback + cancel path).
- explicit menu contract:
  - `/menu -> message tool send with inline keyboard`,
  - `on tool error -> concise error + text fallback`.

## VALIDATION CHECKLIST
Before `READY_FOR_APPLY`:
1. No custom action collides with reserved commands.
2. Every button/callback has a handler and test coverage.
3. Long-running flow supports cancel/status.
4. Functional smoke covers:
   - one interactive action start,
   - one cancel/interrupt action,
   - one completion path.
5. Menu keyboard send is proven in runtime tests:
   - tests assert inline keyboard payload exists (`buttons` or `reply_markup.inline_keyboard`),
   - tests assert `/menu` path triggers button send transport (not plain text only),
   - tests assert callbacks route to real handlers.
   - tests include one concrete command-shaped assertion for the button transport (`openclaw message send ... --buttons ...`).
   - smoke evidence includes transport success payload (`ok: true`, `messageId`/provider id).
6. For `COMPLEX_INTERACTIVE`:
   - tests MUST verify menu success output is buttons-only,
   - tests MUST verify at least two business actions are reachable via callbacks (without typing commands).

If any check fails, return `BLOCKED: UX_CONTRACT_NOT_SATISFIED`.
