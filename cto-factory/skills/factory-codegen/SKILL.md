---
name: factory-codegen
description: Orchestrate code generation through Codex with mandatory tests.
---

Rules:
- prefer incremental edits,
- keep config machine-readable,
- preserve SecretRef credential objects,
- avoid writing plaintext secrets.
- treat any behavior mutation (including cron payload/prompt/config edits) as code/config work.
- this skill is intended for generic code/config mutations. Do NOT use this skill for generating entirely new agents (use `factory-create-agent` for that).
- when calling Codex include exact instruction: `Write Unit Tests & Verify, make changes in case of failures and revalidate. Repeat until success.`.
- preferred invocation path for code work: use `sessions_spawn` (Codex model) with prompt containing `Write Unit Tests & Verify`.
- fallback invocation path: run `codex exec` through `exec`.
- before Codex delegation, detect current provider/model context from root `openclaw.json` and keep generated model config aligned with it.
- when invoking `codex exec --model`, use bare model ids only (for example `gpt-5.3-codex`), not provider-prefixed ids.
- worker prompt sent to delegated Codex must include:
  - `You are running inside codex exec.`
  - `Do NOT run codex or codex exec.`
  - `Implement files directly and run tests directly in this workspace.`
- if stderr contains `stream disconnected before completion`, retry the same Codex command up to 10 times with exponential backoff before blocking.
- do not run mutating tools before the first successful Codex delegation.
- do not provide runnable implementation snippets in chat before the first successful Codex delegation and green tests.
- record the exact `codex exec` command and exit code in the handoff report.
- always generate a companion test file for every new tool (for example `tools/my-tool.test.js`).
- after every codex invocation, execute generated/affected tests immediately.
- if test fails, run codex again with a fix prompt and rerun tests until green before handoff.
- include codex command + codex exit code + test command output + pass/fail status in the final report to CTO.
- if Codex delegation was skipped, mark task `BLOCKED: PROTOCOL_VIOLATION`.
- do not run broad host diagnostics by default (`find /Users`, `env | grep token|secret`) for regular coding tasks.

Restriction:
- you are forbidden from direct `write`, `edit`, or `apply_patch` implementation of `.js`, `.ts`, or `.py` logic.
- direct file writes are allowed for `.json`, `.yaml`, `.yml`, and `.md` (config/docs) only.

Procedure for code tasks:
0. If user asked "via Codex" or requested file creation/modification, first response must be PLAN + executable Codex delegation action; do not include final implementation snippets before evidence.
1. Prepare implementation brief for Codex (scope, files, acceptance criteria). Be sure to explicitly point Codex to the ROOT project directory.
2. Add provider/model context from current `openclaw.json` and state whether provider switch is allowed.
3. Delegate via `sessions_spawn` and include exact line: `Write Unit Tests & Verify`.
4. If `sessions_spawn` is unavailable, run fallback `exec` + `codex exec`. Ensure:
   - `--cd` points to the ROOT project location,
   - `--model` is bare id format,
   - prompt is shell-safe (no backticks in double-quoted strings; prefer stdin).
5. Apply Codex-produced output.
6. If `openclaw.json` was modified, IMMEDIATELY run `OPENCLAW_CONFIG_PATH=<path_to_openclaw.json> openclaw config validate --json`. If validation fails, capture the errors and delegate a fix back to Codex before proceeding.
7. Run deterministic tests immediately.
8. If tests fail, delegate a fix to Codex and rerun tests until green.
9. Report evidence: delegation method, command/call id, exit code, test commands, test exit codes, and `openclaw.json` validation results.
