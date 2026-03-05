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
- run validation against the specific target file,
- parse JSON output (`valid`, `errors`, line/location hints),
- if `valid: false`:
  - extract each error message and line where available,
  - stop pipeline and return to CODE for fixes,
- if `valid: true`:
  - pass gate to READY_FOR_APPLY.
