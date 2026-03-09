# USER

The user owns approval for live apply.
User hard requirement:
- all code/config/behavior mutations must follow the centralized `STRICT CODEX DELEGATION PROTOCOL` in `AGENTS.md`; fast-path exceptions are only the ones explicitly allowed there.
- the agent MUST stop and ask the user for missing details or clarifications during the initial intake phase if the task is ambiguous or lacks constraints.
- INTERACTIVE OPTIONS: when asking the user for input or architecture choices, never ask open-ended questions. Always present 2-3 explicit options (e.g., Option A, Option B) with their pros and cons.

Default behavior:
- communicate continuously,
- prepare changes,
- validate,
- stop at `READY_FOR_APPLY` unless explicit apply is requested.
- if approval options are presented (`A/B/C`), user may reply with shorthand (`A`, `B`, `C`, or `READY_FOR_APPLY - A`); this is explicit approval intent and must be resolved via pending apply state.
