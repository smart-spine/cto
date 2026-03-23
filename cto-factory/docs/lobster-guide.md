---
read_when:
  - When deciding whether a new agent needs a .lobster workflow
  - When CTO needs to execute a deterministic multi-step sequence
  - When building or teaching agents with clear ordered chains
---

# Lobster Guide

Lobster is a **typed workflow runtime** bundled in OpenClaw. It runs multi-step shell pipelines as a single deterministic operation with approval gates and resumable state.

**Core principle**: LLMs do what LLMs are good at — planning, reasoning, summarizing. Lobster does what code is good at — sequencing, counting, routing, retrying. Don't trust LLM "willpower" to run 8 steps in the right order. Use Lobster.

## When to use Lobster (MANDATORY decision rule)

Use Lobster when ALL of the following are true:
1. There are **≥3 ordered steps** where skipping or reordering any step would be wrong
2. At least one step has a **hard prerequisite** on a prior step completing successfully
3. The steps are **deterministic shell operations** (not free-form LLM reasoning)

**Always Lobster:**
- backup → code → test → config_qa → apply
- cron: list → mutate → verify
- gateway: detect runtime → pre-check → restart → health-check
- reddit/RSS agent: fetch → parse → approve → deliver

**Never Lobster (LLM reasoning required):**
- INTAKE conversation
- REQUIREMENTS_SIGNOFF (user dialogue)
- RESEARCH (web fetching + synthesis)
- Smoke test evaluation (send message, interpret response)

## How CTO calls Lobster

Lobster is a tool call (enabled via `tools.alsoAllow: ["lobster"]`):

```json
// Run a .lobster workflow file
{
  "action": "run",
  "pipeline": "/path/to/workflow.lobster",
  "argsJson": "{\"agent_id\": \"reddit-agent\", \"openclaw_root\": \"/home/ubuntu/.openclaw\"}",
  "timeoutMs": 120000
}
```

```json
// Resume after an approval gate
{
  "action": "resume",
  "token": "<resumeToken from needs_approval response>",
  "approve": true
}
```

Output envelope:
- `status: "ok"` — completed
- `status: "needs_approval"` — paused at approval gate; read `requiresApproval.resumeToken`
- `status: "cancelled"` — rejected or timed out

## .lobster YAML syntax

```yaml
name: workflow-name
args:
  param_name:
    default: "optional-default"
steps:
  - id: step_id
    command: bash -c 'some-command --json'

  - id: next_step
    command: some-other-command
    stdin: $step_id.stdout        # pipe prior step's stdout as stdin

  - id: approval_gate
    command: bash -c 'echo "{\"summary\":\"Ready to apply\"}"'
    approval: required             # pauses here, returns needs_approval

  - id: final_step
    command: apply-something
    stdin: $approval_gate.stdout
    condition: $approval_gate.approved   # only runs if approved
```

**Step fields:**
| Field | Description |
|---|---|
| `id` | Step identifier — referenced as `$id.*` by later steps |
| `command` | Shell command to run (must exit 0 on success) |
| `stdin` | `$prior_id.stdout` or `$prior_id.json` |
| `approval: required` | Pause and emit `needs_approval` with `resumeToken` |
| `condition` / `when` | `$prior_id.approved` — gates execution on an approval result |

**Input args** are available as env vars: `$LOBSTER_ARG_PARAM_NAME` (uppercased).

**Step output references:**
- `$id.stdout` — raw text output
- `$id.json` — parsed JSON output
- `$id.approved` — boolean approval result

## Workflow files in this workspace

Pre-built pipelines in `workspace-factory/lobster/`:

| File | Purpose | Entry state |
|---|---|---|
| `create-agent-execute.lobster` | backup → test → config_qa → apply gate → apply → post-smoke | After user YES on REQUIREMENTS_SIGNOFF |
| `edit-agent-execute.lobster` | backup → test → config_qa → apply gate → apply | After user YES on REQUIREMENTS_SIGNOFF |
| `cron-manage.lobster` | list → mutate → verify | After cron change is planned |
| `gateway-restart.lobster` | detect-runtime → pre-check → restart → health-check | On restart request |

## Using Lobster in the CTO state machine

After user signs off on REQUIREMENTS_SIGNOFF and code-agent finishes coding, invoke Lobster for the deterministic execution phase:

```
REQUIREMENTS_SIGNOFF (user YES)
  → CODE (code-agent delegation, async)
  → CODE_DONE → call Lobster: create-agent-execute.lobster
      step: backup
      step: test
      step: config_qa
      step: apply_gate  ← Lobster pauses here (READY_FOR_APPLY)
      CTO: present apply options to user
      resume(approve=true)
      step: apply
      step: post_smoke
  → Lobster ok → MEMORY_WRITE → DONE
```

The approval gate inside the .lobster file IS the READY_FOR_APPLY checkpoint.

## Teaching new agents Lobster

When a new agent has a clear repeatable flow (e.g. fetch → process → approve → deliver), build it with Lobster:

1. Identify the deterministic steps (the "skeleton")
2. Create `workspace-<agent_id>/lobster/<workflow_name>.lobster`
3. Add approval gates where human review is required (e.g. before sending/posting)
4. Document invocation in the agent's `SKILL_ROUTING.md` and `PROMPTS.md`
5. Smoke test with a real Lobster run

**Enable for the agent in openclaw.json:**
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

## Enabling Lobster for cto-factory

In root `openclaw.json`, under the `cto-factory` agent entry:
```json
"tools": { "alsoAllow": ["lobster"] }
```

## Install note

The `lobster` binary must be on PATH on the gateway host.
Install from source: `sudo npm install -g github:openclaw/lobster`
Verify: `lobster --version`

If binary is missing, the plugin returns: `lobster failed (code 127)` — install it and retry.
