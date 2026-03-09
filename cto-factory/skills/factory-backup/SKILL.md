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
4. If a config file is expected to change, persist a baseline snapshot before mutation:
   - create a deterministic snapshot directory inside the active workspace, for example:
     - `.cto-backups/<task-id>/`
   - copy the target config to:
     - `.cto-backups/<task-id>/openclaw.json.before`
   - return that path as `before_config` for `factory-config-diff`.
5. Note the current branch name for later: `CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)`.
6. Create/update backup branch from current `HEAD`.
7. Switch back to the original working branch immediately after creating the backup.
8. Return rollback commands and any baseline snapshot paths for later steps.

Commands:
```bash
[ ! -d ".git" ] && git init
git config user.email cto-factory@local
git config user.name "CTO Factory"
git rev-parse --verify HEAD >/dev/null 2>&1 || git commit --allow-empty -m "root"
mkdir -p ".cto-backups/<task-id>"
cp "<target_config_path>" ".cto-backups/<task-id>/openclaw.json.before"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git branch -f backup/<task-id>
# Stay on the current working branch (do NOT switch to the backup branch)
```
