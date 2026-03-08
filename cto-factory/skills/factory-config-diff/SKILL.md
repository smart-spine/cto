---
name: factory-config-diff
description: Produce a structured diff summary for openclaw.json changes before apply approval.
---

Use this skill whenever `openclaw.json` was modified in the current run.

Inputs:
- `before_config`: path to baseline config snapshot (for example from backup branch/worktree copy),
- `after_config`: path to current config.

Command:
```bash
python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/workspace-factory/scripts/cto_config_diff.py \
  --before <before_config> \
  --after <after_config>
```

Output requirements:
1. Include counts of added/removed/changed paths.
2. Show key changed paths (limit noisy paths if very long).
3. Highlight high-risk keys explicitly:
   - `agents.list`,
   - `bindings`,
   - `tools.sessions`,
   - `tools.agentToAgent`,
   - `channels.telegram`,
   - model/provider settings.
4. If diff cannot be computed, mark task `BLOCKED` until baseline path is provided.
