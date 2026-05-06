#!/usr/bin/env bash
# Compose the pm-benchmark sticky PR comment from bench/pm-bench.sh's
# /tmp/pm-bench-output/{pm-bench-cold,pm-bench-warm}.md exports.
#
# Output: /tmp/pm-bench-output/pr_comment.md
#
# Args:
#   $1 PLATFORM  e.g. linux, mac
#   $2 OS        e.g. ubuntu-latest, macos-latest
#
# hyperfine --export-markdown already emits a clean markdown table per run,
# so we just label them and stitch in the run metadata + PM versions.

set -eu

PLATFORM="$1"
OS="$2"
DIR=/tmp/pm-bench-output
OUT="$DIR/pr_comment.md"
SHA="${GITHUB_SHA:-}"
SHA_SHORT="${SHA:0:7}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

mkdir -p "$DIR"

emit_table() {
  local label="$1" file="$2"
  echo "### $label"
  echo ""
  if [ -f "$file" ] && [ -s "$file" ]; then
    cat "$file"
  else
    echo "_no output captured_"
  fi
  echo ""
}

{
  echo "## 📊 pm-benchmark · \`${SHA_SHORT}\` · ${PLATFORM} (\`${OS}\`)"
  echo ""
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    echo "[Workflow run]($RUN_URL)"
    echo ""
  fi
  echo "_Fixture: \`bench/install/\` · \`--ignore-scripts\` · registry pinned per run._"
  echo ""

  if [ -f "$DIR/versions.txt" ]; then
    echo "<details><summary>Tool versions</summary>"
    echo ""
    echo '```'
    cat "$DIR/versions.txt"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
  fi

  emit_table "Cold install (no global cache, no node_modules)" "$DIR/pm-bench-cold.md"
  emit_table "Warm install (global cache populated, node_modules cleared)" "$DIR/pm-bench-warm.md"
} >"$OUT"

echo "wrote $OUT ($(wc -c <"$OUT") bytes)"
