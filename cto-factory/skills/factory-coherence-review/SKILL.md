---
name: factory-coherence-review
description: Review all agent profile files as a complete system, find and fix contradictions, dead references, duplicates, bloated content, and scope violations. Max 3 iterations.
---

Purpose:
- catch issues that arise from writing files in isolation,
- ensure no single file contradicts or silently overwrites guidance in another,
- produce a clean, non-redundant agent profile set before apply.

When to use:
- **PRE-APPLY gate only** — run ONCE after all CODE changes for the task are complete,
  immediately before `READY_FOR_APPLY`. Do NOT run after each individual file edit
  mid-CODE; the agent profile set is incomplete at that point.
- as a standalone audit requested by the user,
- never skip when `factory-create-agent` or `factory-skill-creator` ran.

Applies when any of the following were created or modified during the task:
`IDENTITY.md`, `TOOLS.md`, `PROMPTS.md`, `AGENTS.md`, `README.md`,
`SKILL_ROUTING.md`, `SKILL_INDEX.md`, `skills/*/SKILL.md`.

Input:
- `agent_workspace` — absolute path to the target agent workspace.

## Procedure (max 3 iterations)

For each iteration:

**Step 1 — Read everything at once.**
Read ALL profile files in `<agent_workspace>/` together as a complete set.
Do NOT review files one by one — the goal is to see the full picture.
Files to read: `IDENTITY.md`, `TOOLS.md`, `PROMPTS.md`, `AGENTS.md` or `README.md`,
`SKILL_ROUTING.md`, `SKILL_INDEX.md`, every `skills/*/SKILL.md`.

**Step 2 — Check for the following issue types:**

| # | Type | What to look for |
|---|---|---|
| C | **Contradiction** | Rule in file A directly conflicts with rule in file B (e.g. TOOLS.md allows X, a SKILL.md forbids X) |
| D | **Dead reference** | Mentions a skill, tool, file, or command that does not exist in the workspace |
| R | **Duplicate rule** | Same instruction in 2+ places with diverging wording — one canonical location, remove the rest |
| B | **Bloated section** | Content that adds no unique value beyond what another file already says |
| A | **Ambiguous directive** | An instruction with two valid interpretations — rewrite to be unambiguous |
| O | **Orphaned content** | A section that no longer connects to any file or runtime behaviour |
| S | **Scope violation** | A skill's SKILL.md claims an intent already owned as primary by another skill |

**Step 3 — Fix every issue found.**
- For each issue: state type (C/D/R/B/A/O/S), location (file + section), and fix applied.
- Do not defer fixes to the next iteration.

**Step 4 — Decide whether to iterate.**
- If zero issues found in this iteration → gate PASSES. Stop.
- If issues remain and iterations < 3 → go back to Step 1 with fresh eyes.
- After 3 iterations with remaining issues → report residual issues with justification
  and surface them to the user before returning READY.

## Output contract

Return a structured report:

```
## Coherence Review — <agent_id>

### Iteration 1
Issues found: N
- [C] TOOLS.md vs skills/fetch/SKILL.md — conflicting tool permission. Fix: ...
- [D] PROMPTS.md line 12 — references skill "monitor" which does not exist. Fix: ...

### Iteration 2
Issues found: M
- ...

### Final state: CLEAN
```

or if residual:

```
### Final state: RESIDUAL ISSUES
- [type] description — reason not fixed: ...
```

Self-reported "CLEAN" without having read all files is a protocol violation.
The report MUST list which files were read in iteration 1.
