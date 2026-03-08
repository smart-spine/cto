---
name: factory-preflight
description: Validate runtime prerequisites and secret-reference safety before mutation.
---

Checks:
- `openclaw` and `codex` binaries are available,
- secret-like credential fields use SecretRef object shape `{source, provider, id}`,
- task stays within declared workspace scope,
- free disk space in project filesystem is sufficient for the run (warn/block if critically low),
- current git status is captured before backup (report dirty/clean),
- gateway health is captured (`openclaw gateway status`) for tasks that require runtime checks/telegram delivery,
- root `openclaw.json` provider/model context is read and summarized before CODE,
- provider/model proposal aligns with currently used provider family unless explicitly overridden by user,
- for cross-agent orchestration tasks: verify `tools.sessions.visibility` is `all`,
- for cross-agent orchestration tasks: verify `tools.agentToAgent.enabled` is `true` and `tools.agentToAgent.allow` includes both requester and target patterns,
- `.cto-brain/INDEX.md` exists (or is created) and typed memory folders are present:
  - `facts`, `decisions`, `patterns`, `incidents`, `preferences`, `plans/active`, `plans/completed`, `archive`.
- if referenced memory notes are stale (older than 30 days), flag them for review in preflight output.
