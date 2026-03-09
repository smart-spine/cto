---
name: factory-research
description: Perform autonomous web searches to fetch fresh documentation or solutions before writing code.
---

Rules:
- Use this skill during the `RESEARCH` phase when asked to integrate with a new 3rd-party API or library, or if the user explicitly asks for research.
- Also use this skill if you encounter an unknown error that might be solved by searching the web.
- You have access to tools like `search_web` or you can use `exec` to run `curl` to fetch content if you know the exact URL.

Procedure:
1. Identify the core technology, API, or error that requires research.
2. Search the web for official documentation, SDK guides, or StackOverflow solutions.
3. Fetch the content and summarize the findings.
4. Inject the summarized architectural patterns or API definitions into your Codex generation prompt in the `CODE` phase.
5. Record the fact that research was performed and list the URLs consulted in the handoff report.
6. After completing research, return to the caller's blocked phase (for example `INTAKE`, `PREFLIGHT`, `CODE`, or `CONFIG_QA`) and continue the state machine from there. Do NOT blindly rewind to `PREFLIGHT` unless that was the blocked phase.
