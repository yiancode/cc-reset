#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC2034
CCR_VERSION="0.3.0"
CCR_CONFIG_DIR="${HOME}/.config/cc-reset"
CCR_STATE_DIR="${CCR_CONFIG_DIR}/state"
CCR_ENV_FILE="${CCR_CONFIG_DIR}/env.sh"
# shellcheck disable=SC2034
CCR_SESSION_FILE="${CCR_STATE_DIR}/oauth-session.json"
CCR_NVM_BLOCK_ID="cc-reset-nvm"
CCR_CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

# System Node major version installed from distro packages (dnf/yum).
# Package name is "nodejs${CCR_NODE_MAJOR}" and the rpm ships binaries as
# /usr/bin/{node,npm,npx}-${CCR_NODE_MAJOR}; we symlink those to
# /usr/local/bin/{node,npm,npx} so every user on the system can find them.
#
# Both the requested major and the fallback are env-overridable. The
# fallback is used when the requested major fails the post-install smoke
# test (e.g. Claude Code TUI crashes under node 20 on some OpenCloudOS
# kernels but works under node 18). Set CCR_NODE_FALLBACK_MAJOR="" to
# disable the fallback and fail hard instead.
CCR_NODE_MAJOR="${CCR_NODE_MAJOR:-20}"
CCR_NODE_FALLBACK_MAJOR="${CCR_NODE_FALLBACK_MAJOR-18}"
# Updated at runtime if we fall back; helpers below read these whenever
# they need a concrete path.
CCR_SYSTEM_NODE="/usr/bin/node-${CCR_NODE_MAJOR}"
CCR_SYSTEM_NPM="/usr/bin/npm-${CCR_NODE_MAJOR}"
# shellcheck disable=SC2034
CCR_SYSTEM_NPX="/usr/bin/npx-${CCR_NODE_MAJOR}"

# Recompute the *_SYSTEM_* paths after CCR_NODE_MAJOR is mutated (e.g.
# during fallback). Everything downstream of install_system_node reads
# those globals, so they must be kept in sync.
ccr::_refresh_system_paths() {
  CCR_SYSTEM_NODE="/usr/bin/node-${CCR_NODE_MAJOR}"
  CCR_SYSTEM_NPM="/usr/bin/npm-${CCR_NODE_MAJOR}"
  # shellcheck disable=SC2034
  CCR_SYSTEM_NPX="/usr/bin/npx-${CCR_NODE_MAJOR}"
}

ccr::info() { printf '[INFO] %s\n' "$*"; }
ccr::warn() { printf '[WARN] %s\n' "$*" >&2; }
ccr::error() { printf '[ERROR] %s\n' "$*" >&2; }
ccr::die() { ccr::error "$*"; exit 1; }
ccr::ok() { printf '[PASS] %s\n' "$*"; }

ccr::status_line() {
  local state="$1"
  local label="$2"
  local detail="${3:-}"
  local state_rendered="$state"
  if [[ -t 1 ]]; then
    case "$state" in
      "[PASS]") state_rendered=$'\033[32m[PASS]\033[0m' ;;
      "[WARN]") state_rendered=$'\033[33m[WARN]\033[0m' ;;
      "[INFO]") state_rendered=$'\033[36m[INFO]\033[0m' ;;
      "[ERROR]") state_rendered=$'\033[31m[ERROR]\033[0m' ;;
    esac
  fi
  printf '%b %-24s %s\n' "$(printf '%-10s' "$state_rendered")" "$label" "$detail"
}

ccr::env_file() {
  printf '%s\n' "$CCR_ENV_FILE"
}

ccr::claude_config_file() {
  local nested="${CCR_CLAUDE_HOME}/.config.json"
  if [[ -f "$nested" ]]; then
    printf '%s\n' "$nested"
  else
    printf '%s\n' "${CCR_CLAUDE_HOME}.json"
  fi
}

ccr::ensure_state_dirs() {
  mkdir -p "$CCR_CONFIG_DIR" "$CCR_STATE_DIR"
}

ccr::has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ccr::require_linux_or_dry_run() {
  local dry_run="$1"
  if [[ "${OSTYPE:-}" != linux* ]] && [[ "$dry_run" -ne 1 ]]; then
    ccr::die "install only supports Linux. Use --dry-run for non-Linux validation."
  fi
}

ccr::detect_pkg_manager() {
  if ccr::has_cmd dnf; then
    printf 'dnf\n'
  elif ccr::has_cmd yum; then
    printf 'yum\n'
  elif ccr::has_cmd apt-get; then
    printf 'apt\n'
  else
    return 1
  fi
}

