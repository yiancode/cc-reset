#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REMOTE_URL="https://github.com/yiancode/cc-reset.git"

usage() {
  cat <<'EOF'
Usage: ./scripts/publish.sh [--remote <url>] [--branch <name>] [--skip-checks]

Default behavior:
  1. Ensures git repo exists
  2. Sets/updates origin
  3. Runs lightweight checks
  4. Shows current status
  5. Pushes current branch

Examples:
  ./scripts/publish.sh
  ./scripts/publish.sh --remote https://github.com/yiancode/cc-reset.git
  ./scripts/publish.sh --branch main
  ./scripts/publish.sh --skip-checks
EOF
}

REMOTE_URL="$DEFAULT_REMOTE_URL"
BRANCH=""
SKIP_CHECKS=0

while (($#)); do
  case "$1" in
    --remote)
      shift
      REMOTE_URL="${1:-}"
      [[ -n "$REMOTE_URL" ]] || { echo "[ERROR] --remote requires a value" >&2; exit 1; }
      ;;
    --branch)
      shift
      BRANCH="${1:-}"
      [[ -n "$BRANCH" ]] || { echo "[ERROR] --branch requires a value" >&2; exit 1; }
      ;;
    --skip-checks)
      SKIP_CHECKS=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown flag: $1" >&2
      exit 1
      ;;
  esac
  shift
done

cd "$ROOT_DIR"

if [[ ! -d .git ]]; then
  git init
  echo "[INFO] Initialized git repository."
fi

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
  echo "[INFO] Updated origin -> $REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
  echo "[INFO] Added origin -> $REMOTE_URL"
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git branch --show-current)"
fi

if [[ -z "$BRANCH" ]]; then
  echo "[ERROR] Cannot determine current branch. Create a branch first." >&2
  exit 1
fi

if [[ "$SKIP_CHECKS" -ne 1 ]]; then
  echo "[INFO] Running publish checks..."
  bash -n bin/cc-reset lib/common.sh
  node --check lib/oauth-helper.mjs
  ./bin/cc-reset doctor --json >/dev/null
fi

echo "[INFO] Current branch: $BRANCH"
git status --short --branch

echo "[INFO] Pushing to origin/$BRANCH ..."
git push -u origin "$BRANCH"

echo "[INFO] Publish complete."
