---
name: factory-smoke
description: Run pre-apply functional smoke (prove behavior before live mutation) and post-apply sanity checks (confirm operational artifacts after apply).
---

Smoke checks should be quick and deterministic.

## PRE-APPLY FUNCTIONAL SMOKE
- Run before `READY_FOR_APPLY`.
- Goal: prove the requested behavior works before any live mutation.
- Failure handling:
  - if the implementation is wrong or incomplete, return `RETURN_TO_CODE`,
  - if runtime/channel prerequisites are missing, return `BLOCKED` with the exact prerequisite,
  - do NOT recommend rollback for work that has not been applied yet.

## POST-APPLY SMOKE
- Run only after live apply.
- Goal: prove the live runtime, delivery path, and health still work after mutation.
- Failure handling:
  - if a live regression or partial apply is detected, mark `POST_APPLY_SMOKE_FAILED` and recommend `ROLLBACK`,
  - if rollback is not appropriate, report the exact remediation path and blast radius.

Minimum required checks:
1. If a new agent workspace was created, verify the directory exists and contains at least `AGENTS.md` or `README.md`.
2. If `openclaw.json` was modified, run `openclaw config validate --json` one final time and confirm `valid: true`.
3. If the agent has a cron schedule, verify it is listed via `openclaw cron list --agent <agent-id> --json`.
4. If any tools (`.js`/`.ts`) were created or modified, run `node --check <file>` to confirm no syntax errors.
5. Report each check with PASS/FAIL status.

For newly created/modified agents (mandatory):
6. Run a **full diagnostic smoke** against the target agent. This is a real session — NOT a synthetic check:

   **Step 6a — Diagnostic message** (send to the agent and inspect response):
   ```
   timeout 90 openclaw agent --agent <id> \
     --message "/diagnose: list all your tools, confirm skills are loaded, confirm delivery channel is reachable, report any errors" \
     --json 2>&1
   ```
   PASS criteria for diagnostic response:
   - Response mentions at least one tool by name (proves tools are loaded)
   - Response mentions at least one skill by name (proves skill routing works)
   - Response includes delivery channel status (proves transport is wired)
   - No "I don't understand" or empty response (proves agent is alive and routing)

   **Step 6b — Skill-targeted invocation** (send a request that triggers the agent's PRIMARY skill):
   - Use the skill's documented trigger phrase from `SKILL_INDEX.md`
   - Verify response demonstrates the skill's intended behavior (not generic fallback)
   - If agent is not yet registered (new agent pending apply): mark as `BLOCKED: REQUIRES_APPLY_FIRST`

   **Step 6c — Tool output verification**:
   - If the agent uses external tools (Reddit, web, DB, file system): send a request that exercises them
   - Verify the tool output appears in the response (actual data, not "I'll fetch that later")
   - If tool requires credentials and they are missing: return `BLOCKED: MISSING_SECRET`

   Self-reported "smoke passed" without command evidence and real response content is a protocol violation.

## Skill Invocation Testing (mandatory when any skill was created or modified)

When any `skills/<name>/SKILL.md` or skill tool file was created or modified:

6a. For each new or modified skill, run a **skill-targeted invocation test**:
   - Identify the skill's trigger: the realistic user phrase or command that routes to this skill according to `SKILL_INDEX.md` or the skill's own description.
   - Send a message specifically crafted to invoke this skill (not a generic greeting or unrelated request):
     - Short-running agent (expected <30s):
       `timeout 60 openclaw agent --agent <id> --message "<skill trigger phrase>" --json`
     - Long-running agent or LLM-backed skill (expected >30s):
       `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_dispatch_agent.py" --agent <id> --message "<skill trigger phrase>"`
   - Verify skill execution evidence in the response:
     - response demonstrates the skill's intended behavior (report structure, expected output fields, side-effect confirmation),
     - response is NOT a generic "I don't understand" or fallback — this counts as a routing failure,
     - if the skill produces a file, API call, or delivery, verify that effect in the filesystem or channel log.
   - PASS criteria: the response unambiguously shows the skill ran (content matches skill purpose).
   - FAIL criteria: generic response, wrong skill routing, empty output, or missing side-effect → `RETURN_TO_CODE` with exact mismatch.
   - If the agent is not yet registered (new agent pending apply): mark this check as `BLOCKED: REQUIRES_APPLY_FIRST` and add it as a mandatory post-apply smoke step.

6b. If the task modified skill routing (`SKILL_INDEX.md` or `SKILL_ROUTING.md`), run one invocation test per modified routing path to confirm correct dispatch.

7. For delivery agents, verify delivery-path evidence (for example `sent=true`, no fallback) when runtime/channel is available.
7a. If intake explicitly requested `buttons` or `buttons + commands`, smoke MUST verify inline-button delivery evidence in the target chat/topic:
   - one message-tool send (or agent-generated send) includes inline keyboard payload,
   - provider response confirms send success (`sent=true` or equivalent message id evidence),
   - text-only fallback menu does NOT satisfy this requirement.
   - `/menu` MUST be used as the primary smoke trigger for interactive menu validation.
7b. For interactive button agents, smoke MUST run runtime UX gate:
   - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_interactive_agent_gate.py" --workspace "$OPENCLAW_ROOT/workspace-<agent_id>" --menu-command /menu --callback-namespace <namespace>`
   - treat non-zero exit as hard smoke failure.
8. If runtime/channel prerequisites are missing, report `BLOCKED` with exact prerequisite and do not claim `READY_FOR_APPLY`.
9. Scope boundary:
   - `factory-smoke` is fast and task-focused.
   - for broad behavioral regression/comparative checks, hand off to `factory-test-agent`.

If any pre-apply smoke check fails, block `READY_FOR_APPLY` and route to `RETURN_TO_CODE` or `BLOCKED`.
If any post-apply smoke check fails, block `DONE` and route to `ROLLBACK` or an explicitly documented live remediation path.
