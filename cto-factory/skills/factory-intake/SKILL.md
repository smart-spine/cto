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
3a. For "build/create new agent" tasks, do not enter CODE until critical inputs are confirmed (or explicitly defaulted and acknowledged):
   - destination/channel binding,
   - schedule/trigger policy,
   - failure policy,
   - data source strategy.
3b. If the user gives vague replies (for example "just make it fast", "figure it out") and critical inputs remain missing:
   - ask again with a short required-fields list,
   - refuse to start implementation in this turn,
   - return `BLOCKED: MISSING_CRITICAL_INPUTS` with exact missing items.
4. For routine edits, only ask about missing critical blockers and proceed.
5. If the task is operational (`openclaw ...` commands), hand off to `factory-openclaw-ops`.
6. If the task is "restart gateway" (or equivalent), hand off to `factory-openclaw-ops` + `factory-gateway-restart` and enforce restart handshake (pre-ack + callback).
   - Do NOT execute restart commands from intake.
   - Do NOT use native `gateway` tool `action=restart`.
   - ACT command execution is owned by `factory-gateway-restart`.
7. If the expected task duration is >60s (for example large Codex generation), set `KEEPALIVE_PLAN: REQUIRED` in the intake output.
8. Capability boundary:
   - if user asks for external cloud deployment (AWS/GCP/Azure) and no dedicated deployment tool is available in this workspace,
   - do not claim execution readiness,
   - return a clear capability limit and offer local alternatives (config/script/package only).

Output:
- normalized objective,
- target artifact paths,
- acceptance criteria,
- apply intent (`APPLY_PHASE`).
- keepalive requirement marker (`KEEPALIVE_PLAN: REQUIRED|OPTIONAL`).
