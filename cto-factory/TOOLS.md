# TOOLS

Allowed:
- `read`, `write`, `edit`, `apply_patch`
- `exec` for deterministic commands
- `sessions_spawn` for cross-agent runtime testing/orchestration
- `sessions_list`, `sessions_history`, `sessions_send`, `session_status` for agent orchestration
- `search_web` for autonomous research (used by `factory-research`)
- `web_fetch` for fetching external documentation and API pages

Preferred command families:
- `openclaw config validate --json`
- `openclaw secrets *`
- `openclaw gateway *`
- `openclaw system event --mode now --text "..."`
- `openclaw message send --channel telegram --target <chat>:topic:<topic> --message "..."`
- `OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"; python3 "${OPENCLAW_ROOT}/workspace-factory/scripts/codex_guarded_exec.py" ...` (primary path for code mutations)
- `git` (backup/rollback)
- `node`, `python3`, `jq`
- `sessions_send` / `sessions_spawn` for multi-agent coordination and black-box testing of created agents
- approved Python helpers:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_apply_state.py" ...`
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_async_task.py" ...`
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_context_checkpoint.py" ...`
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_config_diff.py" ...`
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_agent_artifact_gate.py" ...`
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_skill_consistency_gate.py" ...`
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_qa_suite_v2.py" ...`
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_stress_runner.py" ...`

Safety:
- mutate only target workspace,
- do not run destructive commands outside rollback policy,
- never expose secret values.
- avoid host-wide discovery commands unless user explicitly requested forensic investigation.
- for any code/config mutation behavior, follow the centralized `STRICT CODEX DELEGATION PROTOCOL` in `AGENTS.md`; command examples here do not override it.
- for any `openclaw ...` command, use `factory-openclaw-ops` (`PLAN -> ACT -> OBSERVE -> REACT`) and report exit code + key result line.
- for gateway restart, use detached restart flow + callback event so the user gets completion feedback.
- before gateway restart, run runtime detector:
  - `"$OPENCLAW_ROOT/workspace-factory/scripts/gateway-runtime-detect.sh" 12`
- preferred restart ACT command:
  - `OPENCLAW_ROOT="$OPENCLAW_ROOT" nohup /usr/bin/env bash "$OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh" --agent-id cto-factory --callback-session-id "${CTO_SESSION_ID:-$OPENCLAW_SESSION_ID}" >/dev/null 2>&1 &`.
- forbidden for restart: native `gateway` tool call with `action=\"restart\"`.
- forbidden: naked `openclaw gateway restart` without pre-ack and callback workflow.
- forbidden: `openclaw gateway restart && ...` command chaining in one blocking action.
- forbidden: `exec` with `background=true` for direct `codex_guarded_exec.py` runs.
- forbidden: inline env assignment with same-command expansion (bad: `OPENCLAW_ROOT=... python3 "$OPENCLAW_ROOT/..."`).
