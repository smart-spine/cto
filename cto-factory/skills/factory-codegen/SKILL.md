---
name: factory-codegen
description: Orchestrate code generation through remembered local code agent (`codex` or `claude`) with mandatory tests.
---

Rules:
- Follow the centralized `STRICT CODE AGENT DELEGATION PROTOCOL` in `AGENTS.md`.
- Resolve active code agent from memory before delegation:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_code_agent_memory.py" show --openclaw-root "$OPENCLAW_ROOT"`
- Follow concrete per-agent command contract in `CODE_AGENT_PROTOCOLS.md`.
- This skill adds orchestration requirements only; it does not redefine generic mutation policy.
- prefer incremental edits,
- keep config machine-readable,
- preserve SecretRef credential objects,
- avoid writing plaintext secrets.
- if a code-agent run is expected to be long, send a short keep-alive pre-warning before dispatch.
- code-agent runs expected to exceed 90 seconds MUST be dispatched via `cto_async_task.py` with callback heartbeats.
- you MUST NEVER leave the user without status while code-agent execution is running; heartbeat/status updates are mandatory every <=90 seconds.
- for `codex_guarded_exec.py` (Codex path), default execution mode MUST be foreground (do NOT set `background=true` in `exec` call).
- if runtime returns `Command still running (session ...)`, you MUST immediately enter a `process poll` loop until completion/failure.
- for interactive Telegram/user turns, each poll MUST use `timeout=45000`.
- you MUST NOT use poll timeout `>=120000` during an active interactive turn.
- send one status note before each poll cycle and one note after each poll result.
- long polls (`timeout=1200000`) are allowed only when using detached async supervisor flow after the current user turn already returned.
- treat any behavior mutation (including cron payload/prompt/config edits) as code/config work.
- this skill is intended for generic code/config mutations. Do NOT use this skill for generating entirely new agents (use `factory-create-agent` for that).
- when calling remembered code agent include exact instruction: `Write Unit Tests & Verify, make changes in case of failures and revalidate. Repeat until success.`.
- required invocation path for code work:
  - Codex: guarded wrapper through `exec`.
  - Claude: non-interactive Claude CLI command as defined in `CODE_AGENT_PROTOCOLS.md`.
- naked `codex exec` is forbidden.
- before delegation, detect current provider/model context from root `openclaw.json` and keep generated model config aligned with it.
- validate model id before run:
  - if malformed/provider-prefixed id is detected (for example `openai-codex/gpt-5.3-codex`), normalize to valid token (for example `gpt-5.3-codex`),
  - report fallback explicitly in `OBSERVE` (`model_requested`, `model_resolved`, reason).
- record exact code-agent command and exit code in handoff report.
- include underlying delegated command when available in wrapper output.
- always generate a companion test file for every new tool (for example `tools/my-tool.test.js`).
- after every code-agent invocation, execute generated/affected tests immediately.
- if test fails, rerun delegation with a fix prompt and rerun tests until green before handoff.
- include code-agent command + code-agent exit code + test command output + pass/fail status in the final report to CTO.
- if delegation was skipped, mark task `BLOCKED: PROTOCOL_VIOLATION`.
- do not run broad host diagnostics by default (`find $HOME`, `env | grep token|secret`) for regular coding tasks.
- if task parses feed/web content, enforce sanitization and add tests for raw-markup suppression.
- if delegation hangs or returns retryable transport errors, rerun with bounded retries and timeout.
- `sessions_spawn`/`sessions_send` may be used only for black-box runtime checks against created agents, never for primary code generation.
- never report success unless all expected output files exist and are non-empty.
- for non-trivial tasks, you MUST enforce `PLAN -> IMPLEMENT -> AUDIT` code-agent loop.
- `PLAN -> IMPLEMENT -> AUDIT` loop is mandatory for:
  - new agent creation,
  - interactive UX features (buttons/menus/callbacks),
  - multi-file changes,
  - any task with 3+ explicit requirements.

Restriction:
- direct implementation of `.js`, `.ts`, or `.py` logic is governed by `AGENTS.md` and is not restated here.

Procedure for code tasks:
1. Build a deterministic requirement checklist first:
   - create `tmp/code-agent-requirements-<task-id>.json` with explicit ids (`R1`, `R2`, ...).
