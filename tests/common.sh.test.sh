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

# CCR_NODE_MAJOR / CCR_NODE_FALLBACK_MAJOR must honour env overrides.
# Re-source common.sh in a subshell with the env vars set, then read back.
out="$(CCR_NODE_MAJOR=18 CCR_NODE_FALLBACK_MAJOR=16 bash -c "
  source '$ROOT_DIR/lib/common.sh'
  printf '%s %s %s\n' \"\$CCR_NODE_MAJOR\" \"\$CCR_NODE_FALLBACK_MAJOR\" \"\$CCR_SYSTEM_NODE\"
")"
[[ "$out" == "18 16 /usr/bin/node-18" ]] \
  || { echo "env override failed: got '$out'"; exit 1; }

# An empty fallback must be honoured (disable fallback path).
out="$(CCR_NODE_MAJOR=20 CCR_NODE_FALLBACK_MAJOR= bash -c "
  source '$ROOT_DIR/lib/common.sh'
  printf '%s|%s\n' \"\$CCR_NODE_MAJOR\" \"\$CCR_NODE_FALLBACK_MAJOR\"
")"
[[ "$out" == "20|" ]] \
  || { echo "empty fallback override failed: got '$out'"; exit 1; }

# _refresh_system_paths must follow a CCR_NODE_MAJOR mutation.
(
  source "$ROOT_DIR/lib/common.sh"
  CCR_NODE_MAJOR=18
  ccr::_refresh_system_paths
  [[ "$CCR_SYSTEM_NODE" == "/usr/bin/node-18" ]] || { echo "refresh did not update NODE path"; exit 1; }
  [[ "$CCR_SYSTEM_NPM"  == "/usr/bin/npm-18"  ]] || { echo "refresh did not update NPM path";  exit 1; }
)

# install_node_and_claude_with_fallback: mock install_system_node +
# install_claude_code + smoke_test so we can exercise the retry logic
# without actually touching the system. Fail the first major, pass the
# second → the caller should see rc=0 AND CCR_NODE_MAJOR should end up
# as the fallback.
(
  source "$ROOT_DIR/lib/common.sh"
  CCR_NODE_MAJOR=20
  CCR_NODE_FALLBACK_MAJOR=18
  ccr::install_system_node() { :; }
  ccr::install_claude_code()  { :; }
  ccr::smoke_test_claude()    { [[ "$CCR_NODE_MAJOR" == "18" ]]; }
  ccr::install_node_and_claude_with_fallback 0 >/dev/null 2>&1 \
    || { echo "fallback flow did not return 0"; exit 1; }
  [[ "$CCR_NODE_MAJOR" == "18" ]] \
    || { echo "expected CCR_NODE_MAJOR=18 after fallback, got $CCR_NODE_MAJOR"; exit 1; }
)

# Same setup but BOTH majors fail → function must return non-zero.
(
  source "$ROOT_DIR/lib/common.sh"
  CCR_NODE_MAJOR=20
  CCR_NODE_FALLBACK_MAJOR=18
  ccr::install_system_node() { :; }
  ccr::install_claude_code()  { :; }
  ccr::smoke_test_claude()    { return 1; }
  if ccr::install_node_and_claude_with_fallback 0 >/dev/null 2>&1; then
    echo "expected total failure when both majors fail"
    exit 1
  fi
)

# Requested major passes on first try → fallback must not be attempted.
(
  source "$ROOT_DIR/lib/common.sh"
  CCR_NODE_MAJOR=20
  CCR_NODE_FALLBACK_MAJOR=18
  _calls=0
  ccr::install_system_node() { _calls=$((_calls + 1)); }
  ccr::install_claude_code()  { :; }
  ccr::smoke_test_claude()    { return 0; }
  ccr::install_node_and_claude_with_fallback 0 >/dev/null 2>&1
  [[ "$_calls" -eq 1 ]] \
    || { echo "expected 1 install attempt, got $_calls"; exit 1; }
  [[ "$CCR_NODE_MAJOR" == "20" ]] \
    || { echo "CCR_NODE_MAJOR should stay at 20, got $CCR_NODE_MAJOR"; exit 1; }
)

# Dry-run short-circuits smoke testing.
(
  source "$ROOT_DIR/lib/common.sh"
  CCR_NODE_MAJOR=20
  CCR_NODE_FALLBACK_MAJOR=18
  ccr::install_system_node() { :; }
  ccr::install_claude_code()  { :; }
  ccr::smoke_test_claude()    { echo "smoke ran — should not happen in dry-run" >&2; return 1; }
  ccr::install_node_and_claude_with_fallback 1 >/dev/null 2>&1 \
    || { echo "dry-run fallback-wrapper should always return 0"; exit 1; }
)

# install_system_node candidate fallback: the first candidate fails
# (mocked dnf returns non-zero), the second candidate succeeds. We
# stub dnf/sudo, stub the binary-existence check by putting fake
# executables at the expected second-candidate paths, and verify the
# function returns 0 and points CCR_SYSTEM_NPM at the second candidate.
(
  source "$ROOT_DIR/lib/common.sh"
  CCR_NODE_MAJOR=18
  FAKE_BIN_ROOT="$(mktemp -d)"
  trap 'rm -rf "$FAKE_BIN_ROOT"' EXIT
  # First candidate is 'nodejs' → /usr/bin/node etc. Second is 'nodejs18'
  # → /usr/bin/node-18 etc. We pretend the first pkg install fails and
  # the second succeeds, AND we pretend the second candidate's binaries
  # exist by ln-binding them into our sandbox. Since the code reads
  # /usr/bin/... directly, we need to monkey-patch sudo to intercept
  # ln/install and also to say "yes" to the second dnf call.
  _dnf_calls=0
  sudo() {
    case "$1" in
      dnf|yum)
        _dnf_calls=$((_dnf_calls + 1))
        if [[ "$_dnf_calls" -eq 1 ]]; then
          return 1   # first candidate: fail
        fi
        return 0     # second candidate: succeed
        ;;
      ln) return 0 ;;
      *)  return 0 ;;
    esac
  }
  export -f sudo
  # Stub the binary existence check by temporarily monkey-patching
  # install_system_node to skip /usr/bin verification. Simpler: intercept
  # the test by replacing ccr::install_system_node's tail check.
  # Actually — the cleanest way is to create the expected files.
  # We can't write to /usr/bin in a test, but we CAN shadow via $PATH +
  # modifying the function. For this unit test we just verify that the
  # "first candidate fails → second candidate attempted" flow happens.
  # We assert _dnf_calls == 2 after the call regardless of final result.
  ccr::install_system_node 0 >/dev/null 2>&1 || true
  [[ "$_dnf_calls" -ge 2 ]] \
    || { echo "expected at least 2 dnf attempts across candidates, got $_dnf_calls"; exit 1; }
  unset -f sudo
)

# smoke_test_claude: when python3 is missing, return code 2 (skipped).
# We simulate by renaming python3 out of PATH via a sandbox PATH.
(
  source "$ROOT_DIR/lib/common.sh"
  SANDBOX="$(mktemp -d)"
  trap 'rm -rf "$SANDBOX"' EXIT
  printf '#!/bin/sh\necho "2.1.109"\n' > "$SANDBOX/claude"
  chmod +x "$SANDBOX/claude"
  # set -e would abort on the non-zero return from smoke_test_claude;
  # wrap in an if-guard so we can read the return code explicitly.
  rc=0
  PATH="$SANDBOX" ccr::smoke_test_claude >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] \
    || { echo "smoke_test_claude should return 2 when python3 is missing, got $rc"; exit 1; }
)

echo "common.sh tests passed"
