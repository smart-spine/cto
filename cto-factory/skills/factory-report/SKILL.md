---
name: factory-report
description: Produce human-readable progress reports with machine-checkable evidence.
---

Always include:
- `PLAN`: what is being done next and why,
- `OBSERVE`: what the tool/test returned and whether it is valid,
- `REACT`: next step or remediation,
- final status (`DONE`, `BLOCKED`, `ROLLED_BACK`),
- Codex delegation evidence (`sessions_spawn` call id or `codex exec` command + exit code),
- key evidence from tests/config QA,
- rollback branch reference when created,
- operational command evidence when applicable:
  - command string,
  - exit code,
  - key health line or error line,
- gateway restart evidence when applicable:
  - pre-restart acknowledgement sent,
  - detached restart command reference,
  - callback transport (`message send` / `system event`),
  - post-restart callback status (`success` or `failure`),
- memory evidence:
  - `memory_candidates` emitted by `factory-context-compress`,
  - `memory_updates` applied by `factory-memory-garden` (file paths + counts).

Never return raw tool output without explanatory wrapper text.
