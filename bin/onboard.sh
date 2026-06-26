#!/usr/bin/env bash
# onboard.sh — set up repo-agent-bootstrap in a target repo, end-to-end.
#
# Two-phase flow. Run inside the TARGET repo's working directory.
#
# ─── Phase 1: stage files ──────────────────────────────────────────────
#
#     cd /path/to/target-repo
#     /path/to/repo-agent-bootstrap/bin/onboard.sh setup
#
#   Default mode — stages everything for a LOCAL VS Code Copilot run:
#     - drops .github/workflows/agent-index.yml          (keyless layer-2 indexer)
#     - drops .github/agents/bootstrap.agent.md          (so Copilot's agent picker discovers it)
#     - stages templates + vocab into tmp/repo-agent-bootstrap/
#     - creates feature branch chore/setup-repo-agents   (does NOT commit)
#     - writes state to .git/repo-agent-bootstrap-state.sh
#     - prints the exact prompt to paste into Copilot agent mode
#
#   With --ci-bootstrap — stages files for the CI-driven flow instead:
#     - drops .github/workflows/agent-index.yml          (keyless layer-2 indexer)
#     - drops .github/workflows/bootstrap-agents.yml     (LLM layer-1 bootstrap)
#     - drops .github/workflows/repo-index-weekly.yml    (with --weekly)
#     - NO local templates, NO local agent file
#     - creates feature branch + state, prints next steps
#
# ─── Phase 2: run the bootstrap (default mode only) ────────────────────
#
#   In VS Code with the target repo open:
#     a. Open Copilot chat → switch to AGENT mode
#     b. Select the 'bootstrap' agent from the picker
#     c. Paste the prompt printed by 'setup' (it pre-fills the env vars)
#     d. Wait for the agent to write the generated artifacts
#
# ─── Phase 3: commit + PR ──────────────────────────────────────────────
#
#     /path/to/repo-agent-bootstrap/bin/onboard.sh finalize
#
#   Does:
#     - loads state, verifies you're on the right branch
#     - (default mode) deletes tmp/repo-agent-bootstrap/ and the bootstrap agent file
#     - git add -A → commit → push → open a draft PR
#     - (ci-bootstrap mode) prompts for ANTHROPIC_API_KEY and sets the secret
#     - sets workflow permissions (contents:write, can-create-PRs:true)
#     - removes the state file
#
# Flags (setup):
#   --ci-bootstrap        stage the CI-driven flow instead of local Copilot
#                         (alias: --with-bootstrap-workflow, for back-compat)
#   --weekly              also install the weekly cron workflow (implies --ci-bootstrap)
#   --branch <name>       override branch name (default: chore/setup-repo-agents)
#   --tooling-repo X/Y    override detected tooling repo (e.g. org/repo-agent-bootstrap)
#   --yes / -y            skip the confirmation prompt
#   --help / -h           print this help
#
# Flags (finalize):
#   --no-pr               commit + push only, do not open a PR
#   --skip-secret         do not set ANTHROPIC_API_KEY (no-op in default mode)
#   --skip-perms          do not adjust workflow permissions
#   --keep-staged         do not delete tmp/repo-agent-bootstrap/ (debugging)
#   --yes / -y            skip the confirmation prompt
#   --help / -h           print this help

# Refuse to run under non-bash shells. `sh onboard.sh` ignores the shebang
# and, on systems where /bin/sh is dash (or similar), silently breaks
# bashisms like [[ ]], read -s, BASH_SOURCE, and `set -o pipefail`.
# (This block is intentionally POSIX-only so it works even under dash.)
if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: this script must be run with bash, not sh." >&2
  echo "       try:  bash $0   (or just: $0)" >&2
  exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# Disable gh's pager so any 'gh ...' call inside $(...) substitution doesn't
# try to open a TUI (which corrupts captured output).
export GH_PAGER=cat

# ----------------------------------------------------------------- utilities

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }

info()  { printf '%s %s\n'  "$(c_green '==>')" "$*"; }
warn()  { printf '%s %s\n'  "$(c_yellow 'warn:')" "$*" >&2; }
die()   { printf '%s %s\n'  "$(c_red 'error:')" "$*" >&2; exit 1; }

usage() {
  # Print the docstring (lines 2 to the first blank line), strip the leading
  # comment marker, drop the trailing blank line itself.
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  exit "${1:-0}"
}

# ----------------------------------------------------------------- paths

