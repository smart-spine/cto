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
- **upsert `<agent_workspace>/SKILL_ROUTING.md`** — agent-scoped routing matrix (see Upsert Protocol below),
- ensure each generated skill has valid frontmatter:
  - `name`
  - `description`
- ensure routing matrix maps each intent to one primary skill.
- ensure `SKILL_INDEX.md` contains an explicit anti-overlap rule that forbids multiple primary skills for the same intent.

## SKILL_ROUTING.md — Upsert Protocol (mandatory after every skill create/update/delete)

**UPSERT, never overwrite blindly:**
- If `SKILL_ROUTING.md` does NOT exist → create it from the template below.
- If `SKILL_ROUTING.md` already exists → patch it:
  - ADD rows for new skills (one row per new intent),
  - REMOVE rows whose skill file no longer exists (orphan rows),
  - UPDATE rows for modified skills if trigger phrases or intent changed,
  - PRESERVE all existing rows that remain valid.

Required format:

```markdown
# Skill Routing Matrix

## Routing Table

| Intent | Primary skill | Trigger phrases | Do not use |
|---|---|---|---|
| <user intent> | `<skill-name>` | "<phrase1>", "<phrase2>" | <conflicting approach> |

## Skill Selection Rules

1. <agent-specific rule per skill>
2. Never invoke two primary skills for the same intent simultaneously.
3. If intent is ambiguous, prefer the skill with the more specific trigger match.

## Evidence Requirements

Each invocation must confirm which skill handled the request and why.
```

Rules for the routing table:
- one row per distinct user intent,
- `Trigger phrases` must be realistic user messages (2–3 examples per intent),
- `Do not use` must name the anti-pattern or conflicting skill — never leave blank.

After upserting `SKILL_ROUTING.md`, verify the agent's `README.md` or `AGENTS.md` has a Skills section:
```markdown
## Skills

Skill routing rules and intent-to-skill mapping: [SKILL_ROUTING.md](SKILL_ROUTING.md)
Full skill inventory: [skills/SKILL_INDEX.md](skills/SKILL_INDEX.md)
```
If the section is missing or stale, update it.

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

4a. **Full Skill Coverage Gate (mandatory — run after EVERY skill create/update/delete)**:

   This gate checks ALL skills in the workspace, not just the ones modified in this run.
   A skill can silently fall out of routing when a new skill is added around it.

   Step-by-step:

   i. **Enumerate** all skill files:
      `ls <agent_workspace>/skills/*/SKILL.md`
      Build a list: `ALL_SKILLS = [skill-name-1, skill-name-2, ...]`

   ii. **Check SKILL_ROUTING.md coverage** — for each skill in `ALL_SKILLS`:
      - verify a row exists in the Routing Table with `Primary skill = skill-name`,
      - if any skill is missing → add its row now (do not skip, do not defer).

   iii. **Check for orphan rows** — for each row in `SKILL_ROUTING.md`:
      - verify the referenced skill file exists at `skills/<skill-name>/SKILL.md`,
      - if the file is gone → remove the row.

   iv. **Check SKILL_INDEX.md coverage** — for each skill in `ALL_SKILLS`:
      - verify an entry exists with `path`, `triggers`, and `description` fields,
      - if any skill is missing or incomplete → add/fix the entry.

   v. **Check PROMPTS.md coverage** — verify the routing section mentions ALL skills by name:
      - if any skill is absent → add it to the routing section with its intent.

   vi. **Check README/AGENTS.md Skills section** — verify it lists ALL skills:
      - if any skill is absent → update the section.

   vii. **Contradiction scan across ALL skills**:
      - no two rows in `SKILL_ROUTING.md` may assign the same intent to different primary skills,
      - no skill's `SKILL.md` may instruct behaviour that contradicts another skill's `SKILL.md`,
      - if contradictions found → resolve before proceeding (update routing or skill instructions).

   Gate result: PASS only when all seven checks are green for ALL skills.
   If any check fails → fix immediately, then re-run the gate from step i.

4b. **Coherence Review — all agent files (mandatory, max 3 iterations)**:
   After any skill create/update, read ALL agent profile files together and apply
   the full Coherence Review checklist from `AGENTS.md`.
   Do NOT proceed to step 5 until review passes or residual issues are reported.

5. **Skill documentation (mandatory — hard gate)**:
   For each skill created or modified, the following MUST be present:

   a. `SKILL_INDEX.md` entry MUST contain:
      - `path: skills/<skill-name>/SKILL.md` — exact relative path,
      - `triggers:` — at least 2–3 realistic user phrases or commands,
      - `description:` — one-line summary.

   b. Agent's `PROMPTS.md` MUST contain an explicit skill routing section that:
      - names each available skill,
      - states the intent it handles ("when the user asks X → use skill Y"),
      - references the skill by name and path.

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
- include Full Skill Coverage Gate result (pass/fail per check),
- include any resolved contradictions.
