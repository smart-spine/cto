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

## CODEX WORKER CONTRACT
Use this contract for delegated coding tasks.

Mandatory line in worker prompt:
`Write Unit Tests & Verify`

Mandatory constraints:
- You are running inside Codex worker mode.
- DO NOT run `codex` or `codex exec` recursively.
- Implement files directly in the target workspace.
- Keep diffs minimal and deterministic.
- Never output plaintext secrets.
- Run tests immediately after generation.
- If tests fail, fix and rerun until green.
- If Codex is unavailable after bounded retries, STOP with `BLOCKED: FATAL_CODEX_UNAVAILABLE` and provide command/error evidence.

## CODEX PLAN PHASE TEMPLATE (MANDATORY FOR NON-TRIVIAL TASKS)
Before implementation, Codex MUST return a plan package.

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

## CODEX IMPLEMENT PHASE REPORT TEMPLATE (MANDATORY)
After coding, Codex MUST return implementation report package.

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
- If `open_items` is non-empty, CTO MUST route back to Codex and MUST NOT mark READY.

## NEW AGENT GENERATION TEMPLATE
For new agent tasks, prompt MUST enforce:
- Workspace path MUST be absolute and rooted at `OPENCLAW_ROOT`:
  - `<OPENCLAW_ROOT>/workspace-<agent_name>/`
- NEVER use relative target like `workspace-<agent_name>/` from current cwd.
- If current cwd is `<OPENCLAW_ROOT>/workspace-factory`, generated files MUST still go to sibling path `../workspace-<agent_name>/`.
- Base profile files at workspace root:
  - `IDENTITY.md`
  - `TOOLS.md`
  - `PROMPTS.md`
  - `AGENTS.md` or `README.md`
- Required folders:
  - `config/`, `tools/`, `tests/`, `skills/`
- For interactive Telegram agents (buttons/menus/commands):
  - apply `factory-ux-designer` rules before coding command handlers,
  - implement `/menu` as mandatory primary entry command,
  - avoid reserved command collisions,
  - include graceful interrupt command (`/cancel` or equivalent),
  - include callback/button safety checks in tests/smoke.
  - if intake marks `COMPLEX_INTERACTIVE=YES`, interaction mode MUST be `buttons` (button-led UX).
  - for `COMPLEX_INTERACTIVE=YES`, do NOT implement command-catalog-driven UX as primary path.
  - if interaction mode is `buttons`, menu success response MUST be inline-keyboard only (no command list body).
  - if interaction mode is `buttons + commands`, menu success response MUST still be keyboard-first with only a short command hint.
  - `/menu` runtime path MUST call message transport with inline keyboard payload (`buttons` or `reply_markup.inline_keyboard`) and namespaced callback_data.
- Skill package minimum:
  - `skills/SKILL_INDEX.md`
  - at least one `skills/<name>/SKILL.md`
- Root config registration in `openclaw.json` with absolute paths:
  - `workspace = <OPENCLAW_ROOT>/workspace-<agent_name>`
  - `agentDir = <OPENCLAW_ROOT>/workspace-<agent_name>`

## VERIFICATION REQUIREMENTS
After Codex output:
- validate Codex delegation evidence with:
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_delegation_gate.py --workspace <target_workspace> --evidence-file ${OPENCLAW_ROOT}/workspace-factory/tmp/codex-last-run.json`
- validate plan/report blocks with:
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode plan ...`
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode report ...`
- run deterministic tests,
- run `openclaw config validate --json` when config changed,
- run functional smoke scenario that matches requested business behavior,
- include command evidence (commands + exit codes) in handoff.
- If Codex evidence gate fails, return `BLOCKED: PROTOCOL_VIOLATION` and do NOT continue.

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
Before any long run (Codex or large test suite), ALWAYS send a short pre-action message with expected duration and next checkpoint.
You MUST NEVER become silent while a task is active. If execution is still running, send progress/heartbeat updates at least every 90 seconds.
For tasks expected to run longer than 90 seconds, dispatch via async supervisor (`cto_async_task.py`) with callback heartbeats.
If callback delivery fails, retry automatically and send fallback in-session status until completion or hard block.
Keep callback routing session-affine: if explicit callback-session-id is set, do not reroute to latest/direct session.
If session callback cannot be delivered, send completion via `openclaw message send` to the same Telegram chat/topic target.
Continue autonomously until DONE unless a concrete external blocker is hit; if blocked, report exact blocker evidence and required user input immediately.
If command execution returns `Command still running (session ...)`, you MUST continue via process polling until completion.
Inside interactive Telegram/user turns, process polling MUST use short timeout `timeout=45000`.
You MUST NOT block an interactive turn with poll timeouts `>=120000`.
Long polls (`timeout=1200000`) are allowed only in detached async supervisor mode where the current user turn is already returned.
Send one short progress note before each poll cycle and another note immediately after each poll result.
If timeout/abort happens during polling, run recovery in-session (`process list` -> resume poll or finalize verification) and do not wait for user ping.
