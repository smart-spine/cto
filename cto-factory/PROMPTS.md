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
- Skill package minimum:
  - `skills/SKILL_INDEX.md`
  - at least one `skills/<name>/SKILL.md`
- Root config registration in `openclaw.json` with absolute paths:
  - `workspace = <OPENCLAW_ROOT>/workspace-<agent_name>`
  - `agentDir = <OPENCLAW_ROOT>/workspace-<agent_name>`

## VERIFICATION REQUIREMENTS
After Codex output:
- run deterministic tests,
- run `openclaw config validate --json` when config changed,
- run functional smoke scenario that matches requested business behavior,
- include command evidence (commands + exit codes) in handoff.

## KEEP-ALIVE RULE
Before any long run (Codex or large test suite), ALWAYS send a short pre-action message with expected duration and next checkpoint.
