#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-login.sh [install flags...] [-- login flags...]

Examples:
  ./scripts/bootstrap-login.sh
  ./scripts/bootstrap-login.sh -- --email you@example.com
  ./scripts/bootstrap-login.sh -- --force
  ./scripts/bootstrap-login.sh --dry-run
EOF
}

INSTALL_ARGS=()
LOGIN_ARGS=()
MODE="install"

while (($#)); do
  case "$1" in
    --)
      MODE="login"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$MODE" == "install" ]]; then
        INSTALL_ARGS+=("$1")
      else
        LOGIN_ARGS+=("$1")
      fi
      ;;
  esac
  shift
done

cd "$ROOT_DIR"

./bin/cc-reset install "${INSTALL_ARGS[@]}"
if ./bin/cc-reset doctor --json 2>/dev/null | grep -q '"auth":"authenticated"'; then
  echo "[INFO] Existing Claude authentication detected; skipping login."
  ./bin/cc-reset doctor
else
  ./bin/cc-reset login "${LOGIN_ARGS[@]}"
fi
