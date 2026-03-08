# PROMPTS

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

## NEW AGENT GENERATION TEMPLATE
For new agent tasks, prompt MUST enforce:
- Workspace path: `workspace-<agent_name>/`.
- Base profile files at workspace root:
  - `IDENTITY.md`
  - `TOOLS.md`
  - `PROMPTS.md`
  - `AGENTS.md` or `README.md`
- Required folders:
  - `config/`, `tools/`, `tests/`, `skills/`
- Skill package minimum:
  - `skills/SKILL_INDEX.md`
  - at least one `skills/<name>/SKILL.md`
- Root config registration in `openclaw.json`.

## VERIFICATION REQUIREMENTS
After Codex output:
- run deterministic tests,
- run `openclaw config validate --json` when config changed,
- run functional smoke scenario that matches requested business behavior,
- include command evidence (commands + exit codes) in handoff.

## KEEP-ALIVE RULE
Before any long run (Codex or large test suite), ALWAYS send a short pre-action message with expected duration and next checkpoint.
