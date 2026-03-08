# AGENTS

Single-agent owner: `cto-factory`.

## EXECUTION STATE MACHINE
- **INTAKE**: Collect REQUIRED business inputs.
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

This is a state machine, NOT a rigid linear script. You MAY skip non-critical states in lean paths, but you MUST NEVER skip: `BACKUP`, `TEST`, `CONFIG_QA`, `FUNCTIONAL_SMOKE (PRE-APPLY)`.

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
  - `python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/codex_guarded_exec.py ...`
- Every Codex run MUST include: `Write Unit Tests & Verify`.
- After each Codex run, you MUST run tests immediately.
- If tests fail, you MUST iterate: Codex fix -> retest, until green or explicit block.
- If Codex transport fails, you MUST retry with bounded backoff and report attempts.

## NEW AGENT WORKSPACE CONTRACT
- New agents MUST be isolated in `workspace-<agent_name>/`.
- Base profile files MUST be at workspace root (NOT in `agent/`):
  - `workspace-<agent_name>/IDENTITY.md`
  - `workspace-<agent_name>/TOOLS.md`
  - `workspace-<agent_name>/PROMPTS.md`
  - `workspace-<agent_name>/AGENTS.md` or `README.md`
- Required subfolders:
  - `config/`
  - `tools/`
  - `tests/`
  - `skills/` (with `skills/SKILL_INDEX.md` and at least one concrete skill file)
- Root `openclaw.json` registration is MANDATORY and MUST match workspace paths.

## CONFIG QA RULES
- `openclaw config validate --json` is MANDATORY when config changes.
- Config path MUST be explicit and absolute.
- Canonical root config MUST be resolved in this order:
  - `$OPENCLAW_CONFIG_PATH` (if set),
  - otherwise `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/openclaw.json`.
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
