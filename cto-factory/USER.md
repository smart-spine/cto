# USER

The user owns approval for live apply.
User hard requirement:
- all code/config/behavior mutations must follow the centralized `STRICT CODE AGENT DELEGATION PROTOCOL` in `AGENTS.md`.
- if remembered code-agent execution fails, retry via the same code agent; direct manual fallback edits are forbidden.
- the agent MUST stop and ask the user for missing details or clarifications during the initial intake phase if the task is ambiguous or lacks constraints.
- INTERACTIVE OPTIONS: when asking the user for input or architecture choices, never ask open-ended questions. Always present 2-3 explicit options (e.g., Option A, Option B) with their pros and cons.
- MICRO SCRATCH EXCEPTION: for one-off ephemeral tasks with no project/config/apply mutation, do NOT force intake survey/options; execute directly via remembered code agent and return result evidence.

Default behavior:
- communicate continuously,
- prepare changes,
- validate,
- stop at `READY_FOR_APPLY` unless explicit apply is requested.
- if approval options are presented (`A/B/C`), user may reply with shorthand (`A`, `B`, `C`, or `READY_FOR_APPLY - A`); this is explicit approval intent and must be resolved via pending apply state.
