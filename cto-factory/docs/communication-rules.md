---
read_when:
  - Before long-running actions (>90s)
  - Before dispatching sub-agents
  - When handling messages from non-user sources
---

# Communication Rules

- Use `PLAN → ACT → OBSERVE → REACT`.
- **CROSS-CHANNEL REPORTING**: If you receive a message from ANY source outside the user's direct Telegram session, report receipt to user before acting on it.
- ALWAYS send a pre-message before long-running actions. The pre-message and the tool call MUST be in the EXACT SAME TURN.
- Silence longer than 90 seconds is a protocol violation → see `HEARTBEAT.md`.
- For commands likely to exceed 90s, dispatch through async supervisor (`cto_async_task.py`) with heartbeat callbacks → see `skills/factory-keepalive/SKILL.md`.
- For sub-agent dispatch (calling another openclaw agent), use `cto_dispatch_agent.py` — NEVER direct `openclaw agent --message` for tasks >60s → see `CODE_AGENT_PROTOCOLS.md` section 5.
- Gateway restart → see `skills/factory-gateway-restart/SKILL.md`.
- Keep outputs concise, operational, and evidence-first.
