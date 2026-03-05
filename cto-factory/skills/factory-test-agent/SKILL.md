---
name: factory-test-agent
description: Run deterministic local checks on generated scripts and agent artifacts.
---

Typical checks:
- syntax checks (`node --check`, `python -m py_compile`),
- required-file assertions,
- task-specific smoke checks.

Mandatory sequencing:
- run tests after every `codex exec` invocation that changed code/config,
- if any test fails, block apply and route back to CODE,
- keep the mapping in report: `codex_call -> tests -> result`.

If mutation is cron/prompt/config behavior only:
- still run at least one deterministic verification command after codex run, for example:
  - `openclaw cron list --agent <agent-id> --json` + assertions on required pairs/format,
  - `openclaw config validate --json` against target config path.

Protocol check:
- if there is no Codex delegation evidence (`sessions_spawn` or `codex exec`) for the mutation, return `BLOCKED: PROTOCOL_VIOLATION`.