# All paths below are relative to the target repo root (we cd there before use).
STAGING_DIR="tmp/repo-agent-bootstrap"
STAGED_AGENT_PATH=".github/agents/bootstrap.agent.md"
KEYLESS_WORKFLOW_PATH=".github/workflows/agent-index.yml"
AGENT_SYNC_WORKFLOW_PATH=".github/workflows/agent-sync.yml"
CI_BOOTSTRAP_WORKFLOW_PATH=".github/workflows/bootstrap-agents.yml"
CI_WEEKLY_WORKFLOW_PATH=".github/workflows/repo-index-weekly.yml"
STATE_FILE=".git/repo-agent-bootstrap-state.sh"

# Cross-platform sed -i (macOS BSD vs GNU).
sed_inplace() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

# ----------------------------------------------------------------- shared preflight

# Resolves the target + tooling repos. Sets globals: TOOLING_ROOT, TOOLING_REPO,
# TARGET_ROOT, TARGET_REPO, DEFAULT_BRANCH, CURRENT_BRANCH. Takes one arg: the
# tooling-repo override (may be empty).
do_preflight() {
  local tooling_override="$1"

  command -v git >/dev/null || die "git is not installed"
  command -v gh  >/dev/null || die "gh (GitHub CLI) is not installed — see https://cli.github.com"
  command -v awk >/dev/null || die "awk is not installed"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

  # Locate the tooling repo (where this script lives).
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  TOOLING_ROOT="$(cd "$script_dir/.." && pwd -P)"

  # Sanity-check the tooling tree.
  local required
  for required in \
    "$TOOLING_ROOT/examples/caller-workflow.yml" \
    "$TOOLING_ROOT/examples/caller-index-workflow.yml" \
    "$TOOLING_ROOT/examples/caller-weekly-refresh.yml" \
    "$TOOLING_ROOT/examples/caller-agent-sync.yml" \
    "$TOOLING_ROOT/agents/bootstrap.agent.md" \
    "$TOOLING_ROOT/templates" \
    "$TOOLING_ROOT/vocab/taxonomy-types.yaml" \
    "$TOOLING_ROOT/.github/workflows/bootstrap.yml" \
    "$TOOLING_ROOT/.github/workflows/index.yml" \
    "$TOOLING_ROOT/.github/workflows/agent-sync.yml" \
    "$TOOLING_ROOT/scripts/sync-agents.sh"
  do
    [[ -e "$required" ]] || die "missing in tooling repo: $required"
  done

  # Detect tooling repo's owner/name via gh (canonicalises https/ssh/with-or-
  # without-.git/dotted-names like foo.bar). Passing the URL explicitly avoids
  # gh asking us to `gh repo set-default`.
  if [[ -n "$tooling_override" ]]; then
    TOOLING_REPO="$tooling_override"
  else
    local _tooling_url
    _tooling_url="$(git -C "$TOOLING_ROOT" remote get-url origin 2>/dev/null)" \
      || die "tooling repo at $TOOLING_ROOT has no 'origin' remote (override with --tooling-repo)"
    TOOLING_REPO="$(gh repo view "$_tooling_url" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
      || die "could not resolve tooling repo from $_tooling_url (override with --tooling-repo)"
  fi
  [[ "$TOOLING_REPO" == */* ]] || die "tooling-repo must be owner/name, got: $TOOLING_REPO"

  # We're now (supposed to be) in the target repo's cwd.
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "current directory is not a git repo

Run this script from inside your TARGET repo:
  cd /path/to/your-target-repo
  $script_dir/onboard.sh setup"

  TARGET_ROOT="$(git rev-parse --show-toplevel)"

  # Guard: refuse to run inside the tooling repo tree itself. This is the most
  # common foot-gun — someone runs 'sh onboard.sh' from bin/ and the script
  # happily targets the tooling repo because both 'origin' remotes are the same.
  if [[ "$TARGET_ROOT" == "$TOOLING_ROOT" ]]; then
    die "you are running this script inside the tooling repo itself ($TOOLING_ROOT).

cd into your TARGET repo first, then invoke the script by absolute path:
  cd /path/to/your-target-repo
  $script_dir/onboard.sh setup"
  fi

  local target_remote
  target_remote="$(git remote get-url origin 2>/dev/null)" \
    || die "current repo has no 'origin' remote"
  TARGET_REPO="$(gh repo view "$target_remote" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || die "could not resolve target repo from $target_remote (is it a GitHub remote?)"
  [[ "$TARGET_REPO" == */* ]] || die "unexpected target repo identity: $TARGET_REPO"

  # Second guard: same repo identity (covers forks/worktrees where TARGET_ROOT
  # differs but the remote is the same as the tooling repo's remote).
  if [[ "$TARGET_REPO" == "$TOOLING_REPO" ]]; then
    die "target repo and tooling repo are the same ($TARGET_REPO).

You appear to be running the script from inside the tooling repo. cd into
your TARGET repo first, or pass --tooling-repo <owner/name> if the tooling
really does live in a different repo with the same origin URL."
  fi

  DEFAULT_BRANCH="$(gh repo view "$TARGET_REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" \
    || die "could not query target repo $TARGET_REPO via gh"

  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
}

