---
name: factory-report
description: Produce human-readable progress reports with machine-checkable evidence.
---

Output format:
- Section 1: short operator summary
  - current status,
  - next action,
  - top risks / blockers,
  - highest-signal evidence only.
- Section 2: structured evidence appendix
  - skill routing and phase evidence,
  - validation/test commands and exit codes,
  - apply/restart/rollback metadata,
  - memory / keepalive / approval state details when relevant.

Always include in the evidence appendix:
- `SKILL_ROUTING`: selected primary/secondary skills and why,
- `PLAN`: what is being done next and why,
- `OBSERVE`: what the tool/test returned and whether it is valid,
- `REACT`: next step or remediation,
- final status (`DONE`, `BLOCKED`, `ROLLED_BACK`),
- Codex delegation evidence (guarded Codex command + exit code),
- cross-agent runtime-test evidence (only when used): `sessions_*` call id(s) and target agent id,
- key evidence from tests/config QA,
- for new-agent tasks: artifact gate evidence from
  - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_agent_artifact_gate.py" ...`,
  - include command, exit code, and pass/fail summary lines,
  - include skill package gate evidence from:
    - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_skill_consistency_gate.py" ...`,
- include command, exit code, and pass/fail summary lines,
- for interactive Telegram agents (buttons/menus):
  - include interactive gate evidence from:
    - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_interactive_agent_gate.py" --workspace <agent_workspace> --menu-command /menu --callback-namespace <namespace>`
  - include command, exit code, and missing-runtime/missing-test findings if failed,
- for non-trivial Codex tasks: codex plan/report gate evidence from
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode plan ...`,
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode report ...`,
  - include missing requirement ids (if any) and rework iteration count,
- codex delegation evidence gate from
  - `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_delegation_gate.py --workspace <target_workspace> --evidence-file ${OPENCLAW_ROOT}/workspace-factory/tmp/codex-last-run.json`,
  - include command, exit code, and failure reason when blocked.
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
- user-usage handoff evidence for applyable changes:
  - target agent id and binding target,
  - first user action after apply,
  - commands/buttons quick sheet included,
  - expected callback text + timing window,
  - fallback diagnostic command included when callback may be delayed.
- keep-alive evidence when applicable:
  - pre-task duration warning sent,
  - async task id (if dispatched),
  - status polling output (`running/completed/failed`).

Never return raw tool output without explanatory wrapper text.
Keep the operator summary compact and high-signal; keep the appendix structured and machine-checkable.
