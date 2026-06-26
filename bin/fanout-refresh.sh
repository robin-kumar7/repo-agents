#!/usr/bin/env bash
# fanout-refresh.sh — trigger a refresh across many target repos at once.
#
# Two flavours, controlled by --workflow:
#
#   --workflow agent-sync.yml     (DEFAULT — deterministic, $0 LLM cost)
#     Triggers the static-artifact sync workflow in each target repo. Each
#     target opens a draft PR only if the tooling repo's templates have
#     moved relative to what is currently committed. Use this for the
#     common case: you shipped a new sub-agent template or a coordinator
#     tweak in the tooling repo and re-pointed the v1 tag.
#
#   --workflow bootstrap-agents.yml
#     Triggers the LLM-driven bootstrap workflow in each target repo. Use
#     this when you need a content-level regeneration (repo-index.md,
#     taxonomy.yaml, docs-manifest.yaml). This is rare and costs tokens
#     per repo — confirm with --dry-run first.
#
# This script does NOT propagate reusable-workflow changes — those propagate
# automatically the moment you re-point the v1 tag (see README "Update
# propagation"). You only need this script when:
#   (B) you changed templates/sub-agents/coordinator template → use
#       --workflow agent-sync.yml (default).
#   (C) you want the LLM to regenerate per-repo content → use
#       --workflow bootstrap-agents.yml --mode <m>.
#
# Requirements in each target repo (per workflow):
#   agent-sync.yml         → .github/workflows/agent-sync.yml present.
#                            No secret required.
#   bootstrap-agents.yml   → .github/workflows/bootstrap-agents.yml present
#                            AND ANTHROPIC_API_KEY repo secret set.
#
# Usage:
#   # Deterministic refresh of 15 repos at the v1 tag:
#   bin/fanout-refresh.sh --repos-file repos.txt --templates-ref v1
#
#   # LLM regeneration of agents-only across 3 repos:
#   bin/fanout-refresh.sh \
#     --repos org/repo1,org/repo2,org/repo3 \
#     --workflow bootstrap-agents.yml \
#     --mode agents-only \
#     --templates-ref v1
#
# Flags:
#   --repos <csv>           comma-separated owner/name list (mutually exclusive with --repos-file)
#   --repos-file <path>     newline-delimited owner/name file
#   --workflow <name>       caller workflow filename in each target repo
#                           (default: agent-sync.yml; alternative: bootstrap-agents.yml)
#   --templates-ref <ref>   git ref of repo-agent-bootstrap to render from (default: v1)
#   --mode <m>              full | refresh | repo-index-only | agents-only
#                           (ONLY honoured for --workflow bootstrap-agents.yml; default: refresh)
#   --force-overwrite       pass force_overwrite=true
#                           (ONLY honoured for --workflow bootstrap-agents.yml; default: false)
#   --dry-run               print what would run; do not call gh
#   --concurrency <n>       max parallel triggers (default: 1; bump cautiously)
#   --yes / -y              skip the confirmation prompt
#   --help / -h             print this help

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: this script must be run with bash, not sh." >&2
  exit 1
fi

set -euo pipefail
IFS=$'\n\t'
export GH_PAGER=cat

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }

info() { printf '%s %s\n' "$(c_green '==>')" "$*"; }
warn() { printf '%s %s\n' "$(c_yellow 'warn:')" "$*" >&2; }
die()  { printf '%s %s\n' "$(c_red 'error:')" "$*" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit "${1:-0}"; }

REPOS_CSV=""
REPOS_FILE=""
MODE="refresh"
TEMPLATES_REF="v1"
FORCE_OVERWRITE="false"
WORKFLOW="agent-sync.yml"
DRY_RUN=false
CONCURRENCY=1
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos)            REPOS_CSV="${2:?--repos needs a value}"; shift ;;
    --repos-file)       REPOS_FILE="${2:?--repos-file needs a value}"; shift ;;
    --mode)             MODE="${2:?--mode needs a value}"; shift ;;
    --templates-ref)    TEMPLATES_REF="${2:?--templates-ref needs a value}"; shift ;;
    --force-overwrite)  FORCE_OVERWRITE="true" ;;
    --workflow)         WORKFLOW="${2:?--workflow needs a value}"; shift ;;
    --dry-run)          DRY_RUN=true ;;
    --concurrency)      CONCURRENCY="${2:?--concurrency needs a value}"; shift ;;
    --yes|-y)           ASSUME_YES=true ;;
    --help|-h)          usage 0 ;;
    *)                  die "unknown flag: $1 (try '$0 --help')" ;;
  esac
  shift
done

command -v gh >/dev/null || die "gh (GitHub CLI) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

case "$MODE" in
  full|refresh|repo-index-only|agents-only) ;;
  *) die "invalid --mode: $MODE (use one of: full | refresh | repo-index-only | agents-only)" ;;
esac

[[ "$CONCURRENCY" =~ ^[0-9]+$ && "$CONCURRENCY" -ge 1 ]] \
  || die "--concurrency must be a positive integer, got: $CONCURRENCY"

# Decide which input shape to use based on WORKFLOW. agent-sync takes only
# templates_ref; bootstrap-agents takes mode + templates_ref + force_overwrite.
case "$WORKFLOW" in
  agent-sync.yml)
    WORKFLOW_KIND="agent-sync"
    ;;
  bootstrap-agents.yml)
    WORKFLOW_KIND="bootstrap-agents"
    ;;
  *)
    # Unknown workflow — assume it takes the bootstrap-agents input shape
    # (mode + templates_ref + force_overwrite). The user can adjust if needed.
    warn "unknown --workflow '$WORKFLOW' — assuming bootstrap-agents-style inputs"
    WORKFLOW_KIND="bootstrap-agents"
    ;;
