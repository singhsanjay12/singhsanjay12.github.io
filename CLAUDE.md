# Claude Code Rules — singhsanjay12.github.io

## Git Workflow

- **Never push directly to `main`.** All changes must go through a pull request, no exceptions — including config changes, quick fixes, and single-line edits.
- Always create a new branch before making changes. Branch names must follow the `ssingh1/<description>` convention (e.g. `ssingh1/add-analytics`).
- Open a PR after pushing the branch. Only merge after review.

## GitHub Account

This repo belongs to the personal account **`singhsanjay12`**, not the LinkedIn managed account.

Before creating any PR, verify the active account:

```bash
gh auth status
```

If the active account is `ssingh1_LinkedIn`, switch before creating the PR:

```bash
gh auth switch --user singhsanjay12
```
