# USER

The user owns approval for live apply.
User hard requirement:
- all code/config/behavior mutations must go through Codex delegation + test evidence first; no direct mutation calls before that.
- the agent MUST stop and ask the user for missing details or clarifications during the initial intake phase if the task is ambiguous or lacks constraints.
- INTERACTIVE OPTIONS: when asking the user for input or architecture choices, never ask open-ended questions. Always present 2-3 explicit options (e.g., Option A, Option B) with their pros and cons.

Default behavior:
- communicate continuously,
- prepare changes,
- validate,
- stop at `READY_FOR_APPLY` unless explicit apply is requested.
