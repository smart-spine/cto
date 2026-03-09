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
1. Graceful interrupts:
   - any long-running action MUST expose an interrupt path (`/cancel` or equivalent),
   - include status visibility (`/status` or equivalent) for in-progress jobs,
   - interrupt must be idempotent and safe if no job is running.

2. Button safety:
   - inline button callbacks MUST use namespaced payloads (example: `ux:<agent_id>:<action>`),
   - DO NOT use slash-command text inside callback payloads,
   - DO NOT use reserved Telegram/OpenClaw commands as custom business actions.

3. Reserved command collision prevention:
   - treat these commands as platform-reserved unless explicitly documented otherwise:
     - `/start`, `/help`, `/new`, `/reset`, `/commands`, `/status`, `/whoami`, `/context`, `/model`, `/models`, `/think`, `/verbose`, `/stop`,
   - custom business commands MUST use non-conflicting names (for example `/pain_auto_add`, `/pain_manual_run`) or button callbacks.

4. Dual-path interaction:
   - if buttons are provided, a text-command fallback MUST exist,
   - both paths MUST map to the same validated handler logic.

5. Output/schema safety:
   - if business output requires specific fields (for example `Problem`, `Complaints`, `Where`, `Source URL`), encode this as explicit formatter contract,
   - tests MUST assert required fields are present in each emitted item.

## REQUIRED DELIVERABLES
For interactive agents, produce:
- command map (user intents -> command/callback -> handler),
- reserved-command safety checklist,
- interrupt/cancel behavior spec,
- UX smoke checklist (at least one run covering button + text fallback + cancel path).

## VALIDATION CHECKLIST
Before `READY_FOR_APPLY`:
1. No custom action collides with reserved commands.
2. Every button/callback has a handler and test coverage.
3. Long-running flow supports cancel/status.
4. Functional smoke covers:
   - one interactive action start,
   - one cancel/interrupt action,
   - one completion path.

If any check fails, return `BLOCKED: UX_CONTRACT_NOT_SATISFIED`.
