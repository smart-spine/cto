---
name: factory-rollback
description: Restore workspace state to backup branch and remove untracked artifacts after failure.
---

Rollback sequence:
1. Confirm whether `factory-preflight` flagged protected user-owned untracked files (for example `.env`, screenshots, ad-hoc notes, exported logs).
2. If protected untracked files were flagged, STOP and either:
   - ask for explicit approval to delete them, or
   - move them to a recovery directory before cleanup.
3. Reset all tracked files to `backup/<task-id>`.
4. Remove only untracked files/dirs that are confirmed safe to delete from the failed attempt.
5. Verify rollback completeness (`git status --porcelain` must be empty).
6. Optionally return to prior branch (or stay on current branch with reset state).

Commands:
```bash
git reset --hard backup/<task-id>
# Only run cleanup after confirming untracked-file safety in PREFLIGHT.
git clean -fd
if [ -n "$(git status --porcelain)" ]; then
  echo "ROLLBACK_FAILED"
  exit 1
fi
echo "ROLLBACK_OK"
```

Run rollback immediately when CONFIG_QA fails and rollback policy applies.
