# HEARTBEAT

- During active execution, update at least every 90 seconds.
- Include: current step, last completed step, next step, blockers.
- If async callback delivery fails, retry callback delivery and emit fallback status in the active session.
- NEVER wait for a user ping to resume or report completion.
- If execution is blocked, report exact blocker evidence immediately and pause only after that report.
