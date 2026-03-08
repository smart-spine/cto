---
name: factory-codegen
description: Orchestrate code generation through Codex with mandatory tests.
---

Rules:
- prefer incremental edits,
- keep config machine-readable,
- preserve SecretRef credential objects,
- avoid writing plaintext secrets.
- if a codex run is expected to be long, send a short keep-alive pre-warning before dispatch.
- treat any behavior mutation (including cron payload/prompt/config edits) as code/config work.
- this skill is intended for generic code/config mutations. Do NOT use this skill for generating entirely new agents (use `factory-create-agent` for that).
- when calling Codex include exact instruction: `Write Unit Tests & Verify, make changes in case of failures and revalidate. Repeat until success.`.
- required invocation path for code work: run guarded wrapper through `exec`.
- naked `codex exec` is forbidden.
- before Codex delegation, detect current provider/model context from root `openclaw.json` and keep generated model config aligned with it.
- validate model id before Codex run:
  - if malformed/provider-prefixed id is detected (for example `openai-codex/gpt-5.3-codex`), normalize to valid token (for example `gpt-5.3-codex`),
  - report fallback explicitly in `OBSERVE` (`model_requested`, `model_resolved`, reason).
- do not run mutating tools before the first successful Codex delegation.
- record the exact guarded command and exit code in the handoff report.
- include the underlying `codex exec` command when available in wrapper output.
- always generate a companion test file for every new tool (for example `tools/my-tool.test.js`).
- after every codex invocation, execute generated/affected tests immediately.
- if test fails, run codex again with a fix prompt and rerun tests until green before handoff.
- include codex command + codex exit code + test command output + pass/fail status in the final report to CTO.
- if Codex delegation was skipped, mark task `BLOCKED: PROTOCOL_VIOLATION`.
- do not run broad host diagnostics by default (`find $HOME`, `env | grep token|secret`) for regular coding tasks.
- if task parses feed/web content, enforce sanitization and add tests for raw-markup suppression.
- if delegation hangs or returns retryable transport errors, rerun via guarded wrapper with bounded retries and timeout.
- `sessions_spawn`/`sessions_send` may be used only for black-box runtime checks against created agents, never for primary code generation.
- never report success unless all expected output files exist and are non-empty.

Restriction:
- you are forbidden from direct `write`, `edit`, or `apply_patch` implementation of `.js`, `.ts`, or `.py` logic.
- direct file writes are allowed for `.json`, `.yaml`, `.yml`, and `.md` (config/docs) only.

Procedure for code tasks:
1. Prepare implementation brief for Codex (scope, files, acceptance criteria). Be sure to explicitly point Codex to the ROOT project directory.
2. Add provider/model context from current `openclaw.json` and state whether provider switch is allowed.
3. Delegate via guarded wrapper and include exact line: `Write Unit Tests & Verify`.
   - `OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}" && python3 "$OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir <root_project_workspace> --model gpt-5.3-codex --prompt-file <prompt_file> --retries 3 --timeout 420`
   Ensure `--workdir` strictly points to the ROOT project location.
4. Apply Codex-produced output.
5. If `openclaw.json` was modified, IMMEDIATELY run `OPENCLAW_CONFIG_PATH=<path_to_openclaw.json> openclaw config validate --json`. If validation fails, capture the errors and delegate a fix back to Codex before proceeding.
6. Run deterministic tests immediately.
7. If tests fail, delegate a fix to Codex and rerun tests until green.
8. Run artifact gate checks for expected files (exist + non-empty) before reporting readiness.
9. Report evidence: delegation method, command, exit code, `model_requested/model_resolved`, test commands, test exit codes, artifact-gate result, and `openclaw.json` validation results.
