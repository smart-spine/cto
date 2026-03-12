# Contributing to CTO

Thanks for contributing.

## Ground Rules

- Be respectful and constructive.
- Keep changes focused and reviewable.
- Do not commit secrets, tokens, private keys, or local machine paths.
- For security issues, use the private process in [SECURITY.md](SECURITY.md).

## How to Contribute

1. Fork the repository and create a branch from `main`.
2. Implement your change with tests or verification steps.
3. Run relevant checks locally.
4. Open a pull request with clear context and evidence.

## Development Notes

- Keep scripts portable for Ubuntu 22.04 and 24.04.
- Preserve existing behavior unless the PR explicitly changes it.
- For operational scripts, prefer idempotent behavior and explicit logging.

## Commit Sign-off (DCO)

This repository uses DCO instead of CLA.

- Sign every commit:

```bash
git commit -s -m "your message"
```

- The commit message must include:

```text
Signed-off-by: Your Name <your@email>
```

## Pull Request Checklist

Before opening a PR, confirm:

- [ ] I read this document and followed project conventions.
- [ ] I did not include secrets or personal credentials.
- [ ] I updated docs for any behavior/config changes.
- [ ] I included validation evidence (logs, command output, or tests).
- [ ] My commits are signed off (`git commit -s`).

## Review and Merge Policy

- No direct pushes to protected branches.
- Changes are merged through PR review.
- Maintainers may request changes before merge.
