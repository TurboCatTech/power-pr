# power-pr

One-command GitHub Pull Request creator/merger in Bash (uses `gh`).
Create a PR from **source → target** branch, then merge immediately or enable **auto-merge**.

---

## Requirements

* Linux
* [`git`](https://git-scm.com/) and [`gh` (GitHub CLI)](https://cli.github.com/) available in PATH
* `gh auth login` completed for the machine/CI runner
* Remote named `origin` pointing to a GitHub repo

---

## 1) Install & use with **Composer** (project-local, dev tool)

**Install (dev):**

```bash
composer require --dev turbocat/power-pr
```

**Add an alias in your project’s `composer.json`:**

```json
{
  "scripts": {
    "power-pr": "vendor/bin/power-pr"
  }
}
```

**Run:**

```bash
composer power-pr main production
# with options:
composer power-pr main production --strategy squash --labels "release,auto-merge"
```

---

## 2) Install & use with **npm** (project-local, dev tool)

**Install (dev):**

```bash
npm i -D @turbocat/power-pr
```

**Add an alias in your project’s `package.json`:**

```json
{
  "scripts": {
    "power-pr": "./node_modules/@turbocat/power-pr/bin/power-pr"
  }
}
```

**Run:**

```bash
npm run power-pr -- main production
# or directly via npx:
npx power-pr main production
```

---

## 3) Use **without** Composer/npm (vendor-less)

Add the script directly to your repo:

```bash
mkdir -p scripts
curl -fsSL https://raw.githubusercontent.com/TurboCatTech/power-pr/main/scripts/power_pr.sh -o scripts/power_pr.sh
chmod +x scripts/power_pr.sh
```

*(optional)* Add the tiny wrapper so you can call `bin/power-pr`:

```bash
mkdir -p bin
cat > bin/power-pr <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec bash "$PKG_ROOT/scripts/power_pr.sh" "$@"
SH
chmod +x bin/power-pr
```

**Run:**

```bash
bash scripts/power_pr.sh main production
# or (if you added the wrapper)
bin/power-pr main production
```

---

## Options, env vars & examples (common to all installs)

**Usage**

```bash
power-pr <source_branch> <target_branch> [options]
```

**Options**

* `--strategy <merge|squash|rebase>` — merge strategy (default: `merge`)
* `--no-auto` — don’t enable auto-merge; attempt immediate merge only
* `--no-push` — skip pushing the source branch before creating the PR
* `--allow-dirty` — proceed even if there are uncommitted changes
* `--title "..."` — custom PR title (default: `Merge <source> into <target>`)
* `--body "..."` — custom PR body (default: generated summary)
* `--labels "a,b,c"` — comma-separated labels to apply on creation
* `--dry-run` — print intended actions without creating/merging a PR

**Environment variables**

* `POWER_PR_STRATEGY` — default strategy if `--strategy` isn’t provided
* `POWER_PR_LABELS` — default labels if `--labels` isn’t provided

**Exit codes**

* `0`  success (PR created and merged, or auto-merge enabled)
* `≠0` failure (validation, fetch/push, or `gh` errors)

**Examples (Composer alias shown; identical flags for npm/without)**

```bash
# Basic deploy PR (main -> production), auto-merge when possible
composer power-pr main production

# Squash merge with labels
composer power-pr main production --strategy squash --labels "release,auto-merge"

# Create PR but don’t enable auto-merge
composer power-pr main production --no-auto

# Dry run (no changes)
composer power-pr main production --dry-run

# Custom title/body
composer power-pr main production \
  --title "Deploy: main → production" \
  --body  "Promotes latest changes to production."
```

---

## Troubleshooting

* **HTTPS prompt error**
  `fatal: could not read Username for 'https://github.com': terminal prompts disabled`
  Use SSH remote or configure `gh` to supply HTTPS credentials:

  ```bash
  git remote set-url origin git@github.com:<owner>/<repo>.git
  # or
  gh auth setup-git
  ```

* **Uncommitted changes**
  Commit them or use `--allow-dirty` if you know what you’re doing.

* **Branch not found**
  Ensure `<target_branch>` exists on `origin`; `<source_branch>` must exist locally or on remote.

---



## License

[MIT](./LICENSE) © TurboCat Technology