ccr::run() {
  local dry_run="$1"
  shift
  if [[ "$dry_run" -eq 1 ]]; then
    printf '[DRY-RUN] %q' "$1"
    shift
    while (($#)); do
      printf ' %q' "$1"
      shift
    done
    printf '\n'
    return 0
  fi
  "$@"
}

ccr::append_block_once() {
  local file="$1"
  local block_id="$2"
  local content="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q ">>> ${block_id}" "$file"; then
    return 0
  fi
  {
    printf '\n# >>> %s >>>\n' "$block_id"
    printf '%s\n' "$content"
    printf '# <<< %s <<<\n' "$block_id"
  } >>"$file"
}

ccr::replace_block() {
  local file="$1"
  local block_id="$2"
  local content="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  python3 - "$file" "$block_id" "$content" <<'PY'
import pathlib
import sys

file_path = pathlib.Path(sys.argv[1])
block_id = sys.argv[2]
content = sys.argv[3]
text = file_path.read_text()
start = f"# >>> {block_id} >>>"
end = f"# <<< {block_id} <<<"
replacement = f"{start}\n{content}\n{end}"

if start in text and end in text:
    before, marker, rest = text.partition(start)
    middle, end_marker, after = rest.partition(end)
    if marker and end_marker:
        updated = f"{before}{replacement}{after}"
        file_path.write_text(updated)
        sys.exit(0)

with file_path.open("a") as fh:
    if text and not text.endswith("\n"):
        fh.write("\n")
    fh.write(f"\n{replacement}\n")
PY
}

# Strip a named block entirely from a file (markers and content). Idempotent.
ccr::remove_block() {
  local file="$1"
  local block_id="$2"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$block_id" <<'PY'
import pathlib
import re
import sys

file_path = pathlib.Path(sys.argv[1])
block_id = sys.argv[2]
text = file_path.read_text()
pattern = re.compile(
    r'\n?# >>> ' + re.escape(block_id) + r' >>>.*?# <<< ' + re.escape(block_id) + r' <<<\n?',
    re.DOTALL,
)
new_text, n = pattern.subn('\n', text)
if n:
    # Collapse accidental double blanks introduced by the removal.
    new_text = re.sub(r'\n{3,}', '\n\n', new_text)
    file_path.write_text(new_text)
PY
}

ccr::ensure_shell_init() {
  # Starting v0.3.0 cc-reset installs Node system-wide via dnf packages, so no
  # shell startup init is needed at all. This function now only STRIPS any
  # legacy nvm block that v0.1/v0.2 installs left behind in ~/.bashrc / ~/.zshrc.
  ccr::remove_block "${HOME}/.bashrc" "$CCR_NVM_BLOCK_ID"
  if [[ -f "${HOME}/.zshrc" ]]; then
    ccr::remove_block "${HOME}/.zshrc" "$CCR_NVM_BLOCK_ID"
  fi
}

ccr::install_system_packages() {
  local dry_run="$1"
  local pkg_manager
  pkg_manager="$(ccr::detect_pkg_manager 2>/dev/null || true)"
  if [[ -z "$pkg_manager" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      pkg_manager="yum"
      ccr::warn "No yum/dnf/apt detected on this host; dry-run will use yum-compatible commands for preview."
    else
      ccr::die "No supported package manager found (yum, dnf, or apt-get)."
    fi
  fi
  ccr::info "Using package manager: ${pkg_manager}"
  if [[ "$pkg_manager" == "apt" ]]; then
    ccr::run "$dry_run" sudo apt-get update
    ccr::run "$dry_run" sudo apt-get install -y git curl wget g++ make tar
  else
    ccr::run "$dry_run" sudo "$pkg_manager" update -y
    ccr::run "$dry_run" sudo "$pkg_manager" install -y git curl wget gcc-c++ make tar
  fi
}

ccr::ensure_linux_clipboard_tool() {
  local dry_run="${1:-0}"
  local pkg_manager

  ccr::has_cmd xclip && return 0
  ccr::has_cmd xsel && return 0
  [[ "${OSTYPE:-}" == linux* ]] || return 1

  pkg_manager="$(ccr::detect_pkg_manager 2>/dev/null || true)"
  [[ -n "$pkg_manager" ]] || return 1

  ccr::status_line "[INFO]" "Clipboard tool" "Installing xclip for link copy support"
  if [[ "$pkg_manager" == "apt" ]]; then
    ccr::run "$dry_run" sudo apt-get install -y xclip || return 1
  else
    ccr::run "$dry_run" sudo "$pkg_manager" install -y xclip || return 1
  fi
  ccr::has_cmd xclip
}

# Remove /usr/local/bin/{node,npm,npx,claude} entries that are symlinks
# pointing into a legacy nvm tree (~/.nvm/). v0.1/v0.2 installed node + claude
# under ~/.nvm and left these symlinks behind; on RHEL /usr/local/bin precedes
# /usr/bin in PATH, so a dangling nvm stub shadows the system install and
# every user on the host ends up running a broken `claude`. install_system_node
# already re-creates node/npm/npx via `ln -sfn`, but `claude` is not in that
# loop — it has to be cleared here so install_claude_code's fresh /usr/bin/claude
# wins the PATH lookup.
ccr::purge_legacy_nvm_binstubs() {
  local dry_run="$1"
  local bin path target
  local prefix="${CCR_LOCAL_BIN:-/usr/local/bin}"
  for bin in node npm npx claude; do
    path="${prefix}/${bin}"
    [[ -L "$path" ]] || continue
    # readlink can fail on some exotic filesystems even for a symlink; treat
    # that as "not our problem" rather than aborting the whole install.
    target="$(readlink "$path" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    [[ "$target" == *"/.nvm/"* ]] || continue
    ccr::info "Removing legacy nvm stub: ${path} -> ${target}"
    ccr::run "$dry_run" sudo rm -f "$path"
  done
  if [[ -d "${HOME}/.nvm" ]]; then
    ccr::warn "Legacy ${HOME}/.nvm directory still present under $(id -un)'s home; cc-reset no longer uses it. Safe to remove: rm -rf ${HOME}/.nvm"
    ccr::warn "(Other users may have their own ~/.nvm — cc-reset only checks the invoking user.)"
  fi
}

# Install Node ${CCR_NODE_MAJOR} via NodeSource on Debian/Ubuntu systems.
# Sets CCR_SYSTEM_NODE / CCR_SYSTEM_NPM / CCR_SYSTEM_NPX to the resulting paths.
ccr::install_system_node_apt() {
  local dry_run="$1"

  ccr::info "Installing Node ${CCR_NODE_MAJOR} via NodeSource (Debian/Ubuntu)"
  if [[ "$dry_run" -eq 1 ]]; then
    ccr::run 1 bash -c "curl -fsSL https://deb.nodesource.com/setup_${CCR_NODE_MAJOR}.x | sudo -E bash -"
    ccr::run 1 sudo apt-get install -y nodejs
    ccr::run 1 sudo ln -sfn /usr/bin/node "/usr/local/bin/node"
    ccr::run 1 sudo ln -sfn /usr/bin/npm  "/usr/local/bin/npm"
    ccr::run 1 sudo ln -sfn /usr/bin/npx  "/usr/local/bin/npx"
    return 0
  fi

  curl -fsSL "https://deb.nodesource.com/setup_${CCR_NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y nodejs

  local node_bin="/usr/bin/node"
  local npm_bin="/usr/bin/npm"
  local npx_bin="/usr/bin/npx"

  if [[ ! -x "$node_bin" ]]; then
    ccr::warn "NodeSource install for Node ${CCR_NODE_MAJOR} failed: ${node_bin} not found"
    return 1
  fi

  sudo ln -sfn "$node_bin" "/usr/local/bin/node"
  [[ -x "$npm_bin" ]] && sudo ln -sfn "$npm_bin" "/usr/local/bin/npm"
  [[ -x "$npx_bin" ]] && sudo ln -sfn "$npx_bin" "/usr/local/bin/npx"

  CCR_SYSTEM_NODE="$node_bin"
  CCR_SYSTEM_NPM="$npm_bin"
  # shellcheck disable=SC2034
  CCR_SYSTEM_NPX="$npx_bin"
}

# Install Node ${CCR_NODE_MAJOR} from distro packages and expose node/npm/npx
# under /usr/local/bin. This replaces the v0.1/v0.2 nvm-based flow: Node now
# lives in /usr, so every user on the host — not just the one who ran
# cc-reset — can run `claude`.
ccr::install_system_node() {
  local dry_run="$1"
  local pkg_manager
  pkg_manager="$(ccr::detect_pkg_manager 2>/dev/null || true)"
  if [[ -z "$pkg_manager" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      pkg_manager="yum"
    else
      ccr::die "No supported package manager found (yum, dnf, or apt-get)."
    fi
  fi

  # Debian/Ubuntu: delegate to the NodeSource-based installer.
  if [[ "$pkg_manager" == "apt" ]]; then
    ccr::install_system_node_apt "$dry_run"
    return $?
  fi

  # Per-major candidate list. Each line is:
  #   <space-sep-pkgs>|<node-bin>|<npm-bin>|<npx-bin>
  # We try each line in order until one fully works (dnf install succeeds
  # AND all three binaries exist). The first line is the "distro-native"
  # packaging; later lines are fallbacks for distros that name things
  # differently.
  local candidates
  case "$CCR_NODE_MAJOR" in
    20)
      candidates=(
        'nodejs20 nodejs20-npm|/usr/bin/node-20|/usr/bin/npm-20|/usr/bin/npx-20'
      )
      ;;
    18)
      # OpenCloudOS 9 / RHEL 9 ship Node 18 as the vanilla `nodejs` rpm
      # with binaries directly at /usr/bin/node. Some downstreams expose
      # a separately-versioned `nodejs18` parallel install; try both.
      candidates=(
        'nodejs|/usr/bin/node|/usr/bin/npm|/usr/bin/npx'
        'nodejs18 nodejs18-npm|/usr/bin/node-18|/usr/bin/npm-18|/usr/bin/npx-18'
      )
      ;;
    *)
      candidates=(
        "nodejs${CCR_NODE_MAJOR} nodejs${CCR_NODE_MAJOR}-npm|/usr/bin/node-${CCR_NODE_MAJOR}|/usr/bin/npm-${CCR_NODE_MAJOR}|/usr/bin/npx-${CCR_NODE_MAJOR}"
      )
      ;;
  esac

  local line pkgs node_bin npm_bin npx_bin installed_ok=0
  for line in "${candidates[@]}"; do
    pkgs="${line%%|*}"
    line="${line#*|}"
    node_bin="${line%%|*}"; line="${line#*|}"
    npm_bin="${line%%|*}"; line="${line#*|}"
    npx_bin="${line%%|*}"

    ccr::info "Installing ${pkgs} via ${pkg_manager}"
    # shellcheck disable=SC2086  # $pkgs is intentionally word-split
    if ! ccr::run "$dry_run" sudo "$pkg_manager" install -y $pkgs; then
      ccr::warn "${pkgs} install failed, trying next candidate"
      continue
    fi

    if [[ "$dry_run" -eq 1 ]]; then
      ccr::run 1 sudo ln -sfn "$node_bin" "/usr/local/bin/node"
      ccr::run 1 sudo ln -sfn "$npm_bin"  "/usr/local/bin/npm"
      ccr::run 1 sudo ln -sfn "$npx_bin"  "/usr/local/bin/npx"
      installed_ok=1
      break
    fi

    # Verify the binaries the package was supposed to drop actually
    # landed where we expected.
    if [[ ! -x "$node_bin" || ! -x "$npm_bin" || ! -x "$npx_bin" ]]; then
      ccr::warn "${pkgs} installed but expected binaries missing (${node_bin}); trying next candidate"
      continue
    fi

    sudo ln -sfn "$node_bin" "/usr/local/bin/node"
    sudo ln -sfn "$npm_bin"  "/usr/local/bin/npm"
    sudo ln -sfn "$npx_bin"  "/usr/local/bin/npx"

    # Persist the resolved paths so install_claude_code uses the right npm.
    CCR_SYSTEM_NODE="$node_bin"
    CCR_SYSTEM_NPM="$npm_bin"
    # shellcheck disable=SC2034
    CCR_SYSTEM_NPX="$npx_bin"
    installed_ok=1
    break
  done

  [[ "$installed_ok" -eq 1 ]] || return 1
}

# Smoke-test a freshly installed claude under a real PTY. Returns 0 if
# claude starts and actually renders TUI output within the deadline,
# non-zero on crash, hang, or empty output.
#
# Why not `claude --version` + `script -qc "claude"`? Both produce false
# positives on OpenCloudOS + Node 20:
#   - `--version` exits before loading the TUI native addons
#   - `script -qc "claude"` under piped stdin lets claude enter a
#     non-TTY codepath and exit cleanly, skipping the crashing code
# The real failure mode is a silent hang during TUI init: the process
# lives but never produces any terminal output. We detect that by
# driving claude under a genuine pty.fork PTY with an explicit winsize
# + SSH-like environment, then counting bytes.
#
# Callers should only invoke this after `claude --version` already
# passed — if even --version fails there's no point doing the PTY dance.
#
# Return codes:
#   0 — claude produced TUI bytes within deadline → healthy
#   1 — claude crashed, hung with zero output, or missing claude
#   2 — no python3 available, smoke test skipped (advisory only)
ccr::smoke_test_claude() {
  if ! ccr::has_cmd claude; then
    return 1
  fi
  if ! claude --version >/dev/null 2>&1; then
    ccr::warn "claude --version failed; treating as broken install"
    return 1
  fi
  if ! ccr::has_cmd python3; then
    ccr::warn "smoke test skipped (python3 missing); relying on 'claude --version' only"
    return 2
  fi

  # Probe script: spawn claude under pty.fork with explicit winsize, wait
  # up to 10s for any output, report via exit code.
  #   0 — got bytes (healthy)
  #   2 — child exited with a signal (crash)
  #   3 — timeout with 0 bytes (hang — this is the v20 OpenCloudOS case)
  local probe_out probe_rc
  probe_out="$(python3 - <<'PY' 2>&1
import pty, os, select, struct, fcntl, termios, time, sys
try:
    pid, fd = pty.fork()
except Exception as e:
    print(f"pty.fork failed: {e}", file=sys.stderr); sys.exit(4)
if pid == 0:
    os.environ['TERM'] = 'xterm-256color'
    os.environ.setdefault('LANG', 'en_US.UTF-8')
    try:
        os.execvp("claude", ["claude"])
    except Exception as e:
        sys.stderr.write(f"execvp failed: {e}\n"); os._exit(127)
try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 200, 0, 0))
except Exception:
    pass
deadline = time.time() + 10
got = 0
while time.time() < deadline:
    try:
        r, _, _ = select.select([fd], [], [], 0.3)
    except OSError:
        break
    if r:
        try:
            chunk = os.read(fd, 4096)
            if chunk:
                got += len(chunk)
                if got > 32:  # clearly rendering, done
                    break
        except OSError:
            break
    wpid, status = os.waitpid(pid, os.WNOHANG)
    if wpid != 0:
        sig = status & 0x7f
        if sig:
            print(f"crash sig={sig} bytes={got}", file=sys.stderr); sys.exit(2)
        # clean exit — if we saw bytes, pass; otherwise treat as broken.
        print(f"exit bytes={got}", file=sys.stderr); sys.exit(0 if got else 3)
# Still running — kill and judge by bytes.
try:
    os.kill(pid, 9); os.waitpid(pid, 0)
except Exception:
    pass
print(f"alive bytes={got}", file=sys.stderr)
sys.exit(0 if got else 3)
PY
)" || probe_rc=$?
  probe_rc="${probe_rc:-0}"

  if [[ "$probe_rc" -eq 0 ]]; then
    return 0
  fi
  case "$probe_rc" in
    2) ccr::warn "claude smoke test: crashed during TUI startup" ;;
    3) ccr::warn "claude smoke test: TUI produced zero output within 10s (silent hang)" ;;
    4) ccr::warn "claude smoke test: pty.fork unavailable" ;;
    *) ccr::warn "claude smoke test: failed with rc=${probe_rc}" ;;
  esac
  printf '  probe output: %s\n' "${probe_out}" >&2
  return 1
}

