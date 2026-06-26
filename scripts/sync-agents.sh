#!/usr/bin/env bash
# sync-agents.sh — deterministic refresh of repo-agent-bootstrap artifacts.
#
# Called from the agent-sync.yml reusable workflow in a target repo. Copies
# the static parts of the bootstrap output (sub-agents, instructions, layer-2
# workflow) verbatim from a checked-out tooling repo into the target repo's
# working tree. Re-renders the coordinator agent if .bootstrap-metadata.yaml
# is present.
#
# NO LLM. Pure file copy + sentinel-aware skip. Safe to run on a cron.
#
# Usage:
#   bash scripts/sync-agents.sh <tooling-dir> <target-dir> [--dry-run]
#
# Arguments:
#   tooling-dir   Path to a checked-out repo-agent-bootstrap (any ref).
#   target-dir    Path to the target repo's working tree (usually ".").
#
# Flags:
#   --dry-run     Print what would change; touch nothing.
#
# Exit codes:
#   0   no changes (target already in sync)
#   1   error
#   2   changes applied (or would be applied in dry-run mode) — used by the
#       workflow to decide whether to open a PR.
#
# Rules:
#   - Files lacking the `managed-by: repo-agent-bootstrap` sentinel in their
#     first 40 lines are NEVER overwritten — they're user-managed.
#   - Files that exist and ARE managed are overwritten only if the content
#     differs (cmp -s); a no-op copy doesn't get reported.
#   - New files (no destination) are always created.
#   - Removed files in the tooling repo are NOT deleted in the target repo —
#     too destructive for an auto-sync. Listed as a warning instead.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: this script must be run with bash, not sh." >&2
  exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------- args

DRY_RUN=false
TOOLING_DIR=""
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$TOOLING_DIR" ]]; then
        TOOLING_DIR="$1"
      elif [[ -z "$TARGET_DIR" ]]; then
        TARGET_DIR="$1"
      else
        echo "error: too many positional arguments: $1" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

[[ -n "$TOOLING_DIR" ]] || { echo "error: tooling-dir argument required" >&2; exit 1; }
[[ -n "$TARGET_DIR"  ]] || { echo "error: target-dir argument required" >&2; exit 1; }
[[ -d "$TOOLING_DIR" ]] || { echo "error: tooling-dir not a directory: $TOOLING_DIR" >&2; exit 1; }
[[ -d "$TARGET_DIR"  ]] || { echo "error: target-dir not a directory: $TARGET_DIR" >&2; exit 1; }

# Canonicalise.
TOOLING_DIR="$(cd "$TOOLING_DIR" && pwd -P)"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"

cd "$TARGET_DIR"

# ----------------------------------------------------------------- helpers

# Tracking arrays (counted at the end; used as the sole signal of whether
# anything actually changed).
CREATED=()
UPDATED=()
SKIPPED_USER_MANAGED=()
UNCHANGED=()
REMOVED_IN_TOOLING=()

SENTINEL='managed-by: repo-agent-bootstrap'

is_managed() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  head -n 40 "$f" 2>/dev/null | grep -q "$SENTINEL"
}

copy_one() {
  local src="$1" dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"

  if [[ ! -e "$dst" ]]; then
    CREATED+=("$dst")
    if ! $DRY_RUN; then
      mkdir -p "$dst_dir"
      cp "$src" "$dst"
    fi
    return 0
  fi

  if ! is_managed "$dst"; then
    SKIPPED_USER_MANAGED+=("$dst")
    return 0
  fi

  if cmp -s "$src" "$dst"; then
    UNCHANGED+=("$dst")
    return 0
  fi

  UPDATED+=("$dst")
  if ! $DRY_RUN; then
    cp "$src" "$dst"
  fi
}

# Loop a source directory and mirror it into the target. dst_dir is created
# on demand. Only files matching the glob are considered. Files present in
# the target but missing from the source are reported under REMOVED_IN_TOOLING.
mirror_dir() {
  local src_dir="$1" dst_dir="$2" glob="$3"
  [[ -d "$src_dir" ]] || return 0

  local src dst basename
  for src in "$src_dir"/$glob; do
    [[ -e "$src" ]] || continue   # unmatched glob
    basename="$(basename "$src")"
    dst="$dst_dir/$basename"
    copy_one "$src" "$dst"
  done

  # Detect tooling-side removals.
  if [[ -d "$dst_dir" ]]; then
    for dst in "$dst_dir"/$glob; do
      [[ -e "$dst" ]] || continue
      basename="$(basename "$dst")"
      src="$src_dir/$basename"
      if [[ ! -e "$src" ]] && is_managed "$dst"; then
        REMOVED_IN_TOOLING+=("$dst")
      fi
    done
  fi
}

