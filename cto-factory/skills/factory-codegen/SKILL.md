---
name: factory-codegen
description: Orchestrate code generation through remembered local code agent (`codex` or `claude`) with mandatory tests.
---

Rules:
- Delegation protocol and command contracts → `CODE_AGENT_PROTOCOLS.md`.
- Heartbeat/keepalive rules → `HEARTBEAT.md` and `skills/factory-keepalive/SKILL.md`.
- This skill adds orchestration requirements only; it does not redefine generic mutation policy.
- prefer incremental edits,
- keep config machine-readable,
- preserve SecretRef credential objects,
- avoid writing plaintext secrets.
- treat any behavior mutation (including cron payload/prompt/config edits) as code/config work.
- this skill is intended for generic code/config mutations. Do NOT use for generating entirely new agents (use `factory-create-agent`).
- for micro scratch requests (ephemeral, no project/config/apply mutation), skip option-style intake and execute directly via remembered code agent.
- before delegation, detect current provider/model context from root `openclaw.json` and keep model config aligned.
- validate model id before run:
  - if malformed/provider-prefixed id is detected (e.g. `openai-codex/gpt-5.3-codex`), normalize to valid token (e.g. `gpt-5.3-codex`),
  - report fallback explicitly in `OBSERVE` (`model_requested`, `model_resolved`, reason).

Procedure for code tasks:
1. Build a deterministic requirement checklist:
   - create `tmp/code-agent-requirements-<task-id>.json` with explicit ids (`R1`, `R2`, ...).
2. Prepare implementation brief for remembered code agent (scope, files, acceptance criteria). Point it to the ROOT project directory.
3. Add provider/model context from current `openclaw.json` and state whether provider switch is allowed.
4. PLAN phase delegation (remembered code agent MUST plan before coding):
   - prompt code agent to return `CODEX_PLAN_JSON_BEGIN/END` block.
   - validate plan:
     - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode plan --requirements-file <requirements_json> --codex-output-file <plan_output_txt>`
   - if plan gate fails, send gap list back to code agent and rerun PLAN.
5. IMPLEMENT phase delegation, include exact line: `Write Unit Tests & Verify`.
   - Build command from remembered code-agent memory per `CODE_AGENT_PROTOCOLS.md`:
     - `codex` → `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir <root> --model gpt-5.3-codex --prompt-file <prompt_file> --retries 3 --timeout 10800 ...`
     - `claude` → temp file + stdin pattern from `CODE_AGENT_PROTOCOLS.md` section 4.
   - **FORBIDDEN**: naked `codex exec ...` or using the built-in `coding-agent` skill — both bypass retries, failure budget, JSON markers, and output gate.
   - For long runs, wrap with `cto_async_task.py` per `skills/factory-keepalive/SKILL.md`.
   - Ensure `--workdir` strictly points to the ROOT project location.
6. Validate implementation report block:
   - code-agent response MUST include `CODEX_EXEC_REPORT_JSON_BEGIN/END`.
   - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode report --requirements-file <requirements_json> --codex-output-file <exec_output_txt>`
   - if report gate fails, send missing requirement ids to code agent and rerun IMPLEMENT.
7. Apply code-agent-produced output.
8. **SESSION RESET**: If output modified any base profile files of an existing agent, clear/reset that agent's session context.
9. If `openclaw.json` was modified, run `openclaw config validate --json`. If validation fails, delegate fix back to code agent.
10. Run deterministic tests immediately. If tests fail, delegate fix and rerun until green.
11. Run artifact gate checks for expected files (exist + non-empty).
12. Report evidence: delegation method, command, exit code, `model_requested/model_resolved`, plan/report gate outputs, test commands, test exit codes, artifact-gate result, config validation results.

Restriction:
- direct implementation of ANY project file content is forbidden; all mutations must be delegated through remembered code agent.
- always generate a companion test file for every new tool.
