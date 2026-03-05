---
name: factory-create-agent
description: Orchestrate the generation of an entirely new agent through Codex.
---

Rules for defining a new Agent:
- treat any new agent generation as highly critical and strictly isolated work.
- run a structured intake survey first; gather behavior requirements before any code mutation:
  - agent name and mission,
  - destination/bindings,
  - interaction style and message format,
  - trigger/schedule policy,
  - failure and escalation policy,
  - secret handling plan (SecretRef only),
  - model preference (speed/cost/quality).
- enforce strict workspace isolation relative to the ROOT project workspace (`.openclaw/`):
  - create a new dedicated root workspace directory `workspace-<agent_name>/`, 
  - create `workspace-<agent_name>/config`,
  - create `workspace-<agent_name>/tools`,
  - create `workspace-<agent_name>/tests`,
  - create `workspace-<agent_name>/AGENTS.md` or `README.md` as the agent's passport.
- ALWAYS explicitly register the newly created agent in the target project's root `openclaw.json` file. Provide a dummy `agentDir` pointing to `agents/<agent_name>/agent` and set the `workspace` to the newly created `workspace-<agent_name>`.
- never generate new agent payload inside `agents/` or `workspace-factory/agents/`.
- avoid writing plaintext secrets in the config file.
- run provider/model preflight before Codex:
  - inspect root `openclaw.json`,
  - detect active provider family and existing model naming pattern,
  - suggest 2-3 model options that match current provider,
  - do not switch provider family without explicit user approval.

Codex Contract:
- when calling Codex, include the exact instruction: `Write Unit Tests & Verify`.
- use `sessions_spawn` (Codex model) as the preferred invocation path.
- fallback to `exec` + `codex exec` if needed, ensuring the `--cd` argument strictly points to the ROOT project location.
- record the exact `codex exec` command and exit code in the handoff report.
- always generate a companion test file for every new tool (for example `tools/my-tool.test.js`).
- include the confirmed intake summary and provider/model decision in the Codex prompt.

Validation Contract:
1. Apply Codex-produced output (including `openclaw.json` update).
2. IMMEDIATELY run `OPENCLAW_CONFIG_PATH=<path_to_openclaw.json> openclaw config validate --json`. 
   - If validation fails, capture errors and delegate a fix to Codex.
3. Run deterministic tests (`node --test`) immediately.
4. If tests fail, delegate a fix to Codex and rerun tests until green.
5. In the final report, supply evidence: delegation method, exact command used, exit code, test commands, test exit codes, and `openclaw.json` validation result.
