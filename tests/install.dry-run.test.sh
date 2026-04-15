#!/usr/bin/env bash
#
# Integration-ish test: `cc-reset install --dry-run` should print the full
# plan without actually mutating the system. Asserts the presence of every
# side-effecting command we care about so future refactors can't silently
# drop, say, the legacy-nvm purge step.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export CLAUDE_CONFIG_DIR="$TMP_HOME/.claude"
mkdir -p "$TMP_HOME/.config/cc-reset" "$TMP_HOME/.claude"

# Seed a legacy nvm stub so purge_legacy_nvm_binstubs has something to plan.
FAKE_BIN="$TMP_HOME/usr-local-bin"
mkdir -p "$FAKE_BIN" "$TMP_HOME/.nvm/versions/node/v24/bin"
: > "$TMP_HOME/.nvm/versions/node/v24/bin/claude"
ln -sfn "$TMP_HOME/.nvm/versions/node/v24/bin/claude" "$FAKE_BIN/claude"

out="$(CCR_LOCAL_BIN="$FAKE_BIN" "$ROOT_DIR/bin/cc-reset" install --dry-run --no-clipboard 2>&1)"
status=$?
[[ $status -eq 0 ]] || { echo "install --dry-run exited $status"; echo "$out"; exit 1; }

fail=0
expect() {
  if ! grep -qE "$1" <<<"$out"; then
    echo "MISSING from --dry-run output: $1"
    fail=1
  fi
}

expect 'idempotent'                             # the startup banner
expect '\[DRY-RUN\] sudo (dnf|yum) update'      # system packages update
expect '\[DRY-RUN\] sudo (dnf|yum) install .* git' # system packages install
expect 'Removing legacy nvm stub:.*claude'      # purge step wired in
expect '\[DRY-RUN\] sudo rm -f .*/claude'       # purge actually plans the rm
expect '\[DRY-RUN\] sudo (dnf|yum) install -y nodejs' # node install
expect '\[DRY-RUN\] sudo ln -sfn /usr/bin/node-[0-9]+' # node symlink
expect '\[DRY-RUN\] sudo .*npm.* install -g @anthropic-ai/claude-code' # claude install

# Nothing should have actually been removed.
[[ -L "$FAKE_BIN/claude" ]] || { echo "dry-run actually removed $FAKE_BIN/claude"; exit 1; }

if [[ $fail -ne 0 ]]; then
  echo "---- full output ----"
  echo "$out"
  exit 1
fi

echo "install.dry-run tests passed"
