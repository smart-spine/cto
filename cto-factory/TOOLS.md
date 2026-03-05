# TOOLS

Allowed:
- `read`, `write`, `edit`, `apply_patch`
- `exec` for deterministic commands
- `sessions_spawn` for Codex delegation
- `sessions_list`, `sessions_history`, `sessions_send`, `session_status` for agent orchestration
- `search_web` for autonomous research (used by `factory-research`)
- `web_fetch` for fetching external documentation and API pages

Preferred command families:
- `openclaw config validate --json`
- `openclaw secrets *`
- `openclaw gateway *`
- `openclaw system event --mode now --text "..."`
- `openclaw message send --channel telegram --target <chat>:topic:<topic> --message "..."`
- `codex exec ...` (for code mutations)
- `git` (backup/rollback)
- `node`, `python3`, `jq`
- `sessions_send` / `sessions_spawn` for multi-agent coordination

Safety:
- mutate only target workspace,
- do not run destructive commands outside rollback policy,
- never expose secret values.
- avoid host-wide discovery commands unless user explicitly requested forensic investigation.
- for any `openclaw ...` command, use `factory-openclaw-ops` (`PLAN -> ACT -> OBSERVE -> REACT`) and report exit code + key result line.
- for gateway restart, use detached restart flow + callback event so the user gets completion feedback.
- preferred restart ACT command:
  - `nohup /usr/bin/env bash ~/.openclaw/workspace-factory/scripts/gateway-restart-callback.sh --agent-id cto-factory >/dev/null 2>&1 &`.
- forbidden for restart: native `gateway` tool call with `action=\"restart\"`.
- forbidden: naked `openclaw gateway restart` without pre-ack and callback workflow.
- forbidden: `openclaw gateway restart && ...` command chaining in one blocking action.
- for code mutations, run Codex first, then tests, then report evidence.
- forbidden before Codex+tests evidence: direct `cron update/edit`, direct `gateway config.patch`, direct `write/edit` for mutation.
- forbidden: self-authored `write/edit/apply_patch` implementation logic in `.js/.ts/.py`.
- allowed for `.js/.ts/.py` only when applying Codex-produced output with explicit delegation evidence.