# ----------------------------------------------------------------- state I/O

# Writes the STATE_* globals to .git/repo-agent-bootstrap-state.sh.
save_state() {
  cat > "$TARGET_ROOT/$STATE_FILE" <<EOF
# Created by bin/onboard.sh setup; consumed by bin/onboard.sh finalize.
# Safe to delete (re-run setup to recreate). Lives in .git/ so it's never
# tracked and survives branch switches.
STATE_SCHEMA=1
STATE_MODE="$STATE_MODE"
STATE_BRANCH="$STATE_BRANCH"
STATE_TOOLING_REPO="$STATE_TOOLING_REPO"
STATE_TARGET_REPO="$STATE_TARGET_REPO"
STATE_DEFAULT_BRANCH="$STATE_DEFAULT_BRANCH"
STATE_WEEKLY="$STATE_WEEKLY"
STATE_CREATED_AT="$STATE_CREATED_AT"
EOF
}

# Loads state into STATE_* globals. Dies if missing.
load_state() {
  local path="$TARGET_ROOT/$STATE_FILE"
  [[ -f "$path" ]] || die "no state file at $path — did you run 'onboard.sh setup' first?
(If you ran setup in a different working tree, re-run setup here.)"
  # shellcheck disable=SC1090
  source "$path"
  [[ "${STATE_SCHEMA:-0}" == "1" ]] \
    || die "state file at $path uses an unknown schema (got '${STATE_SCHEMA:-}')"
}

# ----------------------------------------------------------------- staging helpers

# Copies a workflow file from examples/ with the `uses:` line rewritten to
# the detected tooling repo. If the destination already exists AND carries our
# `managed-by: repo-agent-bootstrap` sentinel in the first 40 lines, it's
# considered already-managed and we leave it alone (idempotent re-run). If it
# exists without the sentinel, we refuse to clobber (assume hand-edited).
drop_workflow() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]]; then
    if head -n 40 "$dst" 2>/dev/null | grep -q 'managed-by: repo-agent-bootstrap'; then
      info "kept existing $dst (already managed by repo-agent-bootstrap)"
      return 0
    fi
    die "would clobber existing $dst (no managed-by sentinel — looks hand-edited).
Delete the file first if you want to recreate it."
  fi
  cp "$src" "$dst"
  sed_inplace "s#uses: org/repo-agent-bootstrap#uses: $TOOLING_REPO#g" "$dst"
  info "staged $dst"
}

stage_keyless_workflow()      { drop_workflow "$TOOLING_ROOT/examples/caller-index-workflow.yml" "$KEYLESS_WORKFLOW_PATH"; }
stage_agent_sync_workflow()   { drop_workflow "$TOOLING_ROOT/examples/caller-agent-sync.yml"    "$AGENT_SYNC_WORKFLOW_PATH"; }
stage_ci_bootstrap_workflow() { drop_workflow "$TOOLING_ROOT/examples/caller-workflow.yml"       "$CI_BOOTSTRAP_WORKFLOW_PATH"; }
stage_weekly_workflow()       { drop_workflow "$TOOLING_ROOT/examples/caller-weekly-refresh.yml" "$CI_WEEKLY_WORKFLOW_PATH"; }

stage_bootstrap_agent() {
  mkdir -p "$(dirname "$STAGED_AGENT_PATH")"
  if [[ -e "$STAGED_AGENT_PATH" ]]; then
    if head -n 40 "$STAGED_AGENT_PATH" 2>/dev/null | grep -q 'managed-by: repo-agent-bootstrap'; then
      info "kept existing $STAGED_AGENT_PATH (already managed by repo-agent-bootstrap)"
      return 0
    fi
    die "would clobber existing $STAGED_AGENT_PATH (no managed-by sentinel — looks hand-edited).
Delete the file first if you want to recreate it."
  fi
  cp "$TOOLING_ROOT/agents/bootstrap.agent.md" "$STAGED_AGENT_PATH"
  # Pre-substitute env-var path references with the actual staged paths.
  # Copilot's agent runner does NOT expand $VARS in instruction prose — it
  # treats them as literal text, then falls back to a workspace file-name
  # search that can surface the canonical copy in the tooling repo (outside
  # the target repo). Baking the concrete paths in makes the staged agent
  # self-contained: every file it needs lives inside this target repo.
  sed_inplace "s#\\\$TEMPLATES_DIR#$STAGING_DIR/templates#g" "$STAGED_AGENT_PATH"
  sed_inplace "s#\\\$VOCAB_FILE#$STAGING_DIR/vocab/taxonomy-types.yaml#g" "$STAGED_AGENT_PATH"
  info "staged $STAGED_AGENT_PATH (Copilot's agent picker will discover it)"
}

