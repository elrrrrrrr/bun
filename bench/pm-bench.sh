#!/usr/bin/env bash
#
# Compare install times of bun, utoo, pnpm, yarn, npm against the
# bench/install/ fixture using hyperfine.
#
# Cold runs:  per-PM, sequential. node_modules + the PM's global cache
#             are wiped before each run. Cold time is network + I/O bound,
#             so we don't average across PMs head-to-head.
# Warm runs:  head-to-head via a single hyperfine invocation. Only
#             node_modules is wiped between runs; global caches stay warm.
#
# Outputs:
#   /tmp/pm-bench-output/pm-bench-cold.md   markdown (hyperfine --export-markdown)
#   /tmp/pm-bench-output/pm-bench-warm.md   markdown (hyperfine --export-markdown)
#   /tmp/pm-bench-output/pm-bench-cold.json hyperfine raw json
#   /tmp/pm-bench-output/pm-bench-warm.json hyperfine raw json
#   /tmp/pm-bench-output/versions.txt       per-PM --version output
#
# Env:
#   PM_LIST          comma-separated PMs to bench. Default: bun,utoo,pnpm,yarn,npm
#   REGISTRY         registry url passed to each PM. Default: https://registry.npmjs.org
#   BENCH_COLD_RUNS  cold runs per PM. Default: 1
#   BENCH_WARM_RUNS  warm runs per PM. Default: 3
#   FIXTURE_DIR      fixture project. Default: <repo>/bench/install
#
# Used by .github/workflows/pm-benchmark.yml; safe to run locally too.

set -euo pipefail

PM_LIST="${PM_LIST:-bun,utoo,pnpm,yarn,npm}"
REGISTRY="${REGISTRY:-https://registry.npmjs.org}"
BENCH_COLD_RUNS="${BENCH_COLD_RUNS:-1}"
BENCH_WARM_RUNS="${BENCH_WARM_RUNS:-3}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${FIXTURE_DIR:-$REPO_ROOT/bench/install}"
OUT_DIR="/tmp/pm-bench-output"

IFS=',' read -ra PMS <<<"$PM_LIST"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/pm-bench-*.md "$OUT_DIR"/pm-bench-*.json "$OUT_DIR/versions.txt"

# --- preflight ----------------------------------------------------------------

for cmd in hyperfine git node; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done
for pm in "${PMS[@]}"; do
  command -v "$pm" >/dev/null || { echo "missing: $pm" >&2; exit 1; }
done

if [ ! -d "$FIXTURE_DIR" ] || [ ! -f "$FIXTURE_DIR/package.json" ]; then
  echo "fixture not found: $FIXTURE_DIR" >&2
  exit 1
fi

cd "$FIXTURE_DIR"

{
  echo "Registry: $REGISTRY"
  echo "Fixture: $FIXTURE_DIR"
  echo ""
  for pm in "${PMS[@]}"; do
    printf '%-6s %s\n' "$pm" "$("$pm" --version 2>&1 | head -1)"
  done
} | tee "$OUT_DIR/versions.txt"

# --- cache + install command shapes ------------------------------------------

# Wipe node_modules + (optionally) the PM's global cache.
#   $1 PM  $2 "cold" | "warm"
prepare_cmd() {
  local pm="$1" mode="$2"
  local script="$OUT_DIR/prepare-$pm-$mode.sh"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -e
cd "$FIXTURE_DIR"
rm -rf node_modules .next
EOF
  if [ "$mode" = "cold" ]; then
    case "$pm" in
      bun)  echo 'rm -rf "$HOME/.bun/install/cache"' >>"$script" ;;
      utoo) echo 'rm -rf "$HOME/.cache/nm" "$HOME/.utoo/cache"' >>"$script" ;;
      pnpm) echo 'pnpm store prune >/dev/null 2>&1 || true' >>"$script"
            echo 'rm -rf "$(pnpm store path 2>/dev/null || echo "$HOME/.pnpm-store")"' >>"$script" ;;
      yarn) echo 'rm -rf "$HOME/.yarn/cache" "$(yarn cache dir 2>/dev/null || echo "$HOME/.cache/yarn")"' >>"$script" ;;
      npm)  echo 'npm cache clean --force >/dev/null 2>&1 || true' >>"$script" ;;
    esac
  fi
  chmod +x "$script"
  echo "$script"
}

# Build the install command for one PM. --ignore-scripts so postinstall
# doesn't dominate timings; --registry pinned for parity.
install_cmd() {
  local pm="$1"
  case "$pm" in
    bun)  echo "bun install --ignore-scripts --registry=$REGISTRY" ;;
    utoo) echo "utoo install --ignore-scripts --registry=$REGISTRY" ;;
    pnpm) echo "npm_config_package_manager_strict=false pnpm install --ignore-scripts --registry=$REGISTRY" ;;
    yarn) echo "yarn install --ignore-scripts --registry $REGISTRY" ;;
    npm)  echo "npm install --ignore-scripts --registry=$REGISTRY --no-audit --no-fund" ;;
  esac
}

# --- ensure each PM has a lockfile so warm runs are apples-to-apples ----------

ensure_lockfiles() {
  echo ""
  echo "Generating per-PM lockfiles (untimed setup)..."
  for pm in "${PMS[@]}"; do
    case "$pm" in
      pnpm) [ -f pnpm-lock.yaml ] && continue ;;
      yarn) [ -f yarn.lock ] && continue ;;
      *)    continue ;;
    esac
    rm -rf node_modules
    echo "  $pm install (lockfile bootstrap)"
    eval "$(install_cmd "$pm")" >/dev/null 2>&1 || {
      echo "  $pm lockfile bootstrap failed" >&2
    }
  done
  rm -rf node_modules
}

ensure_lockfiles

# --- cold benchmark -----------------------------------------------------------

echo ""
echo "Cold installs ($BENCH_COLD_RUNS run/PM)..."

cold_args=(
  --warmup 0
  --runs "$BENCH_COLD_RUNS"
  --export-markdown "$OUT_DIR/pm-bench-cold.md"
  --export-json "$OUT_DIR/pm-bench-cold.json"
)
for pm in "${PMS[@]}"; do
  cold_args+=(
    -n "$pm"
    --prepare "bash $(prepare_cmd "$pm" cold)"
    "$(install_cmd "$pm")"
  )
done
hyperfine "${cold_args[@]}" || echo "cold bench failed (continuing)"

# --- warm benchmark -----------------------------------------------------------

echo ""
echo "Warm installs ($BENCH_WARM_RUNS runs/PM, 1 warmup, head-to-head)..."

warm_args=(
  --warmup 1
  --runs "$BENCH_WARM_RUNS"
  --export-markdown "$OUT_DIR/pm-bench-warm.md"
  --export-json "$OUT_DIR/pm-bench-warm.json"
)
for pm in "${PMS[@]}"; do
  warm_args+=(
    -n "$pm"
    --prepare "bash $(prepare_cmd "$pm" warm)"
    "$(install_cmd "$pm")"
  )
done
hyperfine "${warm_args[@]}" || echo "warm bench failed (continuing)"

echo ""
echo "Done. Output: $OUT_DIR/"
ls -1 "$OUT_DIR"
