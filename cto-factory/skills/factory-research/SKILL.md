---
name: factory-research
description: Perform deep web research before planning. Mandatory for non-trivial tasks; results cached in .cto-brain/research/ for reuse during implementation.
---

## When to run

- **DEEP** (10–20 sources): new API/library integration, unfamiliar architecture, security implementation, performance optimization, anything involving tech not used in this session.
- **LIGHT** (3–5 sources): behavior change in a known stack where docs are likely trivially known.
- **SKIP**: hotfix < 10 lines, config value change, copy/label update with no logic change.

When in doubt, run LIGHT. Over-researching is always safer than under-researching.

## Search strategy (auto-detect, no API key required by default)

Try in order until results are obtained:

1. **`search_web`** — use if `BRAVE_API_KEY` is configured in openclaw secrets; openclaw will use Brave Search automatically. No extra setup needed if the key is present.
2. **DuckDuckGo via curl (fallback, zero setup)**:
   ```bash
   curl -sA "Mozilla/5.0" "https://html.duckduckgo.com/html/?q=<url-encoded-query>" \
     | grep -oP 'href="https://[^"]*"' | grep -v duckduckgo | sed 's/href="//;s/"//' | head -20
   ```
   Then `web_fetch` on each extracted URL.
3. **Direct fetch (last resort)**: construct likely authoritative URLs (official docs, GitHub, MDN, Stack Overflow) and `web_fetch` each one directly.

Use option 1 if available; fall through to 2 if `search_web` errors or returns empty; fall through to 3 if curl output is unparseable or rate-limited.

## Procedure

### Step 0 — Check for existing skills before building (MANDATORY for any new tool/integration)

Before researching how to build something, check whether a quality skill already exists.
`clawhub` requires no global install — use `npx clawhub@latest` directly:

**Decompose the task into external dependencies first** — search by component, not by full task description. A task like "Reddit pain finder that posts to Telegram" has two searchable components: `reddit` and `telegram`. Search each one separately:

```bash
# Search per external service/API the task depends on
npx clawhub@latest search "reddit"          # not "reddit pain finder"
npx clawhub@latest search "telegram notify" # if Telegram delivery is custom

# If a candidate looks relevant, inspect it for metadata + security scan results
npx clawhub@latest inspect <slug>
```

A skill that covers even **part** of the task is worth surfacing — the agent can use its output instead of rebuilding that layer from scratch.

**Evaluating candidates:**

The `inspect` output includes platform security scans (VirusTotal + OpenClaw). Use these — do NOT run additional manual audits. Check:
- Are both scans **Benign**?
- Does the summary describe behavior that matches the task?
- Does the skill only request env vars / permissions that align with its stated purpose?

**If a candidate passes all three checks**, pause RESEARCH and surface it to the user before building anything:

> Found a skill that may cover this task:
> **`<slug>`** — <one-line summary from inspect>
> Security: VirusTotal Benign · OpenClaw Benign · <confidence level>
> Install: `npx clawhub@latest install <slug>`
>
> Want to use this skill instead of building from scratch? You'd take responsibility for the final behavior — I'll just set it up. Reply **YES to install** or **NO to build custom**.

Do NOT recommend or default to installing — present it neutrally and let the user decide.

**If no candidate passes (no results, scan flagged, or purpose mismatch):** proceed to steps 1–6 below.

### Step 1–6 — Web research

1. Identify 3–5 focused search queries that cover the core implementation approach for the task.
2. For each query: run search → collect top URLs → `web_fetch` each URL → extract key facts.
3. Stop when depth target is reached (DEEP: 10–20 unique sources; LIGHT: 3–5).
4. Store results in `.cto-brain/research/<task-slug>/`:
   - `index.md` — all URLs, one-line summary per source, and key takeaways section at the top
   - `source-01.md`, `source-02.md`, … — URL + full extracted summary (max 500 words each)
5. Write to storage using `exec` directly — research cache is operational state, exempt from code-agent delegation.
6. Feed `index.md` key takeaways into the REQUIREMENTS_SIGNOFF plan — include a **Research basis** block listing what was found and which sources informed each architectural decision.

## Reuse contract (during CODE phase)

- When implementation hits a question already covered by research: `read` the relevant source file from `.cto-brain/research/<task-slug>/` — do not re-fetch.
- Only re-fetch if the cached content is insufficient or a new sub-question requires a new source.
- Record any new sources found during CODE in the same `index.md`.

## On error from unknown sources

If you encounter an unknown error during PREFLIGHT, CODE, or CONFIG_QA and believe a web search would resolve it: run LIGHT research on the specific error, then return to the blocked phase. Do NOT rewind to PREFLIGHT unless that was the blocked phase.