# Install node + claude for a given major, then smoke-test. If the
# smoke test passes, leave things in place and return 0. If it fails
# and a fallback major is configured, retry with the fallback. On
# ultimate failure, return non-zero so the caller can die.
ccr::install_node_and_claude_with_fallback() {
  local dry_run="$1"
  local -a tried=()
  local major
  for major in "$CCR_NODE_MAJOR" "${CCR_NODE_FALLBACK_MAJOR:-}"; do
    [[ -n "$major" ]] || continue
    # Skip the fallback if it's identical to the requested major.
    local already=0 t
    for t in "${tried[@]}"; do
      [[ "$t" == "$major" ]] && already=1
    done
    [[ "$already" -eq 1 ]] && continue
    tried+=("$major")

    CCR_NODE_MAJOR="$major"
    ccr::_refresh_system_paths
    ccr::info "Attempting Node ${major} + Claude Code"
    if ! ccr::install_system_node "$dry_run"; then
      ccr::warn "Node ${major} install failed (package missing or /usr/bin/node-${major} absent)"
      continue
    fi
    if ! ccr::install_claude_code "$dry_run"; then
      ccr::warn "Claude Code install under Node ${major} failed"
      continue
    fi

    if [[ "$dry_run" -eq 1 ]]; then
      # No real installation happened — nothing to smoke-test. Accept
      # the first (requested) major and stop.
      return 0
    fi

    hash -r 2>/dev/null || true
    if ccr::smoke_test_claude; then
      ccr::ok "Node ${major} + Claude Code smoke test passed"
      return 0
    fi
    ccr::warn "Node ${major} failed smoke test"
    if [[ -n "${CCR_NODE_FALLBACK_MAJOR:-}" && "$major" != "${CCR_NODE_FALLBACK_MAJOR}" ]]; then
      ccr::warn "Falling back to Node ${CCR_NODE_FALLBACK_MAJOR}"
    fi
  done
  ccr::error "All attempted Node majors failed: ${tried[*]}"
  return 1
}

