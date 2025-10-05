#!/usr/bin/env bash
set -Eeuo pipefail

### ---------------------------------------------------------------------------
### power_pr.sh — Create & (auto)merge a PR from source->target using gh
### Usage: power_pr.sh <source_branch> <target_branch> [options]
###
### Options:
###   --strategy <merge|squash|rebase>   Merge strategy (default: merge)
###   --no-auto                          Do not enable auto-merge; attempt immediate merge only
###   --no-push                          Do not push source branch before creating PR
###   --allow-dirty                      Allow uncommitted changes in working tree
###   --title "..."                      Custom PR title (default: "Merge <source> into <target>")
###   --body  "..."                      Custom PR body (otherwise a summary is generated)
###   --labels "a,b,c"                   Comma-separated labels to apply on creation
###   --dry-run                          Print intended actions without creating/merging a PR
### Env:
###   POWER_PR_STRATEGY                  Same as --strategy
###   POWER_PR_LABELS                    Default labels if --labels not provided
### ---------------------------------------------------------------------------

### Pretty printing
if [[ -t 1 ]]; then
  BLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
  BLD=""; RED=""; GRN=""; YEL=""; BLU=""; RST=""
fi
say() { echo -e "${BLD}${BLU}==>${RST} $*"; }
warn(){ echo -e "${YEL}warn:${RST} $*" >&2; }
die() { echo -e "${RED}error:${RST} $*" >&2; exit 1; }

usage() {
  grep -E "^### " "$0" | sed -E 's/^### ?//'
}

### Parse args
[[ ${1:-} == "-h" || ${1:-} == "--help" ]] && { usage; exit 0; }
[[ $# -lt 2 ]] && { usage; exit 2; }
SRC=$1; shift
DST=$1; shift

STRATEGY="${POWER_PR_STRATEGY:-merge}"
AUTO=1
PUSH=1
ALLOW_DIRTY=0
TITLE=""
BODY=""
LABELS="${POWER_PR_LABELS:-}"
DRYRUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strategy) STRATEGY="$2"; shift 2 ;;
    --no-auto) AUTO=0; shift ;;
    --no-push) PUSH=0; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --title) TITLE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    *) die "Unknown option: $1" ;;
  esac
done

case "$STRATEGY" in merge|squash|rebase) ;; *) die "Invalid --strategy '$STRATEGY' (use merge|squash|rebase)";; esac

### Require git & gh
command -v git >/dev/null || die "git not found in PATH"
command -v gh  >/dev/null || die "gh (GitHub CLI) not found in PATH"

### Git repo checks
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run this inside a Git repository"
REPO_ROOT=$(git rev-parse --show-toplevel)
REMOTE_NAME=origin
git remote get-url "$REMOTE_NAME" >/dev/null 2>&1 || die "Remote '$REMOTE_NAME' not configured"

REMOTE_URL=$(git remote get-url "$REMOTE_NAME")
say "Repository: ${REPO_ROOT}"
say "Remote '$REMOTE_NAME': $REMOTE_URL"

