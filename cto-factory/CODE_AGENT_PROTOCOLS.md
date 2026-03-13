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
- On first mutation step in a session, explicitly report remembered agent phrase:
  - `codex remembered`, or
  - `claudecode remembered`.

If no supported code agent is found:
- return `BLOCKED: CODE_AGENT_UNAVAILABLE` with command evidence.

## 2) Global Delegation Guardrails (MANDATORY)

- First CODE/CONFIG mutation MUST be delegated via remembered code agent.
- Direct manual mutation of complex logic (`.js`, `.ts`, `.py`) is forbidden.
- Every delegation MUST include `Write Unit Tests & Verify`.
- For non-trivial tasks, MUST run `PLAN -> IMPLEMENT -> AUDIT`.
- Plan/exec outputs MUST include machine-checkable blocks:
  - `CODEX_PLAN_JSON_BEGIN/END`
  - `CODEX_EXEC_REPORT_JSON_BEGIN/END`
  (Markers are shared for both agents for gate compatibility.)
- Validate output via:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_codex_output_gate.py" --mode ...`
- If tests fail: iterate delegation -> fix -> retest until green or explicit blocker.
- For long runs (>90s expected), use async supervisor + heartbeat:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" start ...`

## 3) CODEX_PROTOCOL

Primary command path:
- `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir <root_workspace> --model gpt-5.3-codex --prompt-file <prompt_file> --retries 3 --timeout 10800 --callback-agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" --callback-message "CODE_AGENT_GUARD_COMPLETE status={status} exit_code={exit_code} used_attempts={used_attempts}"`

Notes:
- Never run `codex exec` naked in normal flow.
- Never run recursive codex calls inside delegated worker prompt.

## 4) CLAUDE_PROTOCOL

Primary non-interactive command path:
- `claude -p "<prompt>" --output-format text --permission-mode default`

Recommended flags:
- `--model claude-sonnet-4-5` (or explicitly requested model)
- `--effort medium|high` for complex tasks

Operational rules:
- Use same `PLAN -> IMPLEMENT -> AUDIT` contract and same JSON markers.
- For long runs, wrap command with `cto_async_task.py` and heartbeat callbacks.
- Keep working directory anchored to target root workspace before running Claude CLI.

## 5) Healthcheck Contract

When validating CTO deployment:

1. `cto_code_agent_memory.py ensure` succeeds.
2. Memory artifacts exist and are non-empty:
   - `.cto-brain/runtime/code_agent_memory.json`
   - `.cto-brain/facts/code_agent.md`
3. Local CTO call returns remembered marker:
   - `codex remembered` OR `claudecode remembered`.

If any check fails, deployment healthcheck MUST fail.