ccr::latest_claude_version() {
  if [[ -x "$CCR_SYSTEM_NPM" ]]; then
    "$CCR_SYSTEM_NPM" view @anthropic-ai/claude-code version
  else
    npm view @anthropic-ai/claude-code version
  fi
}

# Globally install @anthropic-ai/claude-code via the system npm. The binary
# lands in /usr/bin (rpm-managed npm) or /usr/local/bin (if a user has
# customised npm prefix). Either path is readable by every user on the host.
ccr::install_claude_code() {
  local dry_run="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    ccr::run 1 sudo "$CCR_SYSTEM_NPM" install -g @anthropic-ai/claude-code@latest
    return 0
  fi
  [[ -x "$CCR_SYSTEM_NPM" ]] \
    || ccr::die "System npm not found at ${CCR_SYSTEM_NPM}. Run 'cc-reset install' (or install nodejs${CCR_NODE_MAJOR}) first."
  local latest
  latest="$(ccr::latest_claude_version)"
  ccr::info "Installing Claude Code @ ${latest}"
  sudo "$CCR_SYSTEM_NPM" install -g "@anthropic-ai/claude-code@${latest}"
}

ccr::print_versions() {
  {
    ccr::has_cmd git && printf 'git: %s\n' "$(git --version | awk '{print $3}')" || printf 'git: missing\n'
    ccr::has_cmd curl && printf 'curl: present\n' || printf 'curl: missing\n'
    ccr::has_cmd wget && printf 'wget: present\n' || printf 'wget: missing\n'
    ccr::has_cmd node && printf 'node: %s\n' "$(node -v)" || printf 'node: missing\n'
    ccr::has_cmd npm && printf 'npm: %s\n' "$(npm -v)" || printf 'npm: missing\n'
    ccr::has_cmd claude && printf 'claude: %s\n' "$(claude --version)" || printf 'claude: missing\n'
  } | sed 's/^/[OK] /'
}