2. Prepare implementation brief for remembered code agent (scope, files, acceptance criteria). Be sure to explicitly point it to the ROOT project directory.
3. Add provider/model context from current `openclaw.json` and state whether provider switch is allowed.
4. PLAN phase delegation (remembered code agent MUST plan before coding):
   - prompt code agent to return only `CODEX_PLAN_JSON_BEGIN/END` block.
   - run delegated command and capture output. For long runs, you MUST wrap command in async supervisor:
     - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" start --task-id <id>-plan --cwd <root_project_workspace> --cmd "<code_agent_command>" --callback-agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" --callback-progress-message "ASYNC_TASK_HEARTBEAT task_id={task_id} status={status} elapsed={elapsed_seconds}s heartbeat={heartbeat_index}" --callback-message "ASYNC_TASK_COMPLETE task_id={task_id} status={status} exit_code={exit_code}"`
   - when async path is used, poll status/log via `cto_async_task.py status|tail` and continue reporting until terminal state.
   - DO NOT pass `background=true` when executing this command.
   - validate plan block:
     - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode plan --requirements-file <requirements_json> --codex-output-file <plan_output_txt>`
   - if plan gate fails, send gap list back to code agent and rerun PLAN phase.
5. IMPLEMENT phase delegation and include exact line: `Write Unit Tests & Verify`.
   - Build command from remembered code-agent memory:
     - if `codeAgent=codex`:
       - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir <root_project_workspace> --model gpt-5.3-codex --prompt-file <prompt_file> --retries 3 --timeout 10800 --callback-agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" --callback-message "CODEX_GUARD_COMPLETE status={status} exit_code={exit_code} used_attempts={used_attempts}"`
     - if `codeAgent=claude`:
       - `claude -p "<prompt_with_same_contract_and_markers>" --output-format text --permission-mode default`
   - If remembered `codeAgent` is neither `codex` nor `claude`, stop with `BLOCKED: CODE_AGENT_UNAVAILABLE`.
   - for long runs, wrap command in async supervisor:
     - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" start --task-id <id> --cwd <root_project_workspace> --cmd "<code_agent_command>" --callback-agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" --callback-progress-message "ASYNC_TASK_HEARTBEAT task_id={task_id} status={status} elapsed={elapsed_seconds}s heartbeat={heartbeat_index}" --callback-message "ASYNC_TASK_COMPLETE task_id={task_id} status={status} exit_code={exit_code}"`
   - when async path is used, poll status/log via `cto_async_task.py status|tail` and continue reporting until terminal state.
   Ensure `--workdir` strictly points to the ROOT project location.
   - DO NOT pass `background=true` when executing this command.
   - if tool still returns running session, switch to explicit process polling immediately:
     - `process(action=poll, sessionId=<running_session_id>, timeout=45000)`
   - if poll returns still-running, continue polling with the same timeout until terminal status.
   - if poll branch gets aborted/timed out, run recovery immediately:
     - `process(action=list)`
     - if target session is still running, resume `timeout=45000` polling;
     - if target session is no longer running, proceed to verification gates (tests/config/artifacts/report parsing) and publish status without waiting for user ping.
6. Validate implementation report block:
   - code-agent response MUST include `CODEX_EXEC_REPORT_JSON_BEGIN/END`.
   - run:
     - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode report --requirements-file <requirements_json> --codex-output-file <exec_output_txt>`
   - if report gate fails, send missing requirement ids to code agent and rerun IMPLEMENT phase.
7. Apply code-agent-produced output.
8. **SESSION RESET**: If the applied output modified any base profile files (`PROMPTS.md`, `AGENTS.md`, `IDENTITY.md`, `TOOLS.md`) of an existing agent, you MUST explicitly clear or reset that target agent's session context. Old session contexts will continue using outdated instructions and block the new rules from taking effect.
8. If `openclaw.json` was modified, IMMEDIATELY run `OPENCLAW_CONFIG_PATH=<path_to_openclaw.json> openclaw config validate --json`. If validation fails, capture the errors and delegate a fix back to remembered code agent before proceeding.
9. Run deterministic tests immediately.
10. If tests fail, delegate a fix to remembered code agent and rerun tests until green.
11. Run artifact gate checks for expected files (exist + non-empty) before reporting readiness.
12. Report evidence: delegation method, command, exit code, `model_requested/model_resolved`, plan/report gate outputs, test commands, test exit codes, artifact-gate result, and `openclaw.json` validation results.
