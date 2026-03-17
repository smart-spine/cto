---
name: factory-skill-creator
description: Create and validate high-quality skill packages for newly created or existing agents with contradiction checks.
---

Purpose:
- ensure generated agents are shipped with usable skills, not only runtime files,
- enforce deterministic skill routing per agent,
- prevent contradictory skill guidance.

When to use:
- any "create/build new agent" task (mandatory with `factory-create-agent`),
- any request to add/update skills for an existing agent,
- any request to standardize how an agent should choose skills.

Output contract:
- create/update `<agent_workspace>/skills/`,
- create/update `<agent_workspace>/skills/SKILL_INDEX.md`,
- create/update at least one concrete skill folder:
  - `<agent_workspace>/skills/<skill-name>/SKILL.md`
- ensure each generated skill has valid frontmatter:
  - `name`
  - `description`
- ensure routing matrix maps each intent to one primary skill.
- ensure `SKILL_INDEX.md` contains an explicit anti-overlap rule that forbids multiple primary skills for the same intent.

Procedure:
1. Gather skill-use cases from current agent scope:
   - build flows,
   - runtime ops,
   - testing/qa,
   - delivery/reporting.
2. Define minimal skill topology:
   - avoid overlapping primary responsibilities,
   - add fallback/secondary skills where needed.
3. Generate skill package artifacts through Codex delegation (manager mode rules apply):
   - include exact line: `Write Unit Tests & Verify`.
4. Validate consistency:
   - run deterministic gate:
     - `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_skill_consistency_gate.py" --workspace <agent_workspace>`
   - if gate fails, fix and rerun until green.
5. **Skill documentation (mandatory — hard gate, not a suggestion)**:
   For each skill created or modified, the following MUST be present before proceeding:

   a. `SKILL_INDEX.md` entry for this skill MUST contain:
      - `path: skills/<skill-name>/SKILL.md` — exact relative path,
      - `triggers:` — at least 2–3 realistic user phrases or commands that route to this skill,
      - `description:` — one-line summary of what the skill does.

   b. Agent's `PROMPTS.md` MUST contain an explicit skill routing section that:
      - names each available skill,
      - states the intent it handles ("when the user asks X → use skill Y"),
      - references the skill by name and path, not by general guidance.

   c. Agent's `AGENTS.md` or `README.md` MUST include a "Skills" section listing:
      - each skill name, its path, and a one-sentence usage description,
      - the trigger command or phrase a user would send to invoke it.

   If any of (a), (b), or (c) is missing or incomplete: add the missing content immediately.
   Do NOT proceed to step 6 until this check is green.

6. **Skill invocation test (mandatory — do not skip)**:
   For each skill created or modified in this run:
   - Identify the trigger phrase from `SKILL_INDEX.md` or the skill's own description.
   - Send it to the target agent to confirm the skill actually executes:
     - Short-running / tool-based skill:
       `timeout 60 openclaw agent --agent <id> --message "<trigger phrase>" --json`
     - LLM-backed or long-running skill:
       `python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_dispatch_agent.py" --agent <id> --message "<trigger phrase>"`
   - PASS: the response demonstrates the skill's intended behavior — not a generic fallback or "I don't understand".
   - FAIL: return to step 3 (Codex delegation), fix the skill implementation, and retest before proceeding.
   - If the agent is not yet registered in `openclaw.json` (new agent pending apply):
     mark as `BLOCKED: REQUIRES_APPLY_FIRST` and flag this test as a mandatory post-apply check in the handoff packet.

Contradiction rules:
- one intent must not map to multiple different primary skills,
- skill instructions must not claim unavailable tools,
- do not mix mutually exclusive directives such as:
  - "always use skill X for intent Y"
  - "always use skill Z for the same intent Y"

Reporting requirements:
- list created/updated skill files,
- include consistency gate command + exit code,
- include any resolved contradictions.
