---
name: factory-workspace-audit
description: >
  TWO-PART audit before REQUIREMENTS_SIGNOFF:
  (A) deep internal scan of the TARGET agent's files for contradictions, dead references,
  duplicate rules, and conflicting instructions;
  (B) cross-workspace scan of ALL other agents for duplicate skills and reuse opportunities.
  Both parts are mandatory. Structural check is NOT the goal — content quality is.
---

## When to run

MANDATORY before presenting REQUIREMENTS_SIGNOFF for any task that creates or modifies an agent workspace.

Skip only for: gateway restart, cron-only changes, config-value-only edits with no agent workspace change.

## Two-part audit

### PART A — Internal file quality audit (target workspace)

Read ALL profile files of the target agent and check for the following problem types:

**1. Contradicting instructions**
Examples:
- SOUL.md says "always confirm before sending", PROMPTS.md says "send immediately"
- IDENTITY.md describes the agent as read-only, but a skill modifies data
- Two SKILL.md files have different rules for the same trigger phrase

**2. Dead references**
Examples:
- A file references `tools/fetch-reddit.js` but the file doesn't exist
- PROMPTS.md mentions a skill `slug-utils` that has no corresponding SKILL.md
- SKILL_ROUTING.md points to `skills/nonexistent/SKILL.md`
- AGENTS.md links to `docs/architecture.md` which doesn't exist

**3. Duplicate rules**
Examples:
- The same rate-limit rule stated in IDENTITY.md AND SOUL.md with different values
- The same error handling policy duplicated in two different SKILL.md files
- Model name hardcoded in 3 places with inconsistent values

**4. Conflicting skill routing**
Examples:
- Two skills in SKILL_INDEX.md have identical or overlapping trigger phrases
- SKILL_ROUTING.md assigns the same intent to two different skills
- A skill is listed in SKILL_INDEX.md but not referenced in PROMPTS.md routing section

**5. Bloated or incoherent instructions**
Examples:
- AGENTS.md is >100 lines (violates Harness Engineering rule)
- A single SKILL.md contains unrelated responsibilities (violates single-concern rule)
- Instructions that reference outdated behavior or deleted features

**Files to read for Part A** (read all that exist):
- `IDENTITY.md`, `SOUL.md`, `PROMPTS.md`, `AGENTS.md` or `README.md`
- `SKILL_ROUTING.md`, `skills/SKILL_INDEX.md`
- Every `skills/<name>/SKILL.md`
- `tools/` directory listing + any `.md` files in tools/
- `config/` directory listing

### PART B — Cross-workspace deduplication

```bash
ls "$OPENCLAW_ROOT"/workspace-*/   # all workspaces except workspace-factory
```

For each other workspace (not the target, not workspace-factory):
- Read `IDENTITY.md` — what does this agent do?
- Read `skills/SKILL_INDEX.md` — what skills and triggers does it have?
- List `tools/` — what scripts does it use?

Then check:
- Does any other agent already have a skill that covers what we're about to build?
- Does any other agent's tool script do the same thing we'd write from scratch?
- Are there binding conflicts? (two agents bound to the same Telegram channel/topic)
- Are there cron conflicts? (same schedule + same target)

## Audit report format

Include this block verbatim in the REQUIREMENTS_SIGNOFF packet:

```
## Workspace Audit

### PART A — Internal file audit: workspace-<agent_id>
Files read: <list>

Internal issues found:
- [CONTRADICTION] <file A> says X, <file B> says Y — must resolve before CODE
- [DEAD_REF] <file> references <path> which does not exist
- [DUPLICATE_RULE] <rule> appears in <file1> and <file2> with different values
- [ROUTING_CONFLICT] skills <A> and <B> share trigger phrase "<phrase>"
- [BLOAT] <file> is <N> lines, exceeds limit / contains mixed concerns
- CLEAN — no internal issues found

### PART B — Cross-workspace scan
Agents scanned: workspace-<name> (<mission>), ...

Cross-workspace issues found:
- [DUPLICATE_SKILL] workspace-<other> skill <name> covers the same intent as our planned <skill>
- [REUSE] workspace-<other>/tools/<script> can replace our planned implementation of <X>
- [BINDING_CONFLICT] workspace-<other> is also bound to <channel/topic>
- CLEAN — no cross-workspace issues found
```

A sign-off presented without this block is incomplete and invalid.

## What to do with findings

| Finding | Action |
|---|---|
| CONTRADICTION | Resolve in architecture plan before YES is requested. Show which file wins. |
| DEAD_REF | List missing files as T1 in the implementation plan (create them first). |
| DUPLICATE_RULE | Pick one canonical location, remove the duplicate in the same CODE pass. |
| ROUTING_CONFLICT | Redesign trigger phrases so they don't overlap. Update SKILL_INDEX.md. |
| BLOAT | Restructure into docs/ in the same CODE pass. |
| DUPLICATE_SKILL | Propose reuse in sign-off. Don't rebuild without explicit user justification. |
| REUSE | Reference the existing tool; don't copy it. |
| BINDING_CONFLICT | Block CODE until conflict is resolved — two agents on the same topic = delivery chaos. |

## Hard requirements

- MUST read every profile file of the target workspace (not just IDENTITY.md).
- MUST read at least IDENTITY.md + SKILL_INDEX.md of every other agent workspace.
- MUST NOT report "CLEAN" without having actually read the files.
- Self-reported "no issues" without reading is a protocol violation.
- Part A issues are blockers for CODE — do not proceed if CONTRADICTION or BINDING_CONFLICT is found.
