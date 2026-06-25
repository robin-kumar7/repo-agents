#!/usr/bin/env bash
# onboard.sh — set up repo-agent-bootstrap in a target repo, end-to-end.
#
# Run inside the target repo's working directory:
#
#     cd /path/to/target-repo
#     /path/to/repo-agent-bootstrap/bin/onboard.sh
#
# What it does (in order):
#   1. Preflight: git/gh available, cwd is a clean git repo, gh authenticated.
#   2. Detect target repo's owner/name from `origin`.
#   3. Detect tooling repo's owner/name from THIS script's own clone.
#   4. Show plan; ask for confirmation.
#   5. Read ANTHROPIC_API_KEY (env or silent prompt).
#   6. Create a feature branch `chore/setup-repo-agents`.
#   7. Drop the caller workflows (with `uses:` rewritten to your tooling-repo org).
#   8. Commit + push the branch.
#   9. Open a draft PR.
#  10. Set the ANTHROPIC_API_KEY secret on the target repo.
#  11. Set workflow permissions: contents=write, can-create-PRs=true.
#  12. Print next steps + the PR URL.
#
# Flags:
#   --weekly             also install the weekly cron refresh workflow
#   --no-pr              commit + push only, do not open the PR
#   --branch <name>      override branch name (default: chore/setup-repo-agents)
#   --tooling-repo X/Y   override detected tooling repo (e.g. org/repo-agent-bootstrap)
#   --skip-secret        do not set ANTHROPIC_API_KEY (set it yourself later)
#   --skip-perms         do not adjust workflow permissions
#   --yes                skip the confirmation prompt
#   --help               print this help

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------- utilities

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }

info()  { printf '%s %s\n'  "$(c_green '==>')" "$*"; }
warn()  { printf '%s %s\n'  "$(c_yellow 'warn:')" "$*" >&2; }
die()   { printf '%s %s\n'  "$(c_red 'error:')" "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  exit "${1:-0}"
}

# ----------------------------------------------------------------- args

WEEKLY=false
OPEN_PR=true
BRANCH="chore/setup-repo-agents"
TOOLING_REPO=""
SKIP_SECRET=false
SKIP_PERMS=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --weekly)        WEEKLY=true ;;
    --no-pr)         OPEN_PR=false ;;
    --branch)        BRANCH="${2:?--branch needs a value}"; shift ;;
    --tooling-repo)  TOOLING_REPO="${2:?--tooling-repo needs a value}"; shift ;;
    --skip-secret)   SKIP_SECRET=true ;;
    --skip-perms)    SKIP_PERMS=true ;;
    --yes|-y)        ASSUME_YES=true ;;
    --help|-h)       usage 0 ;;
    *)               die "unknown flag: $1 (try --help)" ;;
  esac
  shift
done

# ----------------------------------------------------------------- preflight

command -v git >/dev/null || die "git is not installed"
command -v gh  >/dev/null || die "gh (GitHub CLI) is not installed — see https://cli.github.com"
command -v awk >/dev/null || die "awk is not installed"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

# Resolve tooling-repo location (where this script lives).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TOOLING_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Sanity-check the tooling tree.
for required in \
  "$TOOLING_ROOT/examples/caller-workflow.yml" \
  "$TOOLING_ROOT/examples/caller-index-workflow.yml" \
  "$TOOLING_ROOT/examples/caller-weekly-refresh.yml" \
  "$TOOLING_ROOT/.github/workflows/bootstrap.yml" \
  "$TOOLING_ROOT/.github/workflows/index.yml"
do
  [[ -f "$required" ]] || die "missing in tooling repo: $required"
done

# Detect tooling repo's owner/name (from its own git remote) unless overridden.
if [[ -z "$TOOLING_REPO" ]]; then
  TOOLING_REPO="$(git -C "$TOOLING_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#(git@github\.com:|https?://github\.com/)([^/]+/[^/.]+)(\.git)?#\2#')" \
    || die "could not detect tooling repo from $TOOLING_ROOT (override with --tooling-repo)"
