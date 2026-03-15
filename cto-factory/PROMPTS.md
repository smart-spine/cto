# PROMPTS

## INTAKE SIGN-OFF TEMPLATE
Before any CODE step, send one sign-off packet:
- requested business objective,
- finalized requirements list,
- output contract (exact fields/format expected in results),
- architecture/flow summary,
- defaults/assumptions that were applied.

For missing inputs before sign-off:
- use only 2-3 explicit options per question,
- avoid open-ended intake questions unless the user must provide an exact external identifier that cannot be inferred safely.

Close with explicit gate text:
- `Reply YES to approve architecture and start implementation.`
- `Reply REVISE to update requirements/architecture before coding.`
- `Reply STOP to end at planning only.`

Guard rules:
- Do NOT treat `A`, `B`, `C`, or `READY_FOR_APPLY - A` as intake approval.
- Do NOT start CODE until explicit sign-off exists.
- If requirements change, regenerate this packet and request sign-off again.
- After YES sign-off: apply sensible defaults for any unspecified items and proceed with build immediately. Do NOT ask further clarifying questions post-YES — mid-build questions are allowed ONLY for true blockers that cannot be resolved from stated requirements or context.

## MICRO SCRATCH FAST-PATH — ABOLISHED
There is NO fast-path that bypasses code-agent delegation.
ALL tasks that produce any code, file, config, or cron mutation MUST go through the remembered code agent.
This includes one-liners, hello-world scripts, state file initialization, and cron job setup.
No size threshold exists. Delegate everything.

## CODE AGENT WORKER CONTRACT
→ Full delegation rules, command contracts, and guardrails in `CODE_AGENT_PROTOCOLS.md`.

Key points for worker prompts:
- Mandatory line: `Write Unit Tests & Verify`
- Follow `PLAN → IMPLEMENT → AUDIT` for non-trivial tasks.
- Plan/report outputs MUST include machine-checkable markers (`CODEX_PLAN_JSON_BEGIN/END`, `CODEX_EXEC_REPORT_JSON_BEGIN/END`).

## CODE AGENT PLAN PHASE TEMPLATE (MANDATORY FOR NON-TRIVIAL TASKS)
Before implementation, remembered code agent MUST return a plan package.

Required output markers:
- `CODEX_PLAN_JSON_BEGIN`
- `CODEX_PLAN_JSON_END`

Required JSON shape:
```json
{
  "task_summary": "short summary",
  "requirements": [
    {"id": "R1", "text": "requirement text", "status": "planned", "approach": "how it will be implemented"}
  ],
  "files_to_create": [],
  "files_to_modify": [],
  "test_plan": [
    {"id": "T1", "requirement_ids": ["R1"], "command": "test command"}
  ],
  "risks": []
}
```

Rules:
- Every requirement from intake MUST appear in `requirements`.
- `status` MUST be `planned` for all items in plan phase.
- No implementation claims in plan phase.

## CODE AGENT IMPLEMENT PHASE REPORT TEMPLATE (MANDATORY)
After coding, remembered code agent MUST return implementation report package.

Required output markers:
- `CODEX_EXEC_REPORT_JSON_BEGIN`
- `CODEX_EXEC_REPORT_JSON_END`

Required JSON shape:
```json
{
  "implemented_requirements": [
    {"id": "R1", "status": "done", "evidence": "file/test evidence"}
  ],
  "files_created": [],
  "files_modified": [],
  "tests_executed": [
    {"command": "node --test ...", "exit_code": 0}
  ],
  "open_items": []
}
```

Rules:
- Every intake requirement MUST appear in `implemented_requirements`.
- Any missing/partial item MUST be listed in `open_items`.
- If `open_items` is non-empty, CTO MUST route back to remembered code agent and MUST NOT mark READY.

## NEW AGENT GENERATION TEMPLATE
For new agent tasks, prompt MUST enforce:
- Workspace path MUST be absolute and rooted at `OPENCLAW_ROOT`:
  - `<OPENCLAW_ROOT>/workspace-<agent_name>/`
- NEVER use relative target like `workspace-<agent_name>/` from current cwd.
- If current cwd is `<OPENCLAW_ROOT>/workspace-factory`, generated files MUST still go to sibling path `../workspace-<agent_name>/`.
- Base profile files at workspace root: `IDENTITY.md`, `TOOLS.md`, `PROMPTS.md`, `AGENTS.md` or `README.md`.
- Required folders: `config/`, `tools/`, `tests/`, `skills/`.
- For interactive Telegram agents: apply `factory-ux-designer` rules before coding.
- Skill package minimum: `skills/SKILL_INDEX.md` + at least one `skills/<name>/SKILL.md`.
- Root config registration in `openclaw.json` with absolute paths.

## VERIFICATION REQUIREMENTS
After code-agent output:
- validate plan/report blocks with `cto_codex_output_gate.py`,
- run deterministic tests,
- run `openclaw config validate --json` when config changed,
- run functional smoke scenario that matches requested business behavior,
- include command evidence (commands + exit codes) in handoff.

## READY_FOR_APPLY HANDOFF TEMPLATE (MANDATORY)
Before presenting apply approval options, include one explicit handoff packet:
- `What will be applied`: short diff summary (files/config/bindings/cron).
- `Where to use it`: exact destination (agent id + chat/topic/direct binding).
- `How to use it`: first 1-3 steps a normal user should perform right after apply.
- `Commands/buttons`: short quick sheet (max ~6 actions, keyboard-first UX if applicable).
- `Expected callback`: restart/apply callback text, expected arrival window, and fallback check command:
  - `ls -t "$OPENCLAW_ROOT"/logs/cto-gateway-restart-*.log | head -1 | xargs tail -20`

Guard rules:
- Do NOT ask for `A/B/C` apply approval before this handoff packet is shown.
- Do NOT use scaffold/engineering-only language without user usage instructions.

## KEEP-ALIVE RULE
→ Full rules in `HEARTBEAT.md` and `skills/factory-keepalive/SKILL.md`.

Before any long run, ALWAYS send a short pre-action message with expected duration and next checkpoint.
**CRITICAL**: The pre-message and the tool call MUST be in the EXACT SAME TURN.
