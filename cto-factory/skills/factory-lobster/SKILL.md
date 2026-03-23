---
name: factory-lobster
description: Design, create, and invoke Lobster workflow files. Use when a task or new agent has a clear deterministic chain of ≥3 ordered steps.
---

## Decision rule: Lobster or not?

Use Lobster when:
1. **≥3 ordered steps** — skipping or reordering any step would be wrong
2. **Hard prerequisites** — step N requires step N-1 to succeed
3. **Deterministic shell operations** — not free-form LLM reasoning

**Always Lobster**: backup→code→test→apply, cron operations, gateway restart, fetch→process→deliver agents
**Never Lobster**: intake conversation, requirements signoff, research synthesis, smoke evaluation

→ Full decision guide in `docs/lobster-guide.md`

## Invoking existing CTO workflows

Pre-built pipelines in `workspace-factory/lobster/`:

**After user YES on REQUIREMENTS_SIGNOFF + code-agent done:**
```json
{
  "action": "run",
  "pipeline": "<OPENCLAW_ROOT>/workspace-factory/lobster/create-agent-execute.lobster",
  "argsJson": "{\"agent_id\":\"<id>\",\"openclaw_root\":\"<root>\",\"apply_summary\":\"<what will be applied>\"}",
  "timeoutMs": 300000
}
```

**For cron changes:**
```json
{
  "action": "run",
  "pipeline": "<OPENCLAW_ROOT>/workspace-factory/lobster/cron-manage.lobster",
  "argsJson": "{\"openclaw_root\":\"<root>\",\"agent_id\":\"<id>\",\"action\":\"add\",\"cron_cmd\":\"cron add ...\",\"description\":\"<what>\"}",
  "timeoutMs": 60000
}
```

**For gateway restart:**
```json
{
  "action": "run",
  "pipeline": "<OPENCLAW_ROOT>/workspace-factory/lobster/gateway-restart.lobster",
  "argsJson": "{\"openclaw_root\":\"<root>\",\"callback_session\":\"<session_id>\"}",
  "timeoutMs": 120000
}
```

**Resume after approval gate:**
```json
{
  "action": "resume",
  "token": "<resumeToken from needs_approval>",
  "approve": true
}
```

## Building a Lobster workflow for a new agent

When a new agent has a repeatable deterministic flow:

### Step 1 — Identify the skeleton

List the agent's operations that are:
- Always run in the same order
- Each one required for the next to make sense
- Shell commands or CLI calls

Example (Reddit daily summary):
```
fetch posts (reddit API) → filter 24h → summarize (LLM) → approve → send Telegram
```

### Step 2 — Create the .lobster file

Place in `workspace-<agent_id>/lobster/<workflow_name>.lobster`:

```yaml
name: daily-summary
args:
  subreddits:
    default: "r/openclaw"
  telegram_target:
    default: ""
steps:
  - id: fetch
    command: node tools/reddit-fetch.js --subreddits "$LOBSTER_ARG_SUBREDDITS" --hours 24 --json

  - id: summarize
    command: >
      openclaw.invoke --tool llm-task --action json --args-json '{
        "prompt": "Summarize the top pain points from these posts. Group by theme. Max 5 themes.",
        "schema": {"type":"object","properties":{"themes":{"type":"array","items":{"type":"string"}}}}
      }'
    stdin: $fetch.json

  - id: approve
    command: bash -c 'echo "{\"preview\":\"ready to send summary\"}"'
    approval: required

  - id: send
    command: >
      openclaw message send --channel telegram --target "$LOBSTER_ARG_TELEGRAM_TARGET"
        --message "$(echo $LOBSTER_ARG_SUMMARY)"
    stdin: $summarize.json
    condition: $approve.approved
```

### Step 3 — Enable in the agent's openclaw.json entry

```json
{
  "agents": {
    "list": [{
      "id": "<agent_id>",
      "tools": { "alsoAllow": ["lobster"] }
    }]
  }
}
```

### Step 4 — Document invocation

In `workspace-<agent_id>/PROMPTS.md`, add:
```markdown
## Lobster workflows

| Workflow | File | Trigger |
|---|---|---|
| daily-summary | lobster/daily-summary.lobster | scheduled run or /run-now |
```

In `workspace-<agent_id>/SKILL_ROUTING.md`, add a row for the Lobster flow.

### Step 5 — Smoke test

Run the .lobster file with a dry-run or test dataset before READY_FOR_APPLY:
```json
{
  "action": "run",
  "pipeline": "<OPENCLAW_ROOT>/workspace-<agent_id>/lobster/daily-summary.lobster",
  "argsJson": "{\"subreddits\":\"r/test\",\"telegram_target\":\"...\"}",
  "timeoutMs": 60000
}
```

Verify the output envelope returns `ok` or `needs_approval` (not `cancelled` or error).

## Hard rules

- Lobster MUST be enabled in `openclaw.json` before invoking any lobster workflow.
- NEVER manually sequence steps that should be in a Lobster pipeline — LLM "willpower" is not reliable for step ordering.
- The approval gate inside the .lobster file IS the READY_FOR_APPLY gate — do NOT present a separate manual approval when Lobster handles it.
- If lobster returns `lobster failed (code 127)`: the binary is not installed. Run `sudo npm install -g github:openclaw/lobster` on the gateway host.