if [[ $ALLOW_DIRTY -eq 0 ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "Uncommitted changes detected. Commit or use --allow-dirty."
  fi
else
  warn "Proceeding with dirty working tree (--allow-dirty)."
fi

### Authentication check (parse JSON without external jq by using gh's built-in JQ)
AUTH_JSON=$(gh auth status --json hosts --jq '.hosts | to_entries[] | .value[] | select(.active) | {host,login,state,gitProtocol,scopes}' 2>/dev/null || true)
[[ -z "$AUTH_JSON" ]] && die "Not authenticated to GitHub CLI. Run: gh auth login"
AUTH_HOST=$(gh auth status --json hosts --jq '.hosts | to_entries[] | .value[] | select(.active) | .host' 2>/dev/null)
AUTH_LOGIN=$(gh auth status --json hosts --jq '.hosts | to_entries[] | .value[] | select(.active) | .login' 2>/dev/null)
AUTH_STATE=$(gh auth status --json hosts --jq '.hosts | to_entries[] | .value[] | select(.active) | .state' 2>/dev/null)
AUTH_PROTO=$(gh auth status --json hosts --jq '.hosts | to_entries[] | .value[] | select(.active) | .gitProtocol' 2>/dev/null)
say "Auth: ${AUTH_STATE} as ${AUTH_LOGIN}@${AUTH_HOST} (git protocol: ${AUTH_PROTO})"

### Identify repo on GitHub (owner/name)
# Prefer gh (canonical), fallback to parsing remote URL
if REPO_NWO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null); then
  :
else
  # Parse git@github.com:owner/repo.git or https://github.com/owner/repo.git
  REPO_NWO=$(echo "$REMOTE_URL" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
fi
[[ -z "$REPO_NWO" ]] && die "Unable to determine owner/repo."

say "GitHub repo: $REPO_NWO"

### Ensure branches exist and are fetched
say "Fetching latest from '$REMOTE_NAME'..."
git fetch --prune "$REMOTE_NAME" >/dev/null

# Ensure source branch exists locally or track remote
if git show-ref --verify --quiet "refs/heads/$SRC"; then
  :
elif git ls-remote --exit-code --heads "$REMOTE_NAME" "$SRC" >/dev/null 2>&1; then
  say "Creating local branch '$SRC' tracking '$REMOTE_NAME/$SRC'"
  git branch --track "$SRC" "$REMOTE_NAME/$SRC" >/dev/null
else
  die "Source branch '$SRC' not found locally or on remote."
fi

# Ensure target branch exists on remote
git ls-remote --exit-code --heads "$REMOTE_NAME" "$DST" >/dev/null 2>&1 \
  || die "Target branch '$DST' not found on remote '$REMOTE_NAME'."

### Optionally push latest source branch
if [[ $PUSH -eq 1 ]]; then
  say "Pushing '$SRC' to '$REMOTE_NAME/$SRC'..."
  git push "$REMOTE_NAME" "$SRC":"$SRC" --set-upstream >/dev/null
else
  warn "Skipping push (--no-push)."
fi

### Reuse existing open PR if present
EXISTING_URL=$(gh pr list --base "$DST" --head "$SRC" --state open --limit 1 --json url --jq '.[0].url // empty' 2>/dev/null || true)

if [[ -n "$EXISTING_URL" ]]; then
  say "Found existing open PR: $EXISTING_URL"
  PR_URL="$EXISTING_URL"
else
  ### Compose title/body
  if [[ -z "$TITLE" ]]; then
    TITLE="Merge $SRC into $DST"
  fi

  if [[ -z "$BODY" ]]; then
    # Summarize commits from target..source (limit to 50 lines to keep PR tidy)
    RANGE="$REMOTE_NAME/$DST..$SRC"
    COMMITS=$(git log --pretty=format:'- %s' --no-merges "$RANGE" 2>/dev/null | head -n 50 || true)
    [[ -z "$COMMITS" ]] && COMMITS="- No new commits listed (fast-forward or metadata changes)."
    BODY="Automated PR to merge \`$SRC\` ➜ \`$DST\`.

Changes since \`$DST\`:
$COMMITS

_Opened by power_pr.sh on $(date -u +'%Y-%m-%d %H:%M:%SZ')._"
  fi

  say "Creating PR: '$TITLE'"
  CREATE_ARGS=( --base "$DST" --head "$SRC" --title "$TITLE" --body "$BODY" )
  if [[ -n "$LABELS" ]]; then
    CREATE_ARGS+=( --label "$LABELS" )
  fi

  if [[ $DRYRUN -eq 1 ]]; then
    say "[dry-run] gh pr create ${CREATE_ARGS[*]}"
    echo; say "Dry-run complete."; exit 0
  fi

  set +e
  PR_CREATE_OUT=$(gh pr create "${CREATE_ARGS[@]}" 2>&1)
  PR_CREATE_EXIT=$?
  set -e

  if [[ $PR_CREATE_EXIT -ne 0 ]]; then
    # If creation failed because PR exists, try to grab its URL
    EXISTING_URL=$(gh pr list --base "$DST" --head "$SRC" --state open --limit 1 --json url --jq '.[0].url // empty' 2>/dev/null || true)
    [[ -n "$EXISTING_URL" ]] || { echo "$PR_CREATE_OUT" >&2; die "Failed to create PR."; }
    warn "Creation reported an error, but an open PR exists."
    PR_URL="$EXISTING_URL"
  else
    # gh pr create prints URL on success
    PR_URL=$(echo "$PR_CREATE_OUT" | grep -Eo 'https?://[^ ]+' | tail -n1)
  fi

  say "Created PR: $PR_URL"
fi

### Merge logic: immediate merge if possible, else enable auto-merge (unless --no-auto)
if [[ $DRYRUN -eq 1 ]]; then
  say "[dry-run] Would now merge PR ($PR_URL) with strategy '$STRATEGY'${AUTO:+ and enable auto-merge if needed}."
  echo; say "Dry-run complete."; exit 0
fi

if [[ $AUTO -eq 1 ]]; then
  say "Merging (or enabling auto-merge) with strategy '$STRATEGY'..."
  set +e
  MERGE_OUT=$(gh pr merge "$PR_URL" --"$STRATEGY" --auto 2>&1)
  MERGE_EXIT=$?
  set -e
else
  say "Attempting immediate merge with strategy '$STRATEGY' (auto-merge disabled by flag)..."
  set +e
  MERGE_OUT=$(gh pr merge "$PR_URL" --"$STRATEGY" 2>&1)
  MERGE_EXIT=$?
  set -e
fi

if [[ $MERGE_EXIT -ne 0 ]]; then
  warn "Merge command did not complete successfully. Details:"
  echo "$MERGE_OUT" >&2
fi

### Final status
PR_JSON=$(gh pr view "$PR_URL" --json number,state,mergedAt,mergeStateStatus,isInMergeQueue,headRefName,baseRefName,url 2>/dev/null || echo "{}")
pr_state=$(echo "$PR_JSON" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
merged_at=$(echo "$PR_JSON" | sed -n 's/.*"mergedAt":"\([^"]*\)".*/\1/p')

echo
if [[ -n "$merged_at" || "$pr_state" == "MERGED" ]]; then
  say "${GRN}PR merged${RST} ✓  ($PR_URL)"
  exit 0
else
  say "PR is ${YEL}open${RST} ($PR_URL)."
  if [[ $AUTO -eq 1 ]]; then
    say "Auto-merge is likely enabled (or merge queued). GitHub will merge when requirements are satisfied."
  else
    warn "Auto-merge was disabled via --no-auto. Manual follow-up may be required."
  fi
  exit 0
fi
