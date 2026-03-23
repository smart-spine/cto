---
read_when:
  - Before writing to .cto-brain/
  - At DONE or ROLLBACK state
  - When context is approaching its limit
---

# Memory Protocol

CTO MUST write to `.cto-brain/` proactively during work — not only at session end.

## Write triggers (immediate — do not wait for session end)

| Event | Memory type | When |
|---|---|---|
| User corrects CTO's approach, style, or output | `preference` | Immediately after the correction |
| User states a preference or constraint | `preference` | On the same turn |
| User mentions their tech level, stack, or role | `preference` | On the same turn |
| CTO finds a workaround that resolves a blocker | `workaround` | Immediately after it's verified to work |
| A key architectural or product decision is made | `decision` | When user approves or confirms it |
| A recurring error pattern is diagnosed | `pattern` | After second occurrence or explicit diagnosis |
| An incident occurs (gateway down, failed deploy, etc.) | `incident` | After the incident is resolved |

## How to write

Write the note file directly to `.cto-brain/<type>/YYYY-MM-DD--<slug>.md`, then update `INDEX.md`.

Use `exec` directly — memory writes are exempt from code-agent delegation (they are operational state, not project mutations).

**The memory-write exemption is NARROW — it covers ONLY `.cto-brain/` writes.**

The following are NOT exempt and ALWAYS require code-agent delegation:
- `openclaw.json` (any field — gateway, auth, channels, agents, bindings, cron, etc.)
- Telegram channel/account settings: `dmPolicy`, `allowFrom`, `groupAllowFrom`, `groupPolicy`, `botToken`, peer bindings
- Any `workspace-*` file other than `.cto-brain/` memory entries
- Any systemd drop-in or service file

## Session end / context compress

At **DONE** or **ROLLBACK** state, and whenever context approaches its limit:

1. **FIRST — scan and write memories BEFORE sending any reply to the user.**
   - Scan the session for write-trigger events (see table above).
   - For each candidate: write `.cto-brain/<type>/YYYY-MM-DD--<slug>.md` and append to `INDEX.md`.
   - Use `exec` for these writes.
2. Only after step 1 is confirmed: emit session summary / `factory-context-compress` to user.

**Protocol violation**: sending a DONE or session summary without completing step 1 first.
**Protocol violation**: sending "I'll write memories after" — the write MUST happen before the reply.

The goal: every session leaves the memory garden richer than it found it.
