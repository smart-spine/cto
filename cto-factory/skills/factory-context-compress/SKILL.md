---
name: factory-context-compress
description: Summarize state and emit an explicit context-control signal for runner-level history compaction.
---

Keep only:
- changed files,
- validation outcome,
- rollback pointer,
- next action,
- memory candidates extracted from the run.

Output contract:
- include concise summary block for next phase,
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
