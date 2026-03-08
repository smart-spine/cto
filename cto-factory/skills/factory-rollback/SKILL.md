---
name: factory-rollback
description: Restore workspace state to backup branch and remove untracked artifacts after failure.
---

Rollback sequence:
1. Reset all tracked files to `backup/<task-id>`.
2. Remove untracked files/dirs created during failed attempt.
3. Verify rollback completeness (`git status --porcelain` must be empty).
4. Optionally return to prior branch (or stay on current branch with reset state).

Commands:
```bash
git reset --hard backup/<task-id>
git clean -fd
if [ -n "$(git status --porcelain)" ]; then
  echo "ROLLBACK_FAILED"
  exit 1
fi
echo "ROLLBACK_OK"
```

Run rollback immediately when CONFIG_QA fails and rollback policy applies.
