---
name: factory-codex-plan-audit
description: Enforce Codex plan/report coverage against intake requirements before READY.
---

Use this skill for non-trivial Codex tasks:
- new agent creation,
- multi-file behavior changes,
- interactive UX changes,
- tasks with 3+ explicit requirements.

## GOAL
Prevent requirement drift by enforcing a strict Codex cycle:
- PLAN -> IMPLEMENT -> AUDIT -> (REWORK if needed).

## REQUIRED INPUTS
- deterministic requirement checklist file (`R1`, `R2`, ...),
- Codex plan output text,
- Codex implementation output text.

## REQUIRED TOOLING
- `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode plan --requirements-file <req.json> --codex-output-file <plan.txt>`
- `python3 ${OPENCLAW_ROOT}/workspace-factory/scripts/cto_codex_output_gate.py --mode report --requirements-file <req.json> --codex-output-file <report.txt>`

## RULES
1. PLAN gate MUST pass before implementation starts.
2. EXEC report gate MUST pass before READY_FOR_APPLY.
3. If either gate fails:
   - produce concrete missing requirement ids,
   - send rework prompt to Codex,
   - rerun gate until pass or explicit BLOCKED.
4. NEVER accept narrative-only Codex output for non-trivial tasks.
   - machine-checkable JSON markers are mandatory.

## MINIMUM ACCEPTANCE
- every requirement id from intake appears in Codex plan,
- every requirement id appears as `done` in Codex execution report,
- tests listed in execution report include exit codes,
- no unresolved mandatory gaps remain.

## OUTPUT
- plan gate command + exit code,
- report gate command + exit code,
- missing requirement ids (if any),
- rework iterations count,
- final gate status (`PASS` / `FAIL`).