# ----------------------------------------------------------------- sync work

# 1. Sub-agents — copied verbatim into .github/agents/.
mirror_dir \
  "$TOOLING_DIR/templates/sub-agents" \
  ".github/agents" \
  "*.agent.md"

# 2. Language / domain instructions — copied verbatim into .github/instructions/.
mirror_dir \
  "$TOOLING_DIR/templates/instructions" \
  ".github/instructions" \
  "*.instructions.md"

# 3. Layer-2 keyless workflow — its caller is per-target (it points at the
# tooling repo). Rewrite the `uses:` line before copying.
sync_caller_workflow() {
  local src="$TOOLING_DIR/examples/caller-index-workflow.yml"
  local dst=".github/workflows/agent-index.yml"
  [[ -f "$src" ]] || return 0

  # Compute the tooling repo identity from $GITHUB_REPOSITORY when running
  # inside Actions; otherwise from the tooling dir's git origin.
  local tooling_repo=""
  if [[ -n "${GITHUB_AGENT_SYNC_TOOLING_REPO:-}" ]]; then
    tooling_repo="$GITHUB_AGENT_SYNC_TOOLING_REPO"
  else
    tooling_repo="$(git -C "$TOOLING_DIR" remote get-url origin 2>/dev/null \
      | sed -E 's#^.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" || true
  fi

  if [[ -z "$tooling_repo" ]]; then
    echo "warn: could not resolve tooling repo identity for agent-index.yml — skipping" >&2
    return 0
  fi

  # Render to a temp file, then funnel through copy_one for the standard
  # sentinel-aware compare.
  local tmp
  tmp="$(mktemp)"
  sed "s#uses: org/repo-agent-bootstrap#uses: $tooling_repo#g" "$src" > "$tmp"
  copy_one "$tmp" "$dst"
  rm -f "$tmp"
}
sync_caller_workflow