esac

# Build REPOS array.
declare -a REPOS=()
if [[ -n "$REPOS_CSV" && -n "$REPOS_FILE" ]]; then
  die "pass either --repos or --repos-file, not both"
fi
if [[ -n "$REPOS_CSV" ]]; then
  IFS=',' read -ra REPOS <<< "$REPOS_CSV"
elif [[ -n "$REPOS_FILE" ]]; then
  [[ -f "$REPOS_FILE" ]] || die "no such file: $REPOS_FILE"
  while IFS= read -r line; do
    line="${line%%#*}"               # strip comments
    line="${line//[[:space:]]/}"     # strip whitespace
    [[ -z "$line" ]] && continue
    REPOS+=("$line")
  done < "$REPOS_FILE"
else
  die "must pass --repos <csv> or --repos-file <path>"
fi

(( ${#REPOS[@]} > 0 )) || die "no repos to refresh"

# Validate owner/name shape.
for r in "${REPOS[@]}"; do
  [[ "$r" == */* ]] || die "repo must be 'owner/name', got: $r"
done

cat <<EOF

$(c_bold 'Fan-out refresh plan')
  Workflow:           .github/workflows/$WORKFLOW  ($WORKFLOW_KIND)
  Templates ref:      $TEMPLATES_REF
EOF
if [[ "$WORKFLOW_KIND" == "bootstrap-agents" ]]; then
  cat <<EOF
  Mode:               $MODE
  Force overwrite:    $FORCE_OVERWRITE
EOF
fi
cat <<EOF
  Concurrency:        $CONCURRENCY
  Dry run:            $DRY_RUN
  Repos (${#REPOS[@]}):
EOF
for r in "${REPOS[@]}"; do printf '    - %s\n' "$r"; done
echo

if ! $ASSUME_YES; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by user"
fi

# Per-repo trigger. Captures success/failure into arrays so we can print a
# summary at the end and exit non-zero if any failed.
declare -a OK_REPOS=()
declare -a FAILED_REPOS=()

trigger_one() {
  local repo="$1"
  local -a gh_args=(workflow run "$WORKFLOW" --repo "$repo" -f "templates_ref=$TEMPLATES_REF")
  if [[ "$WORKFLOW_KIND" == "bootstrap-agents" ]]; then
    gh_args+=(-f "mode=$MODE" -f "force_overwrite=$FORCE_OVERWRITE")
  fi
  if $DRY_RUN; then
    info "[dry-run] gh ${gh_args[*]}"
    OK_REPOS+=("$repo")
    return 0
  fi
  # Verify the workflow exists in the target repo first so we get a clean
  # error rather than "Resource not accessible by integration".
  if ! gh workflow view "$WORKFLOW" --repo "$repo" >/dev/null 2>&1; then
    warn "$repo: workflow .github/workflows/$WORKFLOW not found — skipping"
    FAILED_REPOS+=("$repo (no workflow)")
    return 1
  fi
  if gh "${gh_args[@]}" >/dev/null 2>&1; then
    info "triggered: $repo"
    OK_REPOS+=("$repo")
    return 0
  else
    warn "$repo: gh workflow run failed"
    FAILED_REPOS+=("$repo (trigger failed)")
    return 1
  fi
}

# Concurrency = 1: simple serial loop.
# Concurrency > 1: background each call and wait. Cap with a tiny semaphore.
if [[ "$CONCURRENCY" -eq 1 ]]; then
  for r in "${REPOS[@]}"; do
    trigger_one "$r" || true
  done
else
  # Tiny semaphore using a FIFO. Avoids needing GNU parallel.
  FIFO="$(mktemp -u)"; mkfifo "$FIFO"
  exec 3<>"$FIFO"; rm -f "$FIFO"
  for ((i=0; i<CONCURRENCY; i++)); do printf '\n' >&3; done
  for r in "${REPOS[@]}"; do
    read -r -u 3
    {
      trigger_one "$r" || true
      printf '\n' >&3
    } &
  done
  wait
  exec 3<&-
fi

echo
printf '%s\n' "$(c_bold 'Summary')"
printf '  Triggered: %d\n' "${#OK_REPOS[@]}"
printf '  Failed:    %d\n' "${#FAILED_REPOS[@]}"
if (( ${#FAILED_REPOS[@]} > 0 )); then
  echo
  printf '%s\n' "$(c_yellow 'Failures:')"
  for f in "${FAILED_REPOS[@]}"; do printf '  - %s\n' "$f"; done
  echo
  printf 'Each successful trigger queues a workflow run that will open a draft PR.\n'
  printf 'Watch progress at:  https://github.com/<owner>/<repo>/actions/workflows/%s\n' "$WORKFLOW"
  exit 1
fi

cat <<EOF

$(c_green '✓ Fan-out complete')

Each successful trigger queues a workflow run in the target repo. The run
will open a draft PR with the regenerated files (only if anything actually
changed — the sentinel-aware writer skips unchanged content).

Watch progress per repo at:
  https://github.com/<owner>/<repo>/actions/workflows/$WORKFLOW

EOF
