---
name: factory-workspace-audit
description: Audit current OpenClaw workspace state before REQUIREMENTS_SIGNOFF. Scans all agent workspaces for duplicate skills, conflicting instructions, and reuse opportunities.
---

## When to run

MANDATORY before presenting REQUIREMENTS_SIGNOFF for any task that creates or modifies an agent workspace. Run after RESEARCH, before producing the sign-off packet.

Skip only for: gateway restart, cron-only changes, pure config-value-only edits with no agent workspace change.

## Goal

Before writing a single line of code, CTO must understand what already exists. This prevents:
- Duplicating skills that another agent already has
- Contradicting instructions that exist elsewhere
- Missing reuse opportunities (shared tools, common patterns)
- Config conflicts between agents

## Procedure

### Step 1 — Scan all agent workspaces

```bash
ls "$OPENCLAW_ROOT"/workspace-*/  # list all workspace directories (NOT workspace-factory)
```

For each workspace found (excluding `workspace-factory`):
- Read `IDENTITY.md` (1-line summary of what the agent does)
- Read `skills/SKILL_INDEX.md` (what skills it has and their triggers)
- Read `tools/` directory listing (what tools/scripts it uses)

### Step 2 — Focus scan on target workspace

If the task targets an existing agent (`workspace-<agent_id>`):
- Read ALL profile files: `IDENTITY.md`, `SOUL.md`, `PROMPTS.md`, `AGENTS.md`/`README.md`, `SKILL_ROUTING.md`
- Read `skills/SKILL_INDEX.md` fully
- List `tools/` and `config/` directory contents
- Note any constants, thresholds, models, or behavior parameters

### Step 3 — Cross-agent analysis

For each skill in the target agent, check:
- Does any OTHER agent have a skill with similar triggers or purpose?
- Can any existing tool script from another agent be reused?
- Are there conflicting instructions (e.g. two agents claim the same Telegram topic)?

Check `openclaw.json` for:
- Binding conflicts (two agents bound to same channel/topic)
- Cron schedule conflicts (same time, same target)
- Model mismatches (agent uses deprecated model)

### Step 4 — Produce audit report

Output a structured audit block to include in REQUIREMENTS_SIGNOFF:

```
## Workspace Audit

### Existing agents scanned
- workspace-<name>: <one-line mission> | skills: <list>
- ...

### Target workspace: workspace-<agent_id>
- [NEW] / [EXISTS — current state summary]
- Files read: [list]
- Current skills: [list with triggers]
- Current tools: [list]

### Reuse opportunities
- [REUSE] <tool/skill> from workspace-<other> can cover: <what>
- [REUSE] None found

### Conflicts and contradictions
- [CONFLICT] <description> — must resolve before CODE
- [CONFLICT] None found

### Duplicate skill risk
- [DUPLICATE] workspace-<other> has skill <name> with overlapping trigger: <trigger>
- [DUPLICATE] None found
```

This audit block feeds directly into the REQUIREMENTS_SIGNOFF package. A sign-off presented without this block is incomplete.

## What to do with findings

- **REUSE opportunity found**: propose reusing the existing component in the sign-off. Don't rebuild what already works.
- **CONFLICT found**: resolve it in the architecture plan. Don't start CODE with unresolved conflicts.
- **DUPLICATE skill**: either reuse the existing one or explicitly justify why a new one is needed (document in the sign-off).

## Hard requirements

- MUST read at least the IDENTITY.md and SKILL_INDEX.md of every other agent workspace.
- MUST NOT skip because "this is a new agent and conflicts are unlikely" — that assumption is frequently wrong.
- Self-reported "no conflicts" without having read the files is a protocol violation.
