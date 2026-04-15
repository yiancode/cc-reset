#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export CLAUDE_CONFIG_DIR="$TMP_HOME/.claude"

mkdir -p "$TMP_HOME/.config/cc-reset" "$TMP_HOME/.claude"

cat > "$TMP_HOME/.bashrc" <<'EOF'
# >>> cc-reset-nvm >>>
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$HOME/.config/cc-reset/env.sh" ] && . "$HOME/.config/cc-reset/env.sh"
# <<< cc-reset-nvm <<<
EOF

cat > "$TMP_HOME/.claude/.config.json" <<'EOF'
{
  "hasCompletedOnboarding": true
}
EOF

cat > "$TMP_HOME/.claude/.credentials.json" <<'EOF'
{
  "claudeAiOauth": {
    "accessToken": "token"
  }
}
EOF

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

ccr::ensure_shell_init

if grep -q 'env.sh' "$TMP_HOME/.bashrc"; then
  echo "legacy env.sh sourcing was not removed"
  exit 1
fi

grep -q 'NVM_DIR' "$TMP_HOME/.bashrc"

ccr::is_authenticated

echo "common.sh tests passed"
