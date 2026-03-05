---
name: factory-rollback
description: Restore workspace state to backup branch and remove untracked artifacts after failure.
---

Rollback sequence:
1. Reset all tracked files to `backup/<task-id>`.
2. Remove untracked files/dirs created during failed attempt.
3. Optionally return to prior branch (or stay on current branch with reset state).

Commands:
```bash
git reset --hard backup/<task-id>
git clean -fd
```

Run rollback immediately when CONFIG_QA fails and rollback policy applies.
