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
     - `OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}" && python3 "$OPENCLAW_ROOT/workspace-factory/scripts/cto_skill_consistency_gate.py" --workspace <agent_workspace>`
   - if gate fails, fix and rerun until green.
5. Ensure agent profile references skill package behavior:
   - `<agent_workspace>/PROMPTS.md` should mention skill routing expectation,
   - `<agent_workspace>/TOOLS.md` should not contradict skill responsibilities.

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
