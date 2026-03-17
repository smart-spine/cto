# Code Agent Protocols

This file is the single source of truth for how CTO delegates code/config mutations through the local coding CLI.

## 1) Runtime Selection + Memory (MANDATORY)

Before any CODE/CONFIG mutation:

1. Resolve `OPENCLAW_ROOT` (directory containing root `openclaw.json`).
2. Detect and persist active code agent:
   - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_code_agent_memory.py" ensure --openclaw-root "$OPENCLAW_ROOT"`
3. Read memory payload:
   - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_code_agent_memory.py" show --openclaw-root "$OPENCLAW_ROOT"`

Expected payload fields:
- `codeAgent`: `codex` or `claude`
- `ackPhrase`: `codex remembered` or `claudecode remembered`
- `protocolFile`: path to this file
- `protocolKey`: `CODEX_PROTOCOL` or `CLAUDE_PROTOCOL`

Session rule:
- On first runnable turn after deploy/restart, initialize memory with `ensure` and keep files in `.cto-brain`.
- On FIRST CODE step in a session, you MUST announce the remembered agent phrase as a standalone visible line in your response to the user BEFORE invoking any delegation command:
  - `codex remembered`, or
  - `claudecode remembered`.
- This announcement is a hard protocol requirement, not optional commentary. Missing it is a protocol violation.

If no supported code agent is found:
- return `BLOCKED: CODE_AGENT_UNAVAILABLE` with command evidence.

## 2) Global Delegation Guardrails (MANDATORY)

- First CODE/CONFIG mutation MUST be delegated via remembered code agent.
- Direct manual mutation of ANY project file is forbidden (`.md`, `.json`, `.sh`, `.js`, `.ts`, `.py`, and others).
- Manual fallback writes after delegation failure are forbidden (for example shell redirection/heredoc writes, ad-hoc interpreter writes, or manual patch edits used to bypass code-agent execution).
- `sessions_spawn`/`sessions_send`/subagent mutation fallback is forbidden for primary code/config work.

Exemptions from delegation requirement:
- `.cto-brain/` operational state and memory garden writes are performed by CTO Python helper scripts, not through code-agent delegation.
- git backup branch creation, git status/diff/checkpoint operations.
- non-code operational controls (`openclaw gateway ...`, `openclaw secrets reload`).

- Every delegation MUST include `Write Unit Tests & Verify`.
- For non-trivial tasks, MUST run `PLAN -> IMPLEMENT -> AUDIT`.
- Plan/exec outputs MUST include machine-checkable blocks:
  - `CODEX_PLAN_JSON_BEGIN/END`
  - `CODEX_EXEC_REPORT_JSON_BEGIN/END`
  (Markers are shared for both agents for gate compatibility.)
- Validate output via:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_codex_output_gate.py" --mode ...`
- If tests fail: iterate delegation -> fix -> retest until green or explicit blocker.
- If delegation command fails: retry through the same remembered code agent with corrected command/flags/prompt.
- If retries are exhausted: stop with `BLOCKED: CODE_AGENT_EXEC_FAILED` and report exact command + stderr evidence.
- Never replace failed code-agent mutation flow with cross-agent file-writing tasks.
- For long runs (>90s expected), use async supervisor + heartbeat:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" start ...`
- Shell contract for delegated commands:
  - ALWAYS run delegation commands under `bash` (for example `/usr/bin/env bash -lc "<cmd>"`).
  - NEVER run delegation command wrappers with `sh -lc` when command can contain `set -o pipefail` or strict parameter expansion.

## 3) CODEX_PROTOCOL

Primary command path:
- `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir <root_workspace> --model gpt-5.3-codex --prompt-file <prompt_file> --retries 3 --timeout 10800 --callback-agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-${OPENCLAW_SESSION_ID:-}}" --callback-message "CODE_AGENT_GUARD_COMPLETE status={status} exit_code={exit_code} used_attempts={used_attempts}"`

Notes:
- Never run `codex exec` naked in normal flow.
- Never run recursive codex calls inside delegated worker prompt.
- Keep `codex_guarded_exec.py --sandbox auto` default to allow Landlock fallback handling.

## 4) CLAUDE_PROTOCOL

Primary non-interactive command path:
- `claude -p "<prompt>" --output-format text --dangerously-skip-permissions`

Recommended flags:
- `--model claude-sonnet-4-5` (or explicitly requested model)
- `--effort medium|high` for complex tasks

Operational rules:
- Use same `PLAN -> IMPLEMENT -> AUDIT` contract and same JSON markers.
- For long runs, wrap command with `cto_async_task.py` and heartbeat callbacks.
- Keep working directory anchored to target root workspace before running Claude CLI.
- Always use `--dangerously-skip-permissions` to avoid interactive permission prompts blocking execution.

## 5) Sub-Agent Dispatch Protocol

When dispatching work to another openclaw agent (e.g. `openclaw agent --message ... --agent <id>`):

- Direct foreground `openclaw agent --message` calls are FORBIDDEN for any task expected to take >60 seconds.
- ALL sub-agent dispatches MUST use the async dispatcher wrapper:
  ```
  python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_dispatch_agent.py" \
    --agent <id> \
    --message "<task description>" \
    --session-id "${CTO_SESSION_ID:-${OPENCLAW_SESSION_ID:-}}"
  ```
- The wrapper returns `task_id` immediately. CTO receives heartbeat callbacks every 60 seconds.
- On `ASYNC_TASK_COMPLETE` callback: tail the log to read the sub-agent's output:
  ```
  python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" tail --task-id <id> --lines 60
  ```
- For short sub-agent calls (≤60s expected, e.g. a simple status query): foreground is allowed.
- If in doubt, always use the async wrapper — it returns immediately regardless.

## 6) Healthcheck Contract

When validating CTO deployment:

1. `cto_code_agent_memory.py ensure` succeeds.
2. Memory artifacts exist and are non-empty:
   - `.cto-brain/runtime/code_agent_memory.json`
   - `.cto-brain/facts/code_agent.md`
3. Local CTO call returns remembered marker:
   - `codex remembered` OR `claudecode remembered`.

If any check fails, deployment healthcheck MUST fail.
