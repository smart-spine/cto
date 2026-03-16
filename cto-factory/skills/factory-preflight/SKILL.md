---
name: factory-preflight
description: Validate runtime prerequisites and secret-reference safety before mutation.
---

Checks:
- `openclaw` and at least one supported code agent binary (`codex` or `claude`) are available,
- remembered code agent memory exists or is created:
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_code_agent_memory.py" ensure --openclaw-root "$OPENCLAW_ROOT"`,
- secret-like credential fields use SecretRef object shape `{source, provider, id}`,
- task stays within declared workspace scope,
- free disk space in project filesystem is sufficient for the run (warn/block if critically low),
- current git status is captured before backup (report dirty/clean),
- current untracked-file inventory is captured before backup:
  - classify files as generated scratch vs user-owned artifacts,
  - if user-owned untracked files exist (for example `.env`, screenshots, copied logs, manual notes), WARN or BLOCK before any rollback-capable flow,
  - surface a `rollback_cleanup_risk` note that `git clean -fd` would delete those files unless protected or relocated,
- gateway health is captured (`openclaw gateway status`) for tasks that require runtime checks/telegram delivery,
- root `openclaw.json` provider/model context is read and summarized before CODE,
- provider/model proposal aligns with currently used provider family unless explicitly overridden by user,
- selected code-agent model id sanity is checked before delegation:
  - malformed/provider-prefixed model ids (for example `openai-codex/gpt-5.3-codex`) are normalized or flagged,
  - chosen fallback is reported before CODE starts,
- for cross-agent orchestration tasks: verify `tools.sessions.visibility` is `all`,
- for cross-agent orchestration tasks: verify `tools.agentToAgent.enabled` is `true` and `tools.agentToAgent.allow` includes both requester and target patterns,
- `.cto-brain/INDEX.md` exists (or is created) and typed memory folders are present:
  - `facts`, `decisions`, `patterns`, `incidents`, `preferences`, `plans/active`, `plans/completed`, `archive`.
- if referenced memory notes are stale (older than 30 days), flag them for review in preflight output.
- if config is expected to change, reserve and report a deterministic baseline snapshot path for `factory-backup` / `factory-config-diff` (for example `.cto-backups/<task-id>/openclaw.json.before`).
