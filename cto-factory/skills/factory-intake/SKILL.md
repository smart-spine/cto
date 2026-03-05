---
name: factory-intake
description: Parse user request into deterministic task intent and acceptance criteria.
---

Use this skill at the beginning of every task.

Minimum extraction rules:
1. Read the user's message and identify the core intent (e.g., "create agent", "modify config", "fix bug", "add feature").
2. Ask for any missing critical information. At minimum clarify:
   - What is the **target artifact** (agent name, config file, tool file)?
   - What is the **desired outcome** (new behavior, fix, removal)?
   - Are there any **constraints** the user mentioned (timeline, tech stack, provider)?
3. If the task is "build/create a new agent", this skill MUST hand off to `INTAKE_SURVEY` (defined in `PROMPTS.md`) before proceeding.
4. For routine edits, only ask about missing critical blockers and proceed.
5. If the task is operational (`openclaw ...` commands), hand off to `factory-openclaw-ops`.
6. If the task is "restart gateway" (or equivalent), hand off to `factory-openclaw-ops` + `factory-gateway-restart` and enforce restart handshake (pre-ack + callback) with this ACT command:
   - `nohup /usr/bin/env bash ~/.openclaw/workspace-factory/scripts/gateway-restart-callback.sh --agent-id cto-factory >/dev/null 2>&1 &`
   - Do NOT use native `gateway` tool `action=restart`.

Output:
- normalized objective,
- target artifact paths,
- acceptance criteria,
- apply intent (`APPLY_PHASE`).
