---
name: factory-memory-garden
description: Maintain structured long-term memory by creating typed note files, updating index links, and archiving superseded notes.
---

Purpose:
- Persist durable knowledge discovered during runs without bloating active context.
- Preserve learned workarounds and successful fixes so they are reused automatically.

Memory root:
- `.cto-brain/`

Required layout:
- `.cto-brain/INDEX.md`
- `.cto-brain/facts/`
- `.cto-brain/decisions/`
- `.cto-brain/patterns/`
- `.cto-brain/incidents/`
- `.cto-brain/preferences/`
- `.cto-brain/workarounds/`
- `.cto-brain/plans/active/`
- `.cto-brain/plans/completed/`
- `.cto-brain/archive/`

Input (two modes):
- **Triggered mode** (proactive, during work): a single memory candidate triggered by a write event — user correction, workaround found, decision made. Write immediately without waiting for session end.
- **Batch mode** (session end / context compress): `memory_candidates` list from `factory-context-compress`.

Memory writes are exempt from code-agent delegation. Write note files directly using `exec` or `write` tool — these are operational state, not project mutations.

Mapping rules:
- `fact` -> `facts/`
- `decision` -> `decisions/`
- `pattern` -> `patterns/`
- `incident` -> `incidents/`
- `preference` -> `preferences/`
- `workaround` -> `workarounds/`
- `plan` -> `plans/active/` (or `plans/completed/` when explicitly done)

## Workaround Memory (MANDATORY)

When CTO encounters a blocker during execution and finds a legitimate solution (from user guidance or autonomous recovery without violating rules):
1. Persist the fix as a `workaround` note immediately after success.
2. Required fields:
   - `problem`: exact error/blocker description,
   - `solution`: exact command/flags/approach that resolved it,
   - `context`: when this applies (OS, container, provider, etc.),
   - `source`: `user_guidance` or `autonomous_discovery`,
   - `verified`: `true` (only persist solutions that actually worked).
3. Before retrying a known error pattern, ALWAYS check `workarounds/` first.
4. If a matching workaround exists, apply it directly instead of re-discovering the fix.

Example: if code-agent delegation fails with a specific flag and a workaround flag/prompt works, save that as a workaround for future runs.

## Self-Authored Tagging

Every note file written by CTO MUST include a metadata line:
- `authored_by: cto-factory`
- `authored_at: <ISO timestamp>`

This distinguishes CTO-generated memory from seed/template content.

## Procedure
1. Ensure all required directories and `.cto-brain/INDEX.md` exist.
2. For each candidate, create or update one note file:
   - filename format: `YYYY-MM-DD--<slug>.md`
   - include fields: `title`, `type`, `summary`, `confidence`, `evidence`, `source_run`, `last_verified`, `authored_by`, `authored_at`.
3. Deduplicate:
   - if a note with the same title/type already exists, update that note instead of creating a duplicate.
4. Archive superseded notes:
   - move outdated files to `.cto-brain/archive/` and add one-line reason.
5. Refresh `.cto-brain/INDEX.md` with links to recent notes by section.
6. Staleness hygiene:
   - during updates, if a referenced note has `last_verified` older than 30 days, add `needs_review: true` flag and surface it in output.

Output contract:
- return `memory_updates` with:
  - `created`: list of new note paths,
  - `updated`: list of modified note paths,
  - `archived`: list of archived note paths,
  - `index_updated`: boolean.
