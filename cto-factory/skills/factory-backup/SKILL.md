---
name: factory-backup
description: Ensure git is initialized and create a deterministic backup branch before any mutation.
---

Procedure:
1. Check if `.git` exists in the active workspace.
2. If missing:
   - run `git init`,
   - configure a local bot identity if needed,
   - create an initial empty commit (`git commit --allow-empty -m "root"`).
3. Ensure there is a valid baseline commit before edits (commit staged state if necessary).
4. Note the current branch name for later: `CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)`.
5. Create/update backup branch from current `HEAD`.
6. Switch back to the original working branch immediately after creating the backup.
7. Return rollback commands for later steps.

Commands:
```bash
[ ! -d ".git" ] && git init
git config user.email cto-factory@local
git config user.name "CTO Factory"
git rev-parse --verify HEAD >/dev/null 2>&1 || git commit --allow-empty -m "root"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git branch -f backup/<task-id>
# Stay on the current working branch (do NOT switch to the backup branch)
```
