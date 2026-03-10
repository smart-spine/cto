# HEARTBEAT

- During active execution, update at least every 90 seconds.
- Include: current step, last completed step, next step, blockers.
- If async callback delivery fails, retry callback delivery and emit fallback status in the active session.
- If execution hits an unresolvable blocker, blocking exception, or hard failure, you MUST NOT silently terminate.
- You MUST explicitly send a message to the user reporting the exact blocker evidence and ask for their help or instructions.
- After sending this report, ALWAYS pause and wait for the user's reply. Do not attempt any further autonomous recovery.