fi
[[ "$TOOLING_REPO" == */* ]] || die "tooling-repo must be owner/name, got: $TOOLING_REPO"

# We're now in the target repo's cwd.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "current directory is not a git repo"

[[ -z "$(git status --porcelain)" ]] \
  || die "working tree has uncommitted changes — commit or stash first"

# Target repo identity.
TARGET_REMOTE="$(git remote get-url origin 2>/dev/null)" \
  || die "current repo has no 'origin' remote"
TARGET_REPO="$(echo "$TARGET_REMOTE" \
  | sed -E 's#(git@github\.com:|https?://github\.com/)([^/]+/[^/.]+)(\.git)?#\2#')"
[[ "$TARGET_REPO" == */* ]] || die "could not parse owner/name from origin: $TARGET_REMOTE"

DEFAULT_BRANCH="$(gh repo view "$TARGET_REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" \
  || die "could not query target repo $TARGET_REPO via gh"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
  warn "you are on '$CURRENT_BRANCH', not the default branch '$DEFAULT_BRANCH'"
  warn "the script will branch from HEAD; if that's not what you want, abort and switch."
fi

# ----------------------------------------------------------------- plan

cat <<EOF

$(c_bold 'Plan')
  Target repo:        $(c_bold "$TARGET_REPO") (default branch: $DEFAULT_BRANCH)
  Tooling repo:       $(c_bold "$TOOLING_REPO")
  Feature branch:     $BRANCH
  Will create:
    .github/workflows/bootstrap-agents.yml
    .github/workflows/agent-index.yml
EOF
if [[ "$WEEKLY" == "true" ]]; then
  printf '    .github/workflows/repo-index-weekly.yml\n'
fi
cat <<EOF
  Open draft PR:      $OPEN_PR
  Set ANTHROPIC_API_KEY secret: $([ "$SKIP_SECRET" = true ] && echo no || echo yes)
  Adjust workflow permissions:  $([ "$SKIP_PERMS"  = true ] && echo no || echo yes)

EOF

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by user"
fi

# ----------------------------------------------------------------- api key

API_KEY=""
if [[ "$SKIP_SECRET" != "true" ]]; then
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    API_KEY="$ANTHROPIC_API_KEY"
    info "using ANTHROPIC_API_KEY from environment"
  else
    # Silent read — never echoed.
    printf '%s ' "$(c_bold 'Anthropic API key (input hidden):')" >&2
    IFS= read -rs API_KEY
    printf '\n' >&2
    [[ -n "$API_KEY" ]] || die "API key cannot be empty (or re-run with --skip-secret)"
  fi
fi

# ----------------------------------------------------------------- branch

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "branch '$BRANCH' already exists locally — delete it or use --branch <other>"
fi

if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  die "branch '$BRANCH' already exists on origin — delete it or use --branch <other>"
fi

info "creating branch: $BRANCH"
git checkout -b "$BRANCH" >/dev/null

# ----------------------------------------------------------------- drop files

mkdir -p .github/workflows

# Cross-platform sed -i (macOS BSD vs GNU).
sed_inplace() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

drop_workflow() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]]; then
    die "would clobber existing $dst — delete it first if you want to recreate"
  fi
  cp "$src" "$dst"
  # Rewrite the placeholder org to your tooling-repo's actual org.
  sed_inplace "s#uses: org/repo-agent-bootstrap#uses: $TOOLING_REPO#g" "$dst"
  info "wrote $dst"
}

drop_workflow "$TOOLING_ROOT/examples/caller-workflow.yml"       ".github/workflows/bootstrap-agents.yml"
drop_workflow "$TOOLING_ROOT/examples/caller-index-workflow.yml" ".github/workflows/agent-index.yml"
if [[ "$WEEKLY" == "true" ]]; then
  drop_workflow "$TOOLING_ROOT/examples/caller-weekly-refresh.yml" ".github/workflows/repo-index-weekly.yml"
fi

# ----------------------------------------------------------------- commit

git add .github/workflows/
COMMIT_MSG="ci: enable repo-agent-bootstrap workflows"
git -c user.useConfigOnly=false commit -m "$COMMIT_MSG" >/dev/null
info "committed: $COMMIT_MSG"

info "pushing branch to origin"
git push --set-upstream origin "$BRANCH" >/dev/null

# ----------------------------------------------------------------- pr