ccr::render_install_card() {
  local git_version="$1"
  local node_version="$2"
  local npm_version="$3"
  local claude_version="$4"
  local mode="${5:-live}"
  printf '=============================================\n'
  printf ' cc-reset install\n'
  printf '=============================================\n'
  if [[ "$mode" == "dry-run" ]]; then
    ccr::status_line "[INFO]" "Mode" "dry-run preview only"
    ccr::status_line "[INFO]" "git" "${git_version:-existing-or-install-target}"
    ccr::status_line "[INFO]" "Node runtime" "${node_version:-will install/use LTS}"
    ccr::status_line "[INFO]" "npm" "${npm_version:-will install with Node LTS}"
    ccr::status_line "[INFO]" "Claude Code" "${claude_version:-will install latest}"
    ccr::status_line "[INFO]" "Next action" "Run './bin/cc-reset install' for the real install."
  else
    ccr::status_line "[PASS]" "git" "${git_version:-missing}"
    ccr::status_line "[PASS]" "Node runtime" "${node_version:-missing}"
    ccr::status_line "[PASS]" "npm" "${npm_version:-missing}"
    ccr::status_line "[PASS]" "Claude Code" "${claude_version:-missing}"
    ccr::status_line "[INFO]" "Next action" "Run './bin/cc-reset login' to authenticate."
  fi
  printf '=============================================\n'
}

