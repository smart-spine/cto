Task: Create a tiny utility agent named `slug-notes` in root workspace `/Users/uladzislaupraskou/.openclaw`.

INTAKE CONFIRMED:
- Agent id/name: slug-notes
- Binding mode: 1A local utility-only (no chat binding required)
- Output shape: 2A return slug string only
- Failure behavior: 3A throw on invalid input (non-string or empty)
- Tests requested: green before handoff

Provider/model context:
- Root openclaw.json currently uses OpenAI family in agents defaults (`openai/gpt-5.2`) and existing cto-factory uses OpenRouter OpenAI codex variant.
- Keep consistency with existing config style; do not introduce unrelated provider drift.

REQUIRED FILE/DIR STRUCTURE (new agent workspace):
- /Users/uladzislaupraskou/.openclaw/workspace-slug-notes/
  - config/
  - tools/
  - tests/
  - skills/
    - SKILL_INDEX.md
    - slug-utils/SKILL.md
  - agent/
    - IDENTITY.md
    - TOOLS.md
    - PROMPTS.md
  - AGENTS.md (or README.md)

Implementation requirements:
1) Implement JS tool in `tools/slugify.js` exposing `slugify.fromSentence(text)`.
2) `fromSentence(text)` behavior:
   - If text is not a string, throw TypeError.
   - Trim input; if empty after trim, throw Error.
   - Convert to lower-case slug with words separated by `-`.
   - Remove punctuation and collapse repeated separators.
   - Return ONLY slug string.
3) Add unit tests (Node test runner) in both:
   - `tools/slugify.test.js` (tool-level tests)
   - `tests/slug-notes.test.js` (agent-level smoke tests)
   Include happy paths and strict failure cases.
4) Add minimal config file under config/ (agent config metadata as appropriate).
5) Update root `/Users/uladzislaupraskou/.openclaw/openclaw.json`:
   - Add new agent entry in `agents.list` with id `slug-notes`, workspace `/Users/uladzislaupraskou/.openclaw/workspace-slug-notes`, agentDir `/Users/uladzislaupraskou/.openclaw/workspace-slug-notes/agent`.
   - Ensure no new binding is added (local utility-only request).
   - Ensure `tools.agentToAgent.allow` includes `slug-notes` (if not already present).
6) Keep diffs scoped only to slug-notes and necessary openclaw registration changes.

Write Unit Tests & Verify.
- Run tests you add and report exact commands + results in your output.

Deliverables in your response:
- Summary of files created/changed
- Test commands run and pass confirmation
- Any assumptions made