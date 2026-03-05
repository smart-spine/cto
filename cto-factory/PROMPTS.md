# PROMPTS

## Codex Generation Contract

Use this contract for all code-generation subtasks delegated to Codex.

Required line:
`Write Unit Tests & Verify`

Mandatory requirements in the prompt:
- Manager mode applies only to CTO session:
  - CTO delegates implementation to Codex.
  - Delegated Codex worker writes code directly.
- Worker mode applies inside `codex exec`:
  - The delegated worker MUST NOT run `codex` or `codex exec` recursively.
  - The delegated worker MUST implement files and run tests directly in the current workspace.
- Before code generation for new agents: include confirmed intake decisions from the user (behavior, schedule, channels, escalation, safety policy).
- Provider/model guard:
  - read root `openclaw.json` and pass current provider/model context into the prompt,
  - propose 2-3 model options suitable for the task,
  - do not change provider family unless user explicitly approved it.
- For new agents, use the `factory-create-agent` constraints:
  - Implement only inside a dedicated `workspace-<agent_name>/` directory (relative to the `.openclaw` project root). Do NOT place inside `agents/<agent_name>/`.
  - Create `config/`, `tools/`, and `tests/` directories.
  - Create `AGENTS.md` or `README.md` as agent passport.
  - Register the new agent in `openclaw.json` at the root `.openclaw` directory.
- Generate tool implementation.
- Generate companion unit test (for example `tools/<tool>.test.js`).
- CODEX RESPONSIBILITIES:
  - Automatically deduce and install missing package dependencies (`npm install <pkg>`) if your code introduces external libraries. Do not rewrite code on `MODULE_NOT_FOUND` if an install fixes it.
  - Ensure your output is strictly formatted and linted (e.g., run `npx prettier --write` on the files you generate) before finishing.
- Run tests immediately.
- If tests fail, fix and rerun.
- Return test logs and final pass status.
- Return memory candidates for long-term storage (type + title + summary + evidence).
- Execute through Codex CLI (no direct in-session code mutation first).

## Codex CLI Invocation Safety

Mandatory invocation rules:
- For `codex exec --model`, use a bare model id (for example `gpt-5.3-codex`), not provider-prefixed ids (`openai/gpt-5.3-codex`).
- Avoid shell command-substitution in prompts:
  - do not place backticks in a double-quoted shell prompt,
  - prefer single-quoted strings or stdin (`printf ... | codex exec ... -`).
- If reasoning effort override is needed, use config key `model_reasoning_effort` (for example `-c model_reasoning_effort=\"high\"`).
- If the requested reasoning level is unsupported in the runtime (for example `extrahigh`), fall back to the highest supported level and report the actual level used.

Transient stream error policy (`https://api.openai.com/v1/responses`):
- If stderr contains `stream disconnected before completion`, treat it as transient.
- Retry the same `codex exec` command up to 10 attempts with exponential backoff.
- Only after max retries, return `BLOCKED: PROTOCOL_VIOLATION` with full evidence (commands, exit codes, retry count).

## Agent Build Intake Survey (Mandatory)

When task intent is "build/create/design a new agent", gather and confirm these fields before CODE:
- `agent_name`
- `responsibility` (one-sentence mission)
- `target_destination` (channel/chat/topic/thread)
- `interaction_style` (minimal or verbose, command style, formatting)
- `behavior_rules` (when to post, when to stay silent, thresholds/triggers)
- `data_sources` and API constraints
- `failure_policy` (retry, escalate, rollback, human confirmation points)
- `secrets_plan` (SecretRef sources only)
- `runtime_schedule` (if periodic)
- `model_preference` (speed/cost/quality)

Do not enter CODE until these are either explicitly answered or consciously defaulted and acknowledged.

Codex execution template:
```bash
printf "%s" "<worker prompt>" | codex exec --ephemeral --skip-git-repo-check --sandbox workspace-write --cd <root_project_workspace> --model <bare_model_id> -c model_reasoning_effort="high" -
```

Mandatory post-Codex verification:
- run targeted tests immediately after each codex execution,
- if tests fail, run codex again with a fix prompt and rerun tests,
- include codex command + exit code + test commands + exit codes in final report.
- include `memory_candidates` in final report for post-run memory gardening.

Prompt template:
```text
Task: <short task description>

Constraints:
- You are running inside codex exec.
- Do NOT run `codex` or `codex exec`.
- Implement files directly in this workspace and run tests directly.
- Work only inside workspace-<agent_name>/ (relative to the .openclaw root)
- Register the new agent in openclaw.json at the root of the workspace
- Provider context: <provider + currently used model family from openclaw.json>
- Model options: <option A / option B / option C with short tradeoffs>
- Confirmed intake decisions: <behavior survey summary>
- Write Unit Tests & Verify, make changes in case of failures and revalidate. Repeat until success.
- Produce minimal diffs and keep config machine-readable
- Never include plaintext secrets
- SELF-HEALING: Install missing libraries and auto-format your code (`prettier --write`).
- Include `memory_candidates` for durable facts/decisions/patterns discovered in the run.

Expected output:
1) created/updated files
2) codex command used and codex exit code
3) test command(s) executed
4) memory_candidates (array of objects: type, title, summary, evidence, confidence)
```

## No Pre-Delegation Code Output

For any code/file mutation request:
- Before the first successful Codex run, respond only with PLAN/ACT status and execution progress.
- Do NOT return runnable implementation snippets or full code blocks that satisfy the task.
- If the user explicitly requires "via Codex", treat any direct code snippet as `PROTOCOL_VIOLATION`.

## Operational Restart Contract

For `restart gateway` tasks (non-code operational control):
- use `factory-openclaw-ops` as the execution wrapper,
- send pre-restart acknowledgement first,
- run detached restart workflow (do not block current reply on websocket teardown),
- do not use native `gateway` tool `action=restart`,
- use dispatcher command:
  - `nohup /usr/bin/env bash ~/.openclaw/workspace-factory/scripts/gateway-restart-callback.sh --agent-id cto-factory >/dev/null 2>&1 &`,
- emit post-restart callback via `openclaw message send` to the bound Telegram topic (fallback: `openclaw system event --mode now --text ...`),
- report restart outcome (`success`/`failure`) after callback.

## OpenClaw Operational Command Contract

For any command that begins with `openclaw `:
- follow `PLAN -> ACT -> OBSERVE -> REACT`,
- run one command per `ACT` step for critical operations,
- include command exit code in `OBSERVE`,
- summarize only key output lines (no raw output dumps),
- if an operational command fails, report the failing command and immediate next fix action.
- for imperative operational requests (for example "restart gateway now"), do not end the turn after pre-ack: execute `ACT` in the same turn.
- for imperative operational requests, first assistant response must include at least one executable tool call (text-only response is protocol violation).
