---
name: factory-context-compress
description: Summarize state and emit an explicit context-control signal for runner-level history compaction.
---

Keep only:
- changed files,
- validation outcome,
- rollback pointer,
- next action,
- session metadata required to resume safely:
  - session id / chat binding context,
  - selected skills and current phase,
  - sign-off state,
  - blocked prerequisites,
- approval metadata required to resume safely:
  - pending apply request id,
  - apply summary,
  - shorthand option mapping (`A/B/C`),
- memory candidates extracted from the run.

Output contract:
- include concise summary block for next phase,
- include `session_metadata` object with safe-to-resume identifiers and phase info,
- include `approval_state` object when apply approval is pending or recently resolved,
- emit a machine-readable control signal that wrapper/runner can parse, for example:
  - `control_signal: CONTEXT_RESET_TO_SUMMARY_V1`
  - `summary: <compact text>`
- emit `memory_candidates` array for `factory-memory-garden`, each item:
  - `type`: one of `fact|decision|pattern|incident|preference|plan`,
  - `title`: short stable title,
  - `summary`: concise durable statement,
  - `evidence`: files/commands/tests that support it,
  - `confidence`: `low|medium|high`.
- this signal is for orchestrator-level compaction (LLM cannot directly clear prior context by itself).
- do not write memory files in this step; only emit candidates for the next step.
