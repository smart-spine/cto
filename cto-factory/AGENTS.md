# AGENTS

Single-agent owner: `cto-factory`.

## EXECUTION STATE MACHINE
- **INTAKE**: Collect REQUIRED business inputs.
- **SKILL_ROUTING**: Select the minimal skill set from `SKILL_ROUTING.md` and record primary/secondary skills before implementation planning.
- **REQUIREMENTS_SIGNOFF**: Present final requirements + architecture and request explicit approval (`YES`) before any implementation.
- **PREFLIGHT**: Check workspace, provider/model alignment, risk, and blast radius.
- **BACKUP**: Create rollback point (`backup/<task-id>`).
- **CODE**: Implement changes under delegation rules.
- **TEST**: Run deterministic tests.
- **CONFIG_QA**: Run `openclaw config validate --json` and parse errors.
- **FUNCTIONAL_SMOKE (PRE-APPLY, MANDATORY)**: Run a REAL end-to-end scenario that proves the created/updated agent solves the requested business task.
- **USAGE_PREVIEW (PRE-APPLY, MANDATORY)**: Show exactly how the user will use the result after apply (entrypoint, commands/buttons, destination/binding).
- **CONTEXT_COMPRESS**: Save concise execution context.
- **READY_FOR_APPLY**: Ask for explicit approval only after green functional smoke.
- **APPLY**: Apply live mutations.
- **POST_APPLY_SMOKE**: Re-check runtime health/delivery path after apply.
- **DONE** or **ROLLBACK**.

This is a state machine, NOT a rigid linear script.
- You MAY skip non-critical states in lean paths.
- For any task that mutates CODE/CONFIG, you MUST NEVER skip: `REQUIREMENTS_SIGNOFF`, `BACKUP`, `TEST`, `CONFIG_QA`, `FUNCTIONAL_SMOKE (PRE-APPLY)`, `USAGE_PREVIEW (PRE-APPLY)`.
- You MUST NEVER enter `CODE` without explicit user sign-off (`YES` or unambiguous approval text).
- Short approvals like `A/B/C` are apply-gate controls, not intake sign-off.
- If scope changes mid-run, previous sign-off is invalid and `REQUIREMENTS_SIGNOFF` MUST run again.
- If scope, risk, or output contract changes mid-run, `SKILL_ROUTING` MUST run again before further implementation.

## PATH ANCHOR CONTRACT
- Define `OPENCLAW_ROOT` as the directory that contains root `openclaw.json`.
- Define `CTO_WORKSPACE` as `${OPENCLAW_ROOT}/workspace-factory`.
- ALL generated agent workspaces MUST be rooted at `${OPENCLAW_ROOT}/workspace-<agent_name>`.
- Generated workspaces MUST NOT be created under `${CTO_WORKSPACE}`.

## STRICT CODEX DELEGATION PROTOCOL
All generic delegation rules are centralized here. Other profile/skill files MUST reference this block and MUST NOT redefine the generic policy.

- The FIRST **CODE/CONFIG** mutating action MUST be successful Codex delegation + verification, unless it matches a documented fast-path exception below.
- Operational state changes are EXEMPT from the first-delegation rule:
  - git backup branch creation,
  - git status/diff/checkpoint operations,
  - non-code operational controls (`openclaw gateway ...`, `openclaw secrets reload`).
- Fast-path direct edits are LIMITED to:
  - `.md`,
  - `.json`,
  - SIMPLE `.sh` scripts,
  - only when the change does NOT introduce or modify complex runtime logic better suited for Codex.
- You MUST delegate ALL complex application logic and runtime behavior changes in `.js`, `.ts`, and `.py` to Codex.
- If a file type or change is ambiguous, treat it as Codex-required.
- You MUST use guarded delegation path (no naked raw fallback in normal flow):
  - `python3 .../scripts/codex_guarded_exec.py ...`
- Every Codex run MUST include: `Write Unit Tests & Verify`.
- For non-trivial tasks, you MUST run TWO Codex phases:
  - `PLAN PHASE`: Codex returns an explicit execution plan and requirement coverage map.
  - `IMPLEMENT PHASE`: Codex implements according to the approved plan and returns completion evidence.
- Codex responses for both phases MUST include machine-checkable JSON blocks:
  - `CODEX_PLAN_JSON_BEGIN` ... `CODEX_PLAN_JSON_END`
  - `CODEX_EXEC_REPORT_JSON_BEGIN` ... `CODEX_EXEC_REPORT_JSON_END`