ccr::doctor() {
  local json="$1"
  local os_name="unknown"
  local pkg_manager="missing"
  local node_source="missing"
  local node_version=""
  local npm_version=""
  local claude_version=""
  local git_status="missing"
  local curl_status="missing"
  local wget_status="missing"
  local gcc_status="missing"
  local make_status="missing"
  local auth_state="missing"

  if [[ -r /etc/os-release ]]; then
    os_name="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
  else
    os_name="$(uname -srm 2>/dev/null || printf 'unknown')"
  fi
  pkg_manager="$(ccr::detect_pkg_manager 2>/dev/null || printf 'missing')"
  ccr::has_cmd git && git_status="present"
  ccr::has_cmd curl && curl_status="present"
  ccr::has_cmd wget && wget_status="present"
  ccr::has_cmd gcc && gcc_status="present"
  ccr::has_cmd make && make_status="present"
  if [[ -x "$CCR_SYSTEM_NODE" ]]; then
    node_source="system (nodejs${CCR_NODE_MAJOR})"
  elif [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
    node_source="nvm (legacy)"
  fi
  ccr::has_cmd node && node_version="$(node -v)"
  ccr::has_cmd npm && npm_version="$(npm -v)"
  ccr::has_cmd claude && claude_version="$(claude --version)"
  ccr::is_authenticated && auth_state="authenticated"

  if [[ "$json" -eq 1 ]]; then
    cat <<EOF
{"os":"${os_name}","packageManager":"${pkg_manager}","git":"${git_status}","curl":"${curl_status}","wget":"${wget_status}","gcc":"${gcc_status}","make":"${make_status}","nodeSource":"${node_source}","node":"${node_version}","npm":"${npm_version}","claude":"${claude_version}","auth":"${auth_state}"}
EOF
    return 0
  fi
  ccr::render_doctor_card \
    "$os_name" \
    "$pkg_manager" \
    "$git_status" \
    "$curl_status" \
    "$wget_status" \
    "$gcc_status" \
    "$make_status" \
    "$node_source" \
    "${node_version:-}" \
    "${npm_version:-}" \
    "${claude_version:-}" \
    "$auth_state"
}

ccr::require_node() {
  ccr::has_cmd node || ccr::die "node is required. Run ./bin/cc-reset install first."
}

ccr::auth_env_present() {
  [[ -f "$CCR_ENV_FILE" ]] || return 1
  grep -q 'ANTHROPIC_API_KEY' "$CCR_ENV_FILE"
}

ccr::claude_credentials_file() {
  printf '%s\n' "${CCR_CLAUDE_HOME}/.credentials.json"
}

ccr::claude_credentials_present() {
  local credentials_file
  credentials_file="$(ccr::claude_credentials_file)"
  [[ -s "$credentials_file" ]]
}

ccr::oauth_env_present_in_shell() {
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] || [[ -n "${CLAUDE_CODE_OAUTH_REFRESH_TOKEN:-}" ]] || [[ -n "${CLAUDE_CODE_OAUTH_SCOPES:-}" ]]
}

