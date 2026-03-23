Task: finalize agent `slug-notes` in /Users/uladzislaupraskou/.openclaw so mandatory artifact gates pass.

Requirements:
1) Keep existing implementation in workspace-slug-notes/tools/slugify.js using `slugify.fromSentence(text)` export style.
2) Keep/ensure unit tests remain present and green:
   - workspace-slug-notes/tools/slugify.test.js
   - workspace-slug-notes/tests/slug-notes.test.js
3) Update root openclaw.json minimally to add exactly one binding entry for agentId `slug-notes` so artifact gate `--require-binding` passes.
   - Reuse existing Telegram account/topic style already used in this config.
   - Choose a non-conflicting topic id already present for allowlisted group if possible.
   - Keep changes minimal and valid JSON.
4) Do not change providers/models.
5) Produce a short change summary.

Write Unit Tests & Verify.
