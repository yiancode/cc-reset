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

# v0.3.0: the legacy cc-reset-nvm block must be fully removed, not replaced.
if grep -q 'env.sh' "$TMP_HOME/.bashrc"; then
  echo "legacy env.sh sourcing was not removed"
  exit 1
fi
if grep -q 'NVM_DIR' "$TMP_HOME/.bashrc"; then
  echo "legacy cc-reset-nvm block was not removed"
  exit 1
fi
if grep -q 'cc-reset-nvm' "$TMP_HOME/.bashrc"; then
  echo "legacy cc-reset-nvm marker was not removed"
  exit 1
fi

# Running ensure_shell_init twice must be a no-op (idempotent).
ccr::ensure_shell_init
if grep -q 'cc-reset-nvm' "$TMP_HOME/.bashrc"; then
  echo "second ensure_shell_init re-introduced cc-reset-nvm marker"
  exit 1
fi

# remove_block on a fresh block should leave the file tidy.
cat > "$TMP_HOME/.bashrc.test-remove" <<'EOF'
alpha=1
# >>> sample >>>
hello world
# <<< sample <<<
beta=2
EOF
ccr::remove_block "$TMP_HOME/.bashrc.test-remove" "sample"
if grep -q 'sample' "$TMP_HOME/.bashrc.test-remove"; then
  echo "remove_block did not strip sample block"
  exit 1
fi
grep -q '^alpha=1$' "$TMP_HOME/.bashrc.test-remove"
grep -q '^beta=2$'  "$TMP_HOME/.bashrc.test-remove"

ccr::is_authenticated

echo "common.sh tests passed"
