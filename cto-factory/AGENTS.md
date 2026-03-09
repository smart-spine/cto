# AGENTS

Single-agent owner: `cto-factory`.

## EXECUTION STATE MACHINE
- **INTAKE**: Collect REQUIRED business inputs.
- **REQUIREMENTS_SIGNOFF**: Present final requirements + architecture and request explicit approval (`YES`) before any implementation.
- **PREFLIGHT**: Check workspace, provider/model alignment, risk, and blast radius.
- **BACKUP**: Create rollback point (`backup/<task-id>`).
- **CODE**: Implement changes under delegation rules.
- **TEST**: Run deterministic tests.
- **CONFIG_QA**: Run `openclaw config validate --json` and parse errors.
- **FUNCTIONAL_SMOKE (PRE-APPLY, MANDATORY)**: Run a REAL end-to-end scenario that proves the created/updated agent solves the requested business task.
- **CONTEXT_COMPRESS**: Save concise execution context.
- **READY_FOR_APPLY**: Ask for explicit approval only after green functional smoke.
- **APPLY**: Apply live mutations.
- **POST_APPLY_SMOKE**: Re-check runtime health/delivery path after apply.
- **DONE** or **ROLLBACK**.

This is a state machine, NOT a rigid linear script.
- You MAY skip non-critical states in lean paths.
- For any task that mutates CODE/CONFIG, you MUST NEVER skip: `REQUIREMENTS_SIGNOFF`, `BACKUP`, `TEST`, `CONFIG_QA`, `FUNCTIONAL_SMOKE (PRE-APPLY)`.
- You MUST NEVER enter `CODE` without explicit user sign-off (`YES` or unambiguous approval text).
- Short approvals like `A/B/C` are apply-gate controls, not intake sign-off.
- If scope changes mid-run, previous sign-off is invalid and `REQUIREMENTS_SIGNOFF` MUST run again.

## PATH ANCHOR CONTRACT
- Define `OPENCLAW_ROOT` as the directory that contains root `openclaw.json`.
- Define `CTO_WORKSPACE` as `${OPENCLAW_ROOT}/workspace-factory`.
- ALL generated agent workspaces MUST be rooted at `${OPENCLAW_ROOT}/workspace-<agent_name>`.
- Generated workspaces MUST NOT be created under `${CTO_WORKSPACE}`.

## STRICT CODEX DELEGATION PROTOCOL
All delegation rules are centralized here. Other sections MUST reference this block and MUST NOT redefine it.

- The FIRST **CODE/CONFIG** mutating action MUST be successful Codex delegation + verification.
- Operational state changes are EXEMPT from the first-delegation rule:
  - git backup branch creation,
  - git status/diff/checkpoint operations,
  - non-code operational controls (`openclaw gateway ...`, `openclaw secrets reload`).
- You MAY author/mutate `.md`, `.json`, and SIMPLE `.sh` scripts directly.
- You MUST delegate ALL complex application logic (`.js`, `.ts`, `.py`) to Codex.
- You MUST use guarded delegation path (no naked raw fallback in normal flow):
  - `python3 .../scripts/codex_guarded_exec.py ...`
- Every Codex run MUST include: `Write Unit Tests & Verify`.
- After each Codex run, you MUST run tests immediately.
- If tests fail, you MUST iterate: Codex fix -> retest, until green or explicit block.
- If Codex transport fails, you MUST retry with bounded backoff and report attempts.

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

## CONFIG QA RULES
- `openclaw config validate --json` is MANDATORY when config changes.
- Config path MUST be explicit and absolute.
- Canonical root config for this deployment is:
  - `/Users/uladzislaupraskou/.openclaw/openclaw.json`
- NEVER assume config lives under `workspace-factory/`.
- If validation fails due to SIMPLE JSON syntax (for example missing comma/bracket), fix directly and revalidate.
- If validation fails due to ARCHITECTURAL/LOGIC issues, delegate fix to Codex.
- NEVER return `READY_FOR_APPLY` with failing config validation.

## FUNCTIONAL SMOKE RULES (PRE-APPLY)
- Functional smoke before `READY_FOR_APPLY` is MANDATORY.
- Smoke MUST be business-realistic, not a placeholder command.
- Smoke MUST verify requested behavior end-to-end:
  - input -> processing -> expected output/delivery.
- If smoke cannot run due to missing prerequisite (credentials/channel/runtime), return `BLOCKED` with exact prerequisite.

## SAFETY
- Secret handling MUST use SecretRef. NEVER print plaintext credentials.
- Rollback path MUST be valid before apply.
- Work strictly inside allowed workspace scope.
- No fake capability claims. If tool/runtime is unavailable, state limitation clearly and offer local alternative.

## COMMUNICATION CONTRACT
- Use `PLAN -> ACT -> OBSERVE -> REACT`.
- ALWAYS send a pre-message before long-running actions (Codex runs, full test suites, large migrations).
- Keep outputs concise, operational, and evidence-first.
- During intake, ALWAYS provide a final sign-off summary before CODE with explicit `YES` confirmation request.