# 4. Coordinator agent — re-rendered from the template using metadata captured
# at initial-bootstrap time. Only runs if .bootstrap-metadata.yaml exists.
sync_coordinator() {
  local meta=".github/agents/.bootstrap-metadata.yaml"
  local tmpl="$TOOLING_DIR/templates/coordinator.agent.md.tmpl"

  if [[ ! -f "$meta" ]]; then
    echo "info: no $meta — skipping coordinator re-render (was this repo bootstrapped before agent-sync existed?)" >&2
    return 0
  fi
  if [[ ! -f "$tmpl" ]]; then
    echo "warn: no coordinator template at $tmpl — skipping" >&2
    return 0
  fi

  # Extract placeholder values. The metadata file is intentionally a flat
  # key: value YAML so we don't need a YAML parser at runtime.
  local repo_name repo_one_liner primary_language deployment_target peer_services
  local tier_small tier_medium tier_large tier_medium_inline
  repo_name="$(awk -F': ' '/^REPO_NAME:/ {print $2; exit}' "$meta" | tr -d '"')"
  repo_one_liner="$(awk -F': ' '/^REPO_ONE_LINER:/ {sub(/^[^:]+: /, ""); print; exit}' "$meta" | sed 's/^"//; s/"$//')"
  primary_language="$(awk -F': ' '/^PRIMARY_LANGUAGE:/ {print $2; exit}' "$meta" | tr -d '"')"
  deployment_target="$(awk -F': ' '/^DEPLOYMENT_TARGET:/ {print $2; exit}' "$meta" | tr -d '"')"
  peer_services="$(awk -F': ' '/^PEER_SERVICES:/ {sub(/^[^:]+: /, ""); print; exit}' "$meta" | sed 's/^"//; s/"$//')"
  tier_small="$(awk -F': ' '/^TIER_SMALL_EXAMPLES:/ {sub(/^[^:]+: /, ""); print; exit}' "$meta" | sed 's/^"//; s/"$//')"
  tier_medium="$(awk -F': ' '/^TIER_MEDIUM_EXAMPLES:/ {sub(/^[^:]+: /, ""); print; exit}' "$meta" | sed 's/^"//; s/"$//')"
  tier_large="$(awk -F': ' '/^TIER_LARGE_EXAMPLES:/ {sub(/^[^:]+: /, ""); print; exit}' "$meta" | sed 's/^"//; s/"$//')"
  tier_medium_inline="$(awk -F': ' '/^TIER_MEDIUM_EXAMPLES_INLINE:/ {sub(/^[^:]+: /, ""); print; exit}' "$meta" | sed 's/^"//; s/"$//')"

  if [[ -z "$repo_name" ]]; then
    echo "warn: $meta missing REPO_NAME — skipping coordinator re-render" >&2
    return 0
  fi

  local dst=".github/agents/${repo_name}.agent.md"
  local tmp
  tmp="$(mktemp)"

  # Plain sed substitution. Use a # delimiter to avoid clashing with / in
  # values; escape # in values to be safe.
  local esc_repo_name esc_one_liner esc_lang esc_deploy esc_peers
  local esc_small esc_medium esc_large esc_medium_inline
  esc_repo_name="$(printf '%s' "$repo_name"          | sed 's/[#&\\]/\\&/g')"
  esc_one_liner="$(printf '%s' "$repo_one_liner"     | sed 's/[#&\\]/\\&/g')"
  esc_lang="$(printf '%s' "$primary_language"        | sed 's/[#&\\]/\\&/g')"
  esc_deploy="$(printf '%s' "$deployment_target"     | sed 's/[#&\\]/\\&/g')"
  esc_peers="$(printf '%s' "$peer_services"          | sed 's/[#&\\]/\\&/g')"
  esc_small="$(printf '%s' "$tier_small"             | sed 's/[#&\\]/\\&/g')"
  esc_medium="$(printf '%s' "$tier_medium"           | sed 's/[#&\\]/\\&/g')"
  esc_large="$(printf '%s' "$tier_large"             | sed 's/[#&\\]/\\&/g')"
  esc_medium_inline="$(printf '%s' "$tier_medium_inline" | sed 's/[#&\\]/\\&/g')"

  sed \
    -e "s#{{REPO_NAME}}#${esc_repo_name}#g" \
    -e "s#{{REPO_ONE_LINER}}#${esc_one_liner}#g" \
    -e "s#{{PRIMARY_LANGUAGE}}#${esc_lang}#g" \
    -e "s#{{DEPLOYMENT_TARGET}}#${esc_deploy}#g" \
    -e "s#{{PEER_SERVICES}}#${esc_peers}#g" \
    -e "s#{{TIER_SMALL_EXAMPLES}}#${esc_small}#g" \
    -e "s#{{TIER_MEDIUM_EXAMPLES}}#${esc_medium}#g" \
    -e "s#{{TIER_LARGE_EXAMPLES}}#${esc_large}#g" \
    -e "s#{{TIER_MEDIUM_EXAMPLES_INLINE}}#${esc_medium_inline}#g" \
    "$tmpl" > "$tmp"

  copy_one "$tmp" "$dst"
  rm -f "$tmp"
}
sync_coordinator

# ----------------------------------------------------------------- report

emit_section() {
  local label="$1"; shift
  # Caller passes the array via "${ARR[@]+"${ARR[@]}"}" which expands to
  # nothing when the array is empty. $# then accurately reflects the count.
  if (( $# > 0 )); then
    printf '\n%s (%d):\n' "$label" "$#"
    printf '  - %s\n' "$@"
  fi
}

printf '## agent-sync report\n'
printf '\nTooling: %s\n' "$TOOLING_DIR"
printf 'Target:  %s\n' "$TARGET_DIR"
printf 'Mode:    %s\n' "$($DRY_RUN && echo 'dry-run' || echo 'apply')"

emit_section 'Created'                                                  ${CREATED[@]+"${CREATED[@]}"}
emit_section 'Updated'                                                  ${UPDATED[@]+"${UPDATED[@]}"}
emit_section 'Unchanged (already in sync)'                              ${UNCHANGED[@]+"${UNCHANGED[@]}"}
emit_section 'Skipped (user-managed — sentinel removed)'                ${SKIPPED_USER_MANAGED[@]+"${SKIPPED_USER_MANAGED[@]}"}
emit_section 'Removed in tooling but kept in target (manual cleanup needed)' ${REMOVED_IN_TOOLING[@]+"${REMOVED_IN_TOOLING[@]}"}

# Exit code carries the "did anything change?" signal for the workflow.
TOTAL_CHANGES=$(( ${#CREATED[@]} + ${#UPDATED[@]} ))
if (( TOTAL_CHANGES > 0 )); then
  printf '\n==> %d file(s) %s.\n' "$TOTAL_CHANGES" "$($DRY_RUN && echo 'would change' || echo 'changed')"
  exit 2
else
  printf '\n==> Already in sync. No changes.\n'
  exit 0
fi