ccr::clear_stale_oauth_env() {
  unset CLAUDE_CODE_OAUTH_TOKEN
  unset CLAUDE_CODE_OAUTH_REFRESH_TOKEN
  unset CLAUDE_CODE_OAUTH_SCOPES
}

ccr::claude_onboarding_complete() {
  local config_file
  config_file="$(ccr::claude_config_file)"
  [[ -f "$config_file" ]] || return 1
  grep -q '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true' "$config_file"
}

ccr::auth_status_text() {
  ccr::has_cmd claude || return 1
  claude auth status --text 2>/dev/null || true
}

ccr::is_authenticated() {
  local status_text=""
  status_text="$(ccr::auth_status_text)"
  if [[ "$status_text" == *"Auth token:"* ]] || [[ "$status_text" == *"API key:"* ]]; then
    return 0
  fi

  if ccr::claude_credentials_present && ccr::claude_onboarding_complete; then
    return 0
  fi

  if ccr::auth_env_present && ccr::claude_onboarding_complete; then
    return 0
  fi

  return 1
}

ccr::print_auth_summary() {
  local env_state="missing"
  local credentials_state="missing"
  local onboarding_state="missing"
  local status_text=""

  ccr::auth_env_present && env_state="present"
  ccr::claude_credentials_present && credentials_state="present"
  ccr::claude_onboarding_complete && onboarding_state="complete"
  status_text="$(ccr::auth_status_text)"

  ccr::status_line "$([[ "$env_state" == "present" ]] && echo "[PASS]" || echo "[WARN]")" "Auth env file" "$CCR_ENV_FILE"
  ccr::status_line "$([[ "$credentials_state" == "present" ]] && echo "[PASS]" || echo "[WARN]")" "Claude credentials" "$(ccr::claude_credentials_file)"
  ccr::status_line "$([[ "$onboarding_state" == "complete" ]] && echo "[PASS]" || echo "[WARN]")" "Onboarding state" "$(ccr::claude_config_file)"
  if [[ -n "$status_text" ]]; then
    ccr::status_line "[PASS]" "Claude auth source" "$(printf '%s' "$status_text" | tr '\n' ' ' | sed 's/  */ /g')"
  else
    ccr::status_line "[WARN]" "Claude auth source" "unavailable"
  fi
}

