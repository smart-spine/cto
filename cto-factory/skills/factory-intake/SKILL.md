---
name: factory-intake
description: Parse user request into deterministic task intent and acceptance criteria.
---

Use this skill for non-trivial tasks and all project/config mutation tasks.
Do NOT use this skill for micro scratch tasks where there is no project/config/apply mutation.

Minimum extraction rules:
1. Read the user's message and identify the core intent (e.g., "create agent", "modify config", "fix bug", "add feature").
2. Ask for any missing critical information using 2-3 explicit options only. Do NOT use open-ended intake questions unless the user must provide an exact external identifier that cannot be safely inferred.
3. At minimum clarify:
   - What is the **target artifact** (agent name, config file, tool file)?
   - What is the **desired outcome** (new behavior, fix, removal)?
   - Are there any **constraints** the user mentioned (timeline, tech stack, provider)?
4. If the task is "build/create a new agent", this skill MUST hand off to `INTAKE_SURVEY` (defined in `PROMPTS.md`) before proceeding.
4a. For "build/create new agent" tasks, do not enter CODE until critical inputs are confirmed (or explicitly defaulted and acknowledged):
   - destination/channel binding,
   - schedule/trigger policy,
   - failure policy,
   - data source strategy,
   - model preference,
   - secrets plan,
   - interaction mode (`commands only`, `buttons`, or `buttons + commands`) when the UX is interactive.
4b. COMPLEX INTERACTIVE UX CLASSIFIER (MANDATORY FOR NEW AGENTS):
   - classify requested agent as `COMPLEX_INTERACTIVE=YES` if ANY condition is true:
     - two or more business modes/workflows (for example `auto + manual`),
     - configurable runtime controls (interval/list/settings) exposed to end users,
     - long-running actions that require cancel/status,
     - more than 5 primary user actions.
   - if `COMPLEX_INTERACTIVE=YES`, interaction mode MUST be `buttons` (button-first and button-led operation).
   - for `COMPLEX_INTERACTIVE=YES`, `commands only` MUST be rejected as `BLOCKED: UX_MODE_INVALID_FOR_COMPLEX_AGENT`.
   - for interactive agents, `/menu` MUST be declared as primary entry command for UX navigation.
   - command text may exist only as fallback/diagnostic path when button send fails.
4c. If the user gives vague replies (for example "just make it fast", "figure it out") and critical inputs remain missing:
   - ask again with a short required-fields list,
   - present 2-3 explicit options for each unresolved field,
   - refuse to start implementation in this turn,
   - return `BLOCKED: MISSING_CRITICAL_INPUTS` with exact missing items.
5. REQUIREMENTS SIGN-OFF / ARCHITECTURE APPROVAL GATE (MANDATORY BEFORE CODE):
   - after intake questions are complete, produce one explicit sign-off package with:
     - normalized objective,
     - full requirements list,
     - output contract (exact fields expected in final output),
     - architecture/flow summary,
     - defaults/assumptions that were applied.
   - ask for explicit approval using a closed set of responses:
     - `YES` = approve architecture and start implementation,
     - `REVISE` = update requirements/architecture before coding,
     - `STOP` = end at planning only.
   - DO NOT start CODE until explicit approval is received.
   - approvals like `A`, `B`, `C`, `READY_FOR_APPLY - A` are NOT valid intake sign-off.
   - if requirements change after sign-off, invalidate prior sign-off and run this gate again.
6. For routine edits, only ask about missing critical blockers and proceed.
7. If the task is operational (`openclaw ...` commands), hand off to `factory-openclaw-ops`.
8. If the task is "restart gateway" (or equivalent), hand off to `factory-openclaw-ops` + `factory-gateway-restart` and enforce restart handshake (pre-ack + callback).
   - Do NOT execute restart commands from intake.
   - runtime/tool detection MUST happen before restart dispatch.
   - Do NOT use native `gateway` tool `action=restart`.
   - ACT command execution is owned by `factory-gateway-restart`.
9. If the expected task duration is >60s (for example large Codex generation), set `KEEPALIVE_PLAN: REQUIRED` in the intake output.
10. Capability boundary:
   - if user asks for external cloud deployment (AWS/GCP/Azure) and no dedicated deployment tool is available in this workspace,
   - do not claim execution readiness,
   - return a clear capability limit and offer local alternatives (config/script/package only).
11. MICRO_SCRATCH_FASTPATH classifier:
   - set `MICRO_SCRATCH_FASTPATH=YES` only when:
     - task is ephemeral/one-off,
     - no project/config mutation,
     - no apply/restart/deploy request.
   - when `MICRO_SCRATCH_FASTPATH=YES`:
     - skip intake survey/sign-off options,
     - do not ask A/B/C menus by default,
     - proceed with a single concise plan and execute via remembered code agent.

Output:
- normalized objective,
- target artifact paths,
- acceptance criteria,
- architecture summary,
- explicit output schema/format requirements,
- interaction complexity classification (`COMPLEX_INTERACTIVE: YES|NO`),
- UX mode policy (`UX_MODE_POLICY: BUTTONS_MANDATORY|FLEXIBLE`),
- intake sign-off status (`SIGNOFF_STATUS: PENDING|APPROVED`),
- apply intent (`APPLY_PHASE`).
- keepalive requirement marker (`KEEPALIVE_PLAN: REQUIRED|OPTIONAL`).
- micro fast-path marker (`MICRO_SCRATCH_FASTPATH: YES|NO`).
