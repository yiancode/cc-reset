#!/usr/bin/env bash

set -euo pipefail

REMOTE_URL="https://github.com/yiancode/cc-reset.git"
REPO_DIR='${HOME}/.cc-reset'

usage() {
  cat <<'EOF'
Usage: ./scripts/print-quickstart.sh [--email <email>] [--force]

Print the canonical git-only bootstrap one-liner.
EOF
}

EMAIL=""
FORCE=0

while (($#)); do
  case "$1" in
    --email)
      shift
      EMAIL="${1:-}"
      [[ -n "$EMAIL" ]] || { echo "[ERROR] --email requires a value" >&2; exit 1; }
      ;;
    --force)
      FORCE=1
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

TAIL='"$REPO_DIR/scripts/bootstrap-login.sh"'
if [[ -n "$EMAIL" ]]; then
  TAIL+=' -- --email '"$EMAIL"
elif [[ "$FORCE" -eq 1 ]]; then
  TAIL+=' -- --force'
fi

cat <<EOF
REPO_DIR="${REPO_DIR}" && \\
([ -d "\$REPO_DIR/.git" ] && git -C "\$REPO_DIR" fetch --depth=1 origin main && git -C "\$REPO_DIR" reset --hard origin/main || git clone --depth=1 ${REMOTE_URL} "\$REPO_DIR") && \\
${TAIL}
EOF
