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

# purge_legacy_nvm_binstubs: symlinks into ~/.nvm must be removed;
# symlinks pointing elsewhere must be left alone; real files untouched.
FAKE_BIN="$TMP_HOME/usr-local-bin"
mkdir -p "$FAKE_BIN"
mkdir -p "$TMP_HOME/.nvm/versions/node/v24/bin"
: > "$TMP_HOME/.nvm/versions/node/v24/bin/node"
: > "$TMP_HOME/.nvm/versions/node/v24/bin/claude"
ln -sfn "$TMP_HOME/.nvm/versions/node/v24/bin/node"   "$FAKE_BIN/node"
ln -sfn "$TMP_HOME/.nvm/versions/node/v24/bin/claude" "$FAKE_BIN/claude"
ln -sfn "/usr/bin/npm-20"                             "$FAKE_BIN/npm"   # unrelated, must stay
: > "$FAKE_BIN/npx"                                                     # real file, must stay

sudo() { "$@"; }  # strip sudo for the test
export -f sudo
CCR_LOCAL_BIN="$FAKE_BIN" ccr::purge_legacy_nvm_binstubs 0 >/dev/null

[[ ! -e "$FAKE_BIN/node"   ]] || { echo "nvm node stub not removed"; exit 1; }
[[ ! -e "$FAKE_BIN/claude" ]] || { echo "nvm claude stub not removed"; exit 1; }
[[ -L "$FAKE_BIN/npm"      ]] || { echo "unrelated npm symlink was removed"; exit 1; }
[[ -f "$FAKE_BIN/npx" && ! -L "$FAKE_BIN/npx" ]] || { echo "real npx file was removed"; exit 1; }

# purge is robust against a broken symlink whose readlink target is outside
# the nvm tree (must NOT be removed).
ln -sfn "/nonexistent/elsewhere/node" "$FAKE_BIN/node"
CCR_LOCAL_BIN="$FAKE_BIN" ccr::purge_legacy_nvm_binstubs 0 >/dev/null
[[ -L "$FAKE_BIN/node" ]] || { echo "unrelated broken symlink was wrongly removed"; exit 1; }
rm -f "$FAKE_BIN/node"

# Dry-run: no filesystem changes, but [DRY-RUN] line is printed to stdout.
ln -sfn "$TMP_HOME/.nvm/versions/node/v24/bin/claude" "$FAKE_BIN/claude"
out="$(CCR_LOCAL_BIN="$FAKE_BIN" ccr::purge_legacy_nvm_binstubs 1 2>&1)"
[[ -L "$FAKE_BIN/claude" ]] || { echo "dry-run actually removed the file"; exit 1; }
grep -q '\[DRY-RUN\] sudo rm -f' <<<"$out" || { echo "dry-run did not print plan; got: $out"; exit 1; }
rm -f "$FAKE_BIN/claude"

unset -f sudo

echo "common.sh tests passed"
