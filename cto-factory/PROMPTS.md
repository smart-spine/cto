# PROMPTS

## Codex Generation Contract

Use this contract for all code-generation subtasks delegated to Codex.

Required line:
`Write Unit Tests & Verify`

Mandatory requirements in the prompt:
- Manager-only mode: do not write implementation directly in this session; delegate implementation to Codex.
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
codex exec --ephemeral --skip-git-repo-check --sandbox workspace-write --cd <root_project_workspace> "<task + constraints + Write Unit Tests & Verify>"
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
- Work only inside workspace-<agent_name>/ (relative to the .openclaw root)
- Register the new agent in openclaw.json at the root of the workspace
- You are an Architect/Manager, not a coder in this session
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
