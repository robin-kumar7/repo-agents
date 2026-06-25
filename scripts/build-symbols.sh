#!/usr/bin/env bash
# build-symbols.sh
#
# Deterministic symbol-table builder for the agent index.
# Wraps universal-ctags and re-shapes its JSON-lines output into the
# `agent-index/symbols` schema (see docs/index-formats.md).
#
# Usage:
#   build-symbols.sh [OUTPUT] [ROOT]
#
# Defaults:
#   OUTPUT=.agent-index/symbols.json
#   ROOT=.
#
# Requires: universal-ctags, jq, git (optional, only for commit SHA).

set -euo pipefail
IFS=$'\n\t'

OUTPUT="${1:-.agent-index/symbols.json}"
ROOT="${2:-.}"

command -v ctags >/dev/null 2>&1 || { echo "build-symbols: need universal-ctags" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "build-symbols: need jq" >&2; exit 1; }

# Reject the BSD `ctags` shipped on macOS by default — its output is incompatible.
if ! ctags --version 2>&1 | grep -qi 'universal ctags'; then
  echo "build-symbols: ctags is not Universal Ctags (got: $(ctags --version 2>&1 | head -1))" >&2
  echo "  on macOS: brew install universal-ctags" >&2
  echo "  on Debian/Ubuntu: apt install universal-ctags" >&2
  exit 1
fi

CTAGS_VERSION="$(ctags --version | head -1)"
if COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"; then :; else COMMIT="unknown"; fi
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$OUTPUT")"

RAW="$(mktemp)"
cleanup() { rm -f "$RAW"; }
trap cleanup EXIT

# Generate ctags JSON-lines output.
# - --fields=+nKlsS  → include line number, kind, language, scope, signature
# - --extras=+q       → fully-qualified names
# - --output-format=json emits one JSON object per line
ctags \
  --recurse \
  --output-format=json \
  --fields=+nKlsS \
  --extras=+q \
  --languages=Go,Java,Python,JavaScript,TypeScript,Rust,Ruby,C,C++ \
  --exclude='vendor' \
  --exclude='node_modules' \
  --exclude='.git' \
  --exclude='.bootstrap' \
  --exclude='.agent-index' \
  --exclude='dist' \
  --exclude='build' \
  --exclude='target' \
  --exclude='__pycache__' \
  --exclude='.venv' \
  --exclude='venv' \
  --exclude='*.pb.go' \
  --exclude='*.pb.validate.go' \
  --exclude='*_pb2.py' \
  --exclude='*_pb2_grpc.py' \
  --exclude='*.min.js' \
  --exclude='*.bundle.js' \
  -f - \
  "$ROOT" > "$RAW"

# Re-shape ctags output into our schema. Drop duplicate (name,file,line) triples.
jq -s \
   --arg ts "$TS" \
   --arg gen "$CTAGS_VERSION" \
   --arg commit "$COMMIT" \
'{
  schema: "agent-index/symbols",
  version: 1,
  generated_at: $ts,
  generator: $gen,
  repo: { commit: $commit },
  symbols: (
    map({
      name: .name,
      kind: (.kind // "unknown"),
      language: (.language // "unknown"),
      file: .path,
      line: (.line // 0),
      signature: (.signature // null),
      scope: (.scope // null),
      exported: ((.name // "") | test("^[A-Z]"))
    })
    | unique_by([.name, .file, .line])
    | sort_by(.file, .line)
  )
}' "$RAW" > "$OUTPUT"

COUNT="$(jq '.symbols | length' "$OUTPUT")"
SIZE="$(wc -c < "$OUTPUT" | tr -d ' ')"
echo "build-symbols: ${COUNT} symbols, ${SIZE} bytes → ${OUTPUT}" >&2