ccr::render_doctor_card() {
  local os_name="$1"
  local pkg_manager="$2"
  local git_status="$3"
  local curl_status="$4"
  local wget_status="$5"
  local gcc_status="$6"
  local make_status="$7"
  local node_source="$8"
  local node_version="$9"
  local npm_version="${10}"
  local claude_version="${11}"
  local auth_state="${12}"
  local env_state="WARN"
  local credentials_state="WARN"
  local onboarding_state="WARN"
  local auth_line_state="WARN"
  local status_text=""

  ccr::auth_env_present && env_state="PASS"
  ccr::claude_credentials_present && credentials_state="PASS"
  ccr::claude_onboarding_complete && onboarding_state="PASS"
  status_text="$(ccr::auth_status_text)"
  [[ "$auth_state" == "authenticated" ]] && auth_line_state="PASS"

  printf '=============================================\n'
  printf ' cc-reset doctor\n'
  printf '=============================================\n'
  ccr::status_line "[INFO]" "System" "$os_name"
  ccr::status_line "[INFO]" "Package manager" "$pkg_manager"
  ccr::status_line "[PASS]" "git" "$git_status"
  ccr::status_line "[PASS]" "curl" "$curl_status"
  ccr::status_line "[PASS]" "wget" "$wget_status"
  ccr::status_line "[PASS]" "gcc" "$gcc_status"
  ccr::status_line "[PASS]" "make" "$make_status"
  ccr::status_line "$([[ "$node_source" != "missing" ]] && echo "[PASS]" || echo "[WARN]")" "Node source" "$node_source"
  ccr::status_line "$([[ -n "$node_version" ]] && echo "[PASS]" || echo "[WARN]")" "Node runtime" "${node_version:-missing}"
  ccr::status_line "$([[ -n "$npm_version" ]] && echo "[PASS]" || echo "[WARN]")" "npm" "${npm_version:-missing}"
  ccr::status_line "$([[ -n "$claude_version" ]] && echo "[PASS]" || echo "[WARN]")" "Claude Code" "${claude_version:-missing}"
  ccr::status_line "$([[ "$auth_state" == "authenticated" ]] && echo "[PASS]" || echo "[WARN]")" "Authentication" "$auth_state"
  ccr::status_line "[$env_state]" "Auth env file" "$CCR_ENV_FILE"
  ccr::status_line "[$credentials_state]" "Claude credentials" "$(ccr::claude_credentials_file)"
  ccr::status_line "[$onboarding_state]" "Onboarding state" "$(ccr::claude_config_file)"
  if [[ -n "$status_text" ]]; then
    ccr::status_line "[$auth_line_state]" "Claude auth source" "$(printf '%s' "$status_text" | tr '\n' ' ' | sed 's/  */ /g')"
  else
    ccr::status_line "[WARN]" "Claude auth source" "unavailable"
  fi
  printf '=============================================\n'
  if [[ "$auth_state" == "authenticated" ]]; then
    ccr::status_line "[INFO]" "Next action" "No login needed. Use './bin/cc-reset login --force' to re-authenticate."
  else
    ccr::status_line "[INFO]" "Next action" "Run './bin/cc-reset login' to authenticate."
  fi
}

ccr::copy_to_clipboard() {
  local text="$1"
  if ccr::has_cmd pbcopy; then
    printf '%s' "$text" | pbcopy
    ccr::info "URL copied to clipboard via pbcopy."
    return 0
  fi
  if ccr::has_cmd xclip; then
    printf '%s' "$text" | xclip -selection clipboard
    ccr::info "URL copied to clipboard via xclip."
    return 0
  fi
  if ccr::has_cmd xsel; then
    printf '%s' "$text" | xsel --clipboard --input
    ccr::info "URL copied to clipboard via xsel."
    return 0
  fi
  ccr::warn "No clipboard tool found. Copy the URL manually."
  return 1
}

ccr::repo_init() {
  local remote="${1:-}"
  if [[ ! -d .git ]]; then
    git init
    ccr::info "Initialized git repository."
  else
    ccr::info "Git repository already initialized."
  fi

  if [[ -n "$remote" ]]; then
    if git remote get-url origin >/dev/null 2>&1; then
      git remote set-url origin "$remote"
      ccr::info "Updated origin -> $remote"
    else
      git remote add origin "$remote"
      ccr::info "Added origin -> $remote"
    fi
  fi
}
