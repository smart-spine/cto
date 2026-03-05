---
name: factory-memory-garden
description: Maintain structured long-term memory by creating typed note files, updating index links, and archiving superseded notes.
---

Purpose:
- Persist durable knowledge discovered during runs without bloating active context.

Memory root:
- `.cto-brain/`

Required layout:
- `.cto-brain/INDEX.md`
- `.cto-brain/facts/`
- `.cto-brain/decisions/`
- `.cto-brain/patterns/`
- `.cto-brain/incidents/`
- `.cto-brain/preferences/`
- `.cto-brain/plans/active/`
- `.cto-brain/plans/completed/`
- `.cto-brain/archive/`

Input:
- `memory_candidates` from `factory-context-compress`.

Mapping rules:
- `fact` -> `facts/`
- `decision` -> `decisions/`
- `pattern` -> `patterns/`
- `incident` -> `incidents/`
- `preference` -> `preferences/`
- `plan` -> `plans/active/` (or `plans/completed/` when explicitly done)

Procedure:
1. Ensure all required directories and `.cto-brain/INDEX.md` exist.
2. For each candidate, create or update one note file:
   - filename format: `YYYY-MM-DD--<slug>.md`
   - include fields: `title`, `type`, `summary`, `confidence`, `evidence`, `source_run`.
3. Deduplicate:
   - if a note with the same title/type already exists, update that note instead of creating a duplicate.
4. Archive superseded notes:
   - move outdated files to `.cto-brain/archive/` and add one-line reason.
5. Refresh `.cto-brain/INDEX.md` with links to recent notes by section.

Output contract:
- return `memory_updates` with:
  - `created`: list of new note paths,
  - `updated`: list of modified note paths,
  - `archived`: list of archived note paths,
  - `index_updated`: boolean.
