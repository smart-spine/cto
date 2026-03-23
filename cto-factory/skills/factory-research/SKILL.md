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

Before researching how to build something, check whether a quality skill already exists:

```bash
# Search the OpenClaw skill registry
clawhub search "<task keyword>"          # e.g. "reddit scraper", "github issues", "slack notify"
```

Evaluate results by quality signals (strongest first):
1. **Verified badge** — reviewed by OpenClaw team, passes security scan, actively maintained
2. **Official skill** — one of ~50 maintained directly by OpenClaw
3. **High adoption** — 1 000+ downloads and 5+ stars

If a candidate is found, audit it before recommending:
```bash
# Non-destructive 10-point security check
openclaw-security-check ./skills/<skill-slug>/
```

**If a quality match passes audit:** include in the REQUIREMENTS_SIGNOFF plan as:
> *"Existing skill found: `<slug>` (Verified / N downloads). Recommend installing via `clawhub install <slug>` instead of building from scratch."*
Present it as the default option — user can override and request a custom build.

**If no quality match:** proceed to steps 1–6 below.

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