stage_templates() {
  [[ -e "$STAGING_DIR" ]] \
    && die "would clobber existing $STAGING_DIR — delete it first if you want to recreate"
  mkdir -p "$STAGING_DIR"
  cp -R "$TOOLING_ROOT/templates" "$STAGING_DIR/templates"
  cp -R "$TOOLING_ROOT/vocab"     "$STAGING_DIR/vocab"
  # examples/ is needed because the bootstrap agent's Phase 5.8 reads
  # $TEMPLATES_DIR/../examples/caller-index-workflow.yml. Staging it
  # keeps every file the agent touches inside the target repo.
  cp -R "$TOOLING_ROOT/examples"  "$STAGING_DIR/examples"
  cat > "$STAGING_DIR/README-DO-NOT-COMMIT.md" <<'EOF'
# Staged by repo-agent-bootstrap (DO NOT COMMIT)

This directory holds the templates, vocabulary, and example workflows the
bootstrap agent reads during the local Copilot run. It is **automatically
deleted** by:

    bin/onboard.sh finalize

If you see this directory in a committed PR, something went wrong with the
finalize step — please remove it before merging.
EOF
  info "staged $STAGING_DIR/ (templates + vocab + examples)"
}

# ----------------------------------------------------------------- cmd_setup

cmd_setup() {
  local CI_BOOTSTRAP=false
  local WEEKLY=false
  local BRANCH="chore/setup-repo-agents"
  local TOOLING_OVERRIDE=""
  local ASSUME_YES=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ci-bootstrap|--with-bootstrap-workflow) CI_BOOTSTRAP=true ;;
      --weekly)         WEEKLY=true; CI_BOOTSTRAP=true ;;
      --branch)         BRANCH="${2:?--branch needs a value}"; shift ;;
      --tooling-repo)   TOOLING_OVERRIDE="${2:?--tooling-repo needs a value}"; shift ;;
      --yes|-y)         ASSUME_YES=true ;;
      --help|-h)        usage 0 ;;
      *)                die "unknown flag for setup: $1 (try '$0 --help')" ;;
    esac
    shift
  done

  do_preflight "$TOOLING_OVERRIDE"

  [[ -z "$(git status --porcelain)" ]] \
    || die "working tree has uncommitted changes — commit or stash first"

  if [[ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
    warn "you are on '$CURRENT_BRANCH', not the default branch '$DEFAULT_BRANCH'"
    warn "the script will branch from HEAD; if that's not what you want, abort and switch."
  fi

  [[ ! -f "$TARGET_ROOT/$STATE_FILE" ]] \
    || die "a previous setup is in progress (state file exists at $STATE_FILE).
Run '$0 finalize' to complete it, or 'rm $TARGET_ROOT/$STATE_FILE' to abandon."

  local mode="local-copilot"
  $CI_BOOTSTRAP && mode="ci-bootstrap"

  # Show plan.
  cat <<EOF

$(c_bold 'Plan')
  Mode:               $(c_bold "$mode")
  Target repo:        $(c_bold "$TARGET_REPO") (default branch: $DEFAULT_BRANCH)
  Tooling repo:       $(c_bold "$TOOLING_REPO")
  Feature branch:     $BRANCH

  Files to stage (NOT committed; finalize will commit):
EOF
  if $CI_BOOTSTRAP; then
    printf '    %s         (keyless — ctags + Python, on every push)\n' "$KEYLESS_WORKFLOW_PATH"
    printf '    %s    (LLM-driven, needs ANTHROPIC_API_KEY)\n'         "$CI_BOOTSTRAP_WORKFLOW_PATH"
    $WEEKLY && printf '    %s   (cron, LLM-driven)\n' "$CI_WEEKLY_WORKFLOW_PATH"
  else
    printf '    %s         (keyless — ctags + Python, on every push)\n' "$KEYLESS_WORKFLOW_PATH"
    printf '    %s      (bootstrap agent — Copilot picker will see it)\n' "$STAGED_AGENT_PATH"
    printf '    %s/            (templates + vocab; auto-cleaned at finalize)\n' "$STAGING_DIR"
  fi
  echo

  if ! $ASSUME_YES; then
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by user"
  fi

  # Branch creation (before any file writes, so failure leaves no orphan files).
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    die "branch '$BRANCH' already exists locally — delete it or use --branch <other>"
  fi
  if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    die "branch '$BRANCH' already exists on origin — delete it or use --branch <other>"
  fi

  info "creating branch: $BRANCH"
  git checkout -b "$BRANCH" >/dev/null

  # Drop files.
  mkdir -p .github/workflows
  stage_keyless_workflow
  stage_agent_sync_workflow

  if $CI_BOOTSTRAP; then
    stage_ci_bootstrap_workflow
    $WEEKLY && stage_weekly_workflow
  else
    stage_bootstrap_agent
    stage_templates
  fi

  # Persist state for finalize.
  STATE_MODE="$mode"
  STATE_BRANCH="$BRANCH"
  STATE_TOOLING_REPO="$TOOLING_REPO"
  STATE_TARGET_REPO="$TARGET_REPO"
  STATE_DEFAULT_BRANCH="$DEFAULT_BRANCH"
  STATE_WEEKLY="$($WEEKLY && echo true || echo false)"
  STATE_CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_state
  info "wrote state to $STATE_FILE"

  print_setup_next_steps "$mode"
}

print_setup_next_steps() {
  local mode="$1"
  local repo_owner repo_name
  repo_owner="${TARGET_REPO%/*}"
  repo_name="${TARGET_REPO#*/}"
  local repo_url="https://github.com/$TARGET_REPO"

  cat <<EOF

$(c_green '✓ Setup complete') (no commits yet)

Branch:           $STATE_BRANCH
Tooling repo:     $TOOLING_REPO
State file:       $STATE_FILE

Also staged:
  $AGENT_SYNC_WORKFLOW_PATH   (deterministic, zero-LLM refresh from $TOOLING_REPO@v1)
EOF

  if [[ "$mode" == "local-copilot" ]]; then
    cat <<EOF
$(c_bold 'Next steps — local Copilot bootstrap')

  1. Open this repo in VS Code (if not already).
  2. Open Copilot chat and switch to $(c_bold 'agent mode').
  3. From the agent picker, select $(c_bold 'bootstrap').
       (It was just staged at $STAGED_AGENT_PATH.)
  4. Paste this prompt verbatim and send it:

       Bootstrap this repo using these inputs:
         BOOTSTRAP_MODE   = full
         FORCE_OVERWRITE  = false
         TEMPLATES_DIR    = $STAGING_DIR/templates
         VOCAB_FILE       = $STAGING_DIR/vocab/taxonomy-types.yaml
         REPO_NAME        = $repo_name
         REPO_OWNER       = $repo_owner
         REPO_URL         = $repo_url

       Follow the procedure in your own instructions exactly.
       Write all generated files. Do not commit. Do not modify source code.

  5. Wait for the agent to finish writing artifacts (repo-index.md,
     taxonomy.yaml, docs-manifest.yaml, .github/agents/*.agent.md,
     .github/instructions/*.instructions.md, .github/copilot-instructions.md).
  6. Review the generated artifacts in your file tree / SCM view.
  7. When happy, run:

       $0 finalize

     That will:
       - delete $STAGING_DIR/                       (staged templates/vocab)
       - delete $STAGED_AGENT_PATH    (the bootstrap agent itself)
       - git add -A → commit → push → open a draft PR

  $(c_yellow 'IMPORTANT:') do NOT git-commit anything by hand between now and finalize.
              Finalize takes care of staging the right paths for you.

EOF
  else
    cat <<EOF
$(c_bold 'Next steps — CI bootstrap')

  1. Review the staged workflow files in your file tree.
  2. Run:

       $0 finalize

     That will:
       - git add -A → commit → push → open a draft PR
       - prompt for ANTHROPIC_API_KEY and set it as a repo secret
       - set workflow permissions (contents:write, can-create-PRs:true)

  3. After the PR is merged, trigger the first bootstrap run:
       $repo_url/actions/workflows/$(basename "$CI_BOOTSTRAP_WORKFLOW_PATH")
       → Run workflow → mode: full → Run workflow
EOF
    if [[ "$STATE_WEEKLY" == "true" ]]; then
      printf '\n  4. The weekly refresh runs every Monday at 08:00 UTC.\n'
    fi
  fi

  cat <<EOF

To abandon this setup without committing:
  git checkout $DEFAULT_BRANCH
  git branch -D $STATE_BRANCH
  rm -rf $STAGING_DIR $STAGED_AGENT_PATH \\
         $KEYLESS_WORKFLOW_PATH $AGENT_SYNC_WORKFLOW_PATH \\
         $CI_BOOTSTRAP_WORKFLOW_PATH $CI_WEEKLY_WORKFLOW_PATH 2>/dev/null || true
  rm -f $STATE_FILE

EOF
}

# ----------------------------------------------------------------- cmd_finalize

cmd_finalize() {
  local OPEN_PR=true
  local SKIP_SECRET=false
  local SKIP_PERMS=false
  local KEEP_STAGED=false
  local ASSUME_YES=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-pr)         OPEN_PR=false ;;
      --skip-secret)   SKIP_SECRET=true ;;
      --skip-perms)    SKIP_PERMS=true ;;
      --keep-staged)   KEEP_STAGED=true ;;
      --yes|-y)        ASSUME_YES=true ;;
      --help|-h)       usage 0 ;;
      *)               die "unknown flag for finalize: $1 (try '$0 --help')" ;;
    esac
    shift
  done

  # Need TARGET_ROOT before load_state. Quick lookup; full preflight runs next.
  TARGET_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "current directory is not a git repo"
  load_state

  do_preflight "$STATE_TOOLING_REPO"

  # Sanity: state should match what we re-detected.
  [[ "$TARGET_REPO" == "$STATE_TARGET_REPO" ]] \
    || die "target repo mismatch — state says '$STATE_TARGET_REPO', detected '$TARGET_REPO' (cwd or remote changed?)"

  if [[ "$CURRENT_BRANCH" != "$STATE_BRANCH" ]]; then
    warn "you are on '$CURRENT_BRANCH', state expected '$STATE_BRANCH'"
    if ! $ASSUME_YES; then
      read -r -p "Continue from current branch? [y/N] " ans
      [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by user"
    fi
  fi

  # Local-Copilot mode: warn (don't fail) if expected artifacts are missing.
  [[ "$STATE_MODE" == "local-copilot" ]] && finalize_local_copilot_preflight

  cat <<EOF

$(c_bold 'Finalize plan')
  Mode:                       $STATE_MODE
  Branch:                     $STATE_BRANCH
  Open draft PR:              $OPEN_PR
EOF
  if [[ "$STATE_MODE" == "ci-bootstrap" ]]; then
    printf '  Set ANTHROPIC_API_KEY:      %s\n' "$([ "$SKIP_SECRET" = true ] && echo no || echo yes)"
  fi
  printf '  Adjust workflow perms:      %s\n' "$([ "$SKIP_PERMS"  = true ] && echo no || echo yes)"
  if [[ "$STATE_MODE" == "local-copilot" ]]; then
    printf '  Delete staged templates:    %s\n' "$([ "$KEEP_STAGED" = true ] && echo no || echo yes)"
    printf '  Delete bootstrap agent:     %s\n' "$([ "$KEEP_STAGED" = true ] && echo no || echo yes)"
  fi
  echo

  if ! $ASSUME_YES; then
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by user"
  fi

  # CI-bootstrap mode: capture API key BEFORE we start changing things.
  local API_KEY=""
  if [[ "$STATE_MODE" == "ci-bootstrap" && "$SKIP_SECRET" != "true" ]]; then
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
      API_KEY="$ANTHROPIC_API_KEY"
      info "using ANTHROPIC_API_KEY from environment"
    else
      printf '%s ' "$(c_bold 'Anthropic API key (input hidden):')" >&2
      IFS= read -rs API_KEY
      printf '\n' >&2
      [[ -n "$API_KEY" ]] || die "API key cannot be empty (or re-run with --skip-secret)"
    fi
  fi

  # Cleanup staged files (local-Copilot only).
  if [[ "$STATE_MODE" == "local-copilot" && "$KEEP_STAGED" != "true" ]]; then
    if [[ -d "$STAGING_DIR" ]]; then
      rm -rf "$STAGING_DIR"
      info "removed $STAGING_DIR/"
      # Clean up empty parent 'tmp/' if we created it solely for staging.
      rmdir tmp 2>/dev/null || true
    fi
    if [[ -f "$STAGED_AGENT_PATH" ]]; then
      rm -f "$STAGED_AGENT_PATH"
      info "removed $STAGED_AGENT_PATH"
    fi
  fi

  # Stage + commit.
  git add -A
  if git diff --cached --quiet; then
    die "nothing to commit — did the bootstrap agent run? did setup succeed?"
  fi

  local COMMIT_MSG="ci: enable repo-agent-bootstrap workflows"
  [[ "$STATE_MODE" == "local-copilot" ]] && COMMIT_MSG="ci: bootstrap repo agents + indices"
  git -c user.useConfigOnly=false commit -m "$COMMIT_MSG" >/dev/null
  info "committed: $COMMIT_MSG"

  info "pushing branch to origin"
  git push --set-upstream origin "$STATE_BRANCH" >/dev/null

  # Open PR.
  local PR_URL=""
  if $OPEN_PR; then
    info "opening draft pull request"
    PR_URL="$(open_pr)" || die "gh pr create failed (see error above)"
    info "PR opened: $PR_URL"
  fi

  # Set secret (CI-bootstrap mode only).
  if [[ "$STATE_MODE" == "ci-bootstrap" && "$SKIP_SECRET" != "true" ]]; then
    info "setting ANTHROPIC_API_KEY secret on $TARGET_REPO"
    printf '%s' "$API_KEY" | gh secret set ANTHROPIC_API_KEY --repo "$TARGET_REPO" >/dev/null
    info "secret set"
    unset API_KEY
  fi

  # Workflow permissions.
  if ! $SKIP_PERMS; then
    info "setting workflow permissions (contents:write, can-create-PRs:true)"
    if gh api \
         -X PUT "/repos/$TARGET_REPO/actions/permissions/workflow" \
         -F default_workflow_permissions=write \
         -F can_approve_pull_request_reviews=true \
         >/dev/null 2>&1
    then
      info "workflow permissions updated"
    else
      warn "could not update workflow permissions automatically — most likely a repo-admin issue"
      warn "set them manually at:"
      warn "  https://github.com/$TARGET_REPO/settings/actions"
      warn "  -> Workflow permissions: 'Read and write permissions'"
      warn "  -> Check 'Allow GitHub Actions to create and approve pull requests'"
    fi
  fi

  # Remove state file (success path only — keep on failure for debugging).
  rm -f "$TARGET_ROOT/$STATE_FILE"

  print_finalize_next_steps "$PR_URL"
}

finalize_local_copilot_preflight() {
  # Expected generated artifacts (per agents/bootstrap.agent.md Phase 5).
  local missing=()
  [[ -f "site/content/repo-index.md" ]]      || missing+=("site/content/repo-index.md")
  [[ -f "taxonomy.yaml" ]]                   || missing+=("taxonomy.yaml")
  [[ -f ".github/copilot-instructions.md" ]] || missing+=(".github/copilot-instructions.md")

  # Coordinator agent: any *.agent.md under .github/agents/ other than bootstrap.
  local has_coordinator=false f
  if compgen -G ".github/agents/*.agent.md" >/dev/null; then
    for f in .github/agents/*.agent.md; do
      [[ "$f" == "$STAGED_AGENT_PATH" ]] && continue
      has_coordinator=true
      break
    done
  fi
  $has_coordinator || missing+=(".github/agents/<coordinator>.agent.md")

  if (( ${#missing[@]} > 0 )); then
    warn "expected generated artifacts not found:"
    for f in "${missing[@]}"; do warn "  - $f"; done
    warn "did the bootstrap agent finish successfully?"
    warn "(re-run the Copilot agent, or pass --keep-staged to skip cleanup and inspect)"
  fi
}

# Returns the PR URL on stdout. Writes gh error output to stderr on failure.
open_pr() {
  local body title
  if [[ "$STATE_MODE" == "ci-bootstrap" ]]; then
    body="$(ci_pr_body)"
    title="ci: enable repo-agent-bootstrap workflows"
  else
    body="$(local_copilot_pr_body)"
    title="ci: bootstrap repo agents + indices"
  fi

  # NOTE: deliberately no --label here. Labels would need to already exist on
  # the target repo, and a missing label causes the entire gh pr create to fail.
  # Apply labels post-hoc with `gh pr edit` if you want them.
  local out
  if ! out="$(gh pr create \
                --repo "$TARGET_REPO" \
                --base "$STATE_DEFAULT_BRANCH" \
                --head "$STATE_BRANCH" \
                --draft \
                --title "$title" \
                --body "$body" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  # On success, the URL is the last line of stdout/stderr combined.
  printf '%s\n' "$out" | tail -1
}

ci_pr_body() {
  cat <<EOM
Adds GitHub Actions workflow(s) that wire this repo into the
\`$TOOLING_REPO\` agent + index automation.

**What this PR adds:**

- \`.github/workflows/agent-index.yml\` — auto-runs on every push to \`$STATE_DEFAULT_BRANCH\`; regenerates \`.agent-index/symbols.json\` + \`.agent-index/logs.json\` using \`universal-ctags\` + a Python log extractor. Deterministic, **no LLM, no secrets needed**.
- \`.github/workflows/bootstrap-agents.yml\` — manual trigger; runs the LLM-driven bootstrap that generates \`site/content/repo-index.md\`, \`taxonomy.yaml\`, agent files, and language-specific review instructions. Requires the \`ANTHROPIC_API_KEY\` repo secret.
$([ "$STATE_WEEKLY" = "true" ] && echo '- `.github/workflows/repo-index-weekly.yml` — cron-runs every Monday at 08:00 UTC; refreshes `repo-index.md` only.')

**After merging this PR:**

1. Manually trigger \`Bootstrap agents\` (Actions tab → Run workflow → mode \`full\`) to produce the first batch of agent files and the curated repo index. That run will open another draft PR for you to review.
2. \`Build agent index\` will start running on every push to \`$STATE_DEFAULT_BRANCH\` automatically.

This PR was opened by \`bin/onboard.sh finalize\` (mode: ci-bootstrap).
EOM
}

local_copilot_pr_body() {
  cat <<EOM
Bootstraps repo-specific Copilot agents and indices, generated locally via
the \`$TOOLING_REPO\` bootstrap agent in VS Code Copilot.

**What this PR adds:**

- \`site/content/repo-index.md\` — curated subsystem map (entry point for downstream agent calls).
- \`taxonomy.yaml\` + \`docs-manifest.yaml\` — typed identifier registry + doc index.
- \`.github/agents/*.agent.md\` — repo coordinator + generic sub-agents.
- \`.github/instructions/*.instructions.md\` — language-specific review rules (only for languages actually present).
- \`.github/copilot-instructions.md\` — short pointer file with the Repository Overview filled in.
- \`.github/workflows/agent-index.yml\` — keyless layer-2 indexer (\`universal-ctags\` + Python log extractor). Runs on every push to \`$STATE_DEFAULT_BRANCH\`.
- \`.agent-index/.gitkeep\` — placeholder so the layer-2 workflow has a target dir on first push.

**After merging this PR:**

1. \`Build agent index\` will run on every push to \`$STATE_DEFAULT_BRANCH\` and commit \`.agent-index/*.json\` back to main. No LLM, no secrets, no cost.
2. Downstream Copilot agents in this repo will use \`repo-index.md\` + the layer-2 JSON to answer questions cheaply.

This PR was opened by \`bin/onboard.sh finalize\` (mode: local-copilot).
EOM
}

print_finalize_next_steps() {
  local pr_url="$1"
  cat <<EOF

$(c_green '✓ Finalize complete')

Target repo:    $TARGET_REPO
Branch:         $STATE_BRANCH
EOF
  [[ -n "$pr_url" ]] && printf 'Draft PR:       %s\n' "$pr_url"

  if [[ "$STATE_MODE" == "ci-bootstrap" ]]; then
    cat <<EOF

$(c_bold 'Next steps')

  1. Review and merge the PR above.
  2. Trigger the first bootstrap run:
       https://github.com/$TARGET_REPO/actions/workflows/$(basename "$CI_BOOTSTRAP_WORKFLOW_PATH")
       → Run workflow → mode: full → Run workflow

     That run will open a SECOND draft PR with the generated agent files,
     repo-index.md, taxonomy.yaml, etc. Review and merge that one too.

$(c_bold 'If your org locks third-party Actions')

  Ask your org admin to allow these (one-time, one-line each):
    - anthropics/claude-code-action@v1
    - peter-evans/create-pull-request@v6

EOF
  else
    cat <<EOF

$(c_bold 'Next steps')

  1. Review and merge the PR above.
  2. After merge, $(c_bold 'agent-index.yml') will run on every push to $STATE_DEFAULT_BRANCH
     and commit .agent-index/*.json back to main. No LLM, no secrets, no cost.
  3. Downstream agents in this repo will now use the curated repo-index.md
     plus the deterministic symbol/log indices.

EOF
  fi
}

# ----------------------------------------------------------------- dispatch

case "${1:-}" in
  setup)           shift; cmd_setup    "$@" ;;
  finalize)        shift; cmd_finalize "$@" ;;
  -h|--help|help)  usage 0 ;;
  "")              usage 1 ;;
  *)               die "unknown sub-command: $1 (try '$0 --help')" ;;
esac
