---
name: factory-config-qa
description: Execute OpenClaw native config validation for a specific target config and parse JSON errors.
---

Mandatory command:
You MUST validate the exact config file that was changed.

```bash
OPENCLAW_CONFIG_PATH=<path/to/openclaw.json> openclaw config validate --json
```

Contract:
- path resolution rule:
  - if the task modified root config, target MUST be `$OPENCLAW_ROOT/openclaw.json`,
  - do NOT default to `workspace-factory/openclaw.json`,
- run validation against the specific target file,
- parse JSON output (`valid`, `errors`, line/location hints),
- if validation fails for ANY reason (syntax/semantic/architectural):
  - delegate fix to remembered code agent,
  - re-run the same validation command after delegated fix,
- if `valid: false`:
  - extract each error message and line where available,
  - stop pipeline and return to CODE for fixes,
- if `valid: true`:
  - pass gate to READY_FOR_APPLY.