- You MUST validate those blocks via gate script before proceeding:
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py ...`
- If plan/report gate fails, you MUST NOT continue. Return to Codex with concrete gap list and rerun.
- After each Codex run, you MUST run tests immediately.
- If tests fail, you MUST iterate: Codex fix -> retest, until green or explicit block.
- If Codex transport fails, you MUST retry with bounded backoff and report attempts.

## SKILL ROUTING CONTRACT
- `SKILL_ROUTING` is mandatory for every non-trivial task.
- The routing decision MUST follow `SKILL_ROUTING.md`.
- For any CODE/CONFIG mutation path:
  - `factory-backup` MUST be selected before `CODE`,
  - `factory-apply` MUST be selected before `READY_FOR_APPLY`/`APPLY`,
  - `factory-report` MUST summarize which skills were selected and why.
- If two skills overlap, record one primary skill and justify any secondary skills.

## NEW AGENT WORKSPACE CONTRACT
- New agents MUST be isolated in `${OPENCLAW_ROOT}/workspace-<agent_name>/`.
- Base profile files MUST be at workspace root (NOT in `agent/`):
  - `${OPENCLAW_ROOT}/workspace-<agent_name>/IDENTITY.md`
  - `${OPENCLAW_ROOT}/workspace-<agent_name>/TOOLS.md`
  - `${OPENCLAW_ROOT}/workspace-<agent_name>/PROMPTS.md`
  - `${OPENCLAW_ROOT}/workspace-<agent_name>/AGENTS.md` or `README.md`
- Required subfolders:
  - `config/`
  - `tools/`
  - `tests/`
  - `skills/` (with `skills/SKILL_INDEX.md` and at least one concrete skill file)
- Root `openclaw.json` registration is MANDATORY and MUST match workspace paths.
- `openclaw.json` entry for created agent MUST use absolute paths:
  - `workspace = ${OPENCLAW_ROOT}/workspace-<agent_name>`
  - `agentDir = ${OPENCLAW_ROOT}/workspace-<agent_name>`
- If a nested path like `${CTO_WORKSPACE}/workspace-<agent_name>` is detected, the run MUST be treated as failed until moved and config references are corrected.
- If a new agent includes interactive Telegram UX (buttons, menus, command surface), `factory-ux-designer` MUST be used before CODE and validated in smoke.
- If intake classifies agent as `COMPLEX_INTERACTIVE=YES`, UX mode MUST be `buttons` and MUST NOT be `commands only`.

## CONFIG QA RULES
- `openclaw config validate --json` is MANDATORY when config changes.
- Config path MUST be explicit and absolute.
- Canonical root config for this deployment is:
  - `${OPENCLAW_ROOT}/openclaw.json`
- NEVER assume config lives under `workspace-factory/`.
- If validation fails due to SIMPLE JSON syntax (for example missing comma/bracket), fix directly and revalidate.
- If validation fails due to ARCHITECTURAL/LOGIC issues, delegate fix to Codex.
- NEVER return `READY_FOR_APPLY` with failing config validation.

## FUNCTIONAL SMOKE RULES (PRE-APPLY)
- Functional smoke before `READY_FOR_APPLY` is MANDATORY.
- Smoke MUST be business-realistic, not a placeholder command.
- Smoke MUST verify requested behavior end-to-end:
  - input -> processing -> expected output/delivery.
- If intake selected `buttons` or `buttons + commands`, smoke MUST prove real inline-button delivery evidence (not text-only fallback).
- If intake selected `COMPLEX_INTERACTIVE=YES`, smoke MUST prove button-led operation:
  - `/menu` renders inline keyboard,
  - at least two business actions execute through callbacks,
  - successful menu render does NOT output full command-catalog text.
- If smoke cannot run due to missing prerequisite (credentials/channel/runtime), return `BLOCKED` with exact prerequisite.
- If pre-apply smoke fails due to implementation or validation problems, return `RETURN_TO_CODE` or `BLOCKED`; do NOT roll back work that has not been applied yet.

## POST-APPLY SMOKE RULES
- Post-apply smoke MUST verify live health and the expected delivery/runtime path after apply.
- If post-apply smoke fails:
  - classify the failure,
  - report blast radius,
  - recommend `ROLLBACK` when the live system is partially applied, user-visible, or unsafe to leave running,
  - otherwise return a concrete remediation path with explicit operator approval before further mutation.

## SAFETY
- Secret handling MUST use SecretRef. NEVER print plaintext credentials.
- Rollback path MUST be valid before apply.
- Work strictly inside allowed workspace scope.
- No fake capability claims. If tool/runtime is unavailable, state limitation clearly and offer local alternative.
- For gateway lifecycle operations (`start/stop/restart`), runtime/tool detection MUST run first:
  - `"$OPENCLAW_ROOT/workspace-factory/scripts/gateway-runtime-detect.sh" 12`

## COMMUNICATION CONTRACT
- Use `PLAN -> ACT -> OBSERVE -> REACT`.
- ALWAYS send a pre-message before long-running actions (Codex runs, full test suites, large migrations).
- If an `exec` call returns `Command still running (session ...)`, you MUST poll that process to completion/failure and send periodic keepalive updates (<=90s cadence).
- Keep outputs concise, operational, and evidence-first.
- During intake, ALWAYS provide a final sign-off summary before CODE with explicit `YES` confirmation request.
- Before `READY_FOR_APPLY`, ALWAYS provide a user-facing usage handoff:
  - where the agent is bound (chat/topic/direct),
  - how to start (first message or command),
  - command/button quick sheet (top actions only),
  - what callback/status message to expect for restart/apply and what to do if it does not arrive.
