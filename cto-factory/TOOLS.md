# TOOLS

Allowed:
- `read` (All file mutations MUST be done via remembered local code agent, `write`, `edit`, `apply_patch` tools are STRICTLY FORBIDDEN)
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
- `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_code_agent_memory.py" ensure --openclaw-root "$OPENCLAW_ROOT"` (resolve remembered local code agent)
- `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" ...` (Codex guarded path when remembered code agent is `codex`)
- `claude -p "<prompt>" --output-format text --permission-mode default` (Claude path when remembered code agent is `claude`)
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

Safety:
- mutate only target workspace,
- do not run destructive commands outside rollback policy,
- never expose secret values,
- avoid host-wide discovery commands unless user explicitly requested forensic investigation.
- Code/config mutation rules → `CODE_AGENT_PROTOCOLS.md`.
- Gateway restart protocol → `skills/factory-gateway-restart/SKILL.md`.
- Long-running task dispatch → `skills/factory-keepalive/SKILL.md`.
