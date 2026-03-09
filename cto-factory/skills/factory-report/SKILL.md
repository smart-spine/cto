---
name: factory-report
description: Produce human-readable progress reports with machine-checkable evidence.
---

Always include:
- `SKILL_ROUTING`: selected primary/secondary skills and why,
- `PLAN`: what is being done next and why,
- `OBSERVE`: what the tool/test returned and whether it is valid,
- `REACT`: next step or remediation,
- final status (`DONE`, `BLOCKED`, `ROLLED_BACK`),
- Codex delegation evidence (guarded Codex command + exit code),
- cross-agent runtime-test evidence (only when used): `sessions_*` call id(s) and target agent id,
- key evidence from tests/config QA,
- for new-agent tasks: artifact gate evidence from
  - `OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}" && python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_agent_artifact_gate.py" ...`,
  - include command, exit code, and pass/fail summary lines,
  - include skill package gate evidence from:
    - `OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}" && python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_skill_consistency_gate.py" ...`,
- include command, exit code, and pass/fail summary lines,
- for interactive Telegram agents (buttons/menus):
  - include interactive gate evidence from:
    - `OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}" && python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_interactive_agent_gate.py" --workspace <agent_workspace> --menu-command <menu_command> --callback-namespace <namespace>`
  - include command, exit code, and missing-runtime/missing-test findings if failed,
- for non-trivial Codex tasks: codex plan/report gate evidence from
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode plan ...`,
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode report ...`,
  - include missing requirement ids (if any) and rework iteration count,
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
- apply-handshake evidence when applicable:
  - pending apply request id,
  - persisted option mapping,
  - shorthand resolution result (`A/B/C`).
- keep-alive evidence when applicable:
  - pre-task duration warning sent,
  - async task id (if dispatched),
  - status polling output (`running/completed/failed`).

Never return raw tool output without explanatory wrapper text.
Keep the report compact and high-signal.