PR_URL=""
if [[ "$OPEN_PR" == "true" ]]; then
  info "opening draft pull request"
  PR_URL="$(gh pr create \
    --repo "$TARGET_REPO" \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH" \
    --draft \
    --title "ci: enable repo-agent-bootstrap workflows" \
    --label "automation,agents,needs-review" \
    --body "$(cat <<EOM
Adds three GitHub Actions workflows that wire this repo into the
\`$TOOLING_REPO\` agent + index automation.

**What this PR adds:**

- \`.github/workflows/bootstrap-agents.yml\` — manual trigger; runs the LLM-driven bootstrap that generates \`site/content/repo-index.md\`, \`taxonomy.yaml\`, agent files, and language-specific review instructions.
- \`.github/workflows/agent-index.yml\` — auto-runs on every push to \`$DEFAULT_BRANCH\`; regenerates \`.agent-index/symbols.json\` + \`.agent-index/logs.json\` using \`universal-ctags\` + a Python log extractor. Deterministic, no LLM.
$([ "$WEEKLY" = true ] && echo '- `.github/workflows/repo-index-weekly.yml` — cron-runs every Monday at 08:00 UTC; refreshes `repo-index.md` only.' || echo '')

**After merging this PR:**

1. Manually trigger \`Bootstrap agents\` (Actions tab → Run workflow → mode \`full\`) to produce the first batch of agent files and the curated repo index. That run will open another draft PR for you to review.
2. \`Build agent index\` will start running on every push to \`$DEFAULT_BRANCH\` automatically.

This PR was opened by \`bin/onboard.sh\`.
EOM
)" 2>&1 | tail -1)" || die "gh pr create failed"
  info "PR opened: $PR_URL"
fi

# ----------------------------------------------------------------- secret

if [[ "$SKIP_SECRET" != "true" ]]; then
  info "setting ANTHROPIC_API_KEY secret on $TARGET_REPO"
  printf '%s' "$API_KEY" | gh secret set ANTHROPIC_API_KEY --repo "$TARGET_REPO" >/dev/null
  info "secret set"
  unset API_KEY
fi

# ----------------------------------------------------------------- permissions

if [[ "$SKIP_PERMS" != "true" ]]; then
  info "setting workflow permissions (contents:write, can-create-PRs:true)"
  if gh api \
       -X PUT "/repos/$TARGET_REPO/actions/permissions/workflow" \
       -F default_workflow_permissions=write \
       -F can_approve_pull_request_reviews=true \
       >/dev/null 2>&1
  then
    info "workflow permissions updated"
  else
    warn "could not update workflow permissions automatically — most likely a repo-admin"
    warn "permissions issue. Set them manually at:"
    warn "  https://github.com/$TARGET_REPO/settings/actions"
    warn "  -> Workflow permissions: 'Read and write permissions'"
    warn "  -> Check 'Allow GitHub Actions to create and approve pull requests'"
  fi
fi

# ----------------------------------------------------------------- next steps

cat <<EOF

$(c_green '✓ Onboarding complete')

Target repo:    $TARGET_REPO
Feature branch: $BRANCH
EOF
[[ -n "$PR_URL" ]] && printf 'Draft PR:       %s\n' "$PR_URL"
cat <<EOF

$(c_bold 'Next steps')

  1. Review the PR above and merge it into $DEFAULT_BRANCH.

  2. Trigger the first bootstrap run:
       https://github.com/$TARGET_REPO/actions/workflows/bootstrap-agents.yml
       → Run workflow → mode: full → Run workflow

     That run will open a SECOND draft PR with the generated agent files,
     repo-index.md, taxonomy.yaml, etc. Review and merge that one too.

  3. After the bootstrap PR merges, $(c_bold 'agent-index.yml') will run automatically
     on every push to $DEFAULT_BRANCH and commit .agent-index/*.json back to main.
EOF
if [[ "$WEEKLY" == "true" ]]; then
  cat <<EOF

  4. The weekly refresh is enabled (cron: Monday 08:00 UTC). Disable any time
     via the Actions tab if you don't want it.
EOF
fi
cat <<EOF

$(c_bold 'If your org locks third-party Actions')

  The bootstrap workflow uses these third-party Actions. If they are not in
  your org's allowlist, the first run will fail with "Action xxx is not
  allowed". Ask your org admin to allow these (one-time, one-line each):

    - anthropics/claude-code-action@v1
    - peter-evans/create-pull-request@v6

EOF
