#!/usr/bin/env bash

set -euo pipefail

CCR_VERSION="0.1.0"
CCR_CONFIG_DIR="${HOME}/.config/cc-reset"
CCR_STATE_DIR="${CCR_CONFIG_DIR}/state"
CCR_ENV_FILE="${CCR_CONFIG_DIR}/env.sh"
CCR_SESSION_FILE="${CCR_STATE_DIR}/oauth-session.json"
CCR_NVM_BLOCK_ID="cc-reset-nvm"

ccr::info() { printf '[INFO] %s\n' "$*"; }
ccr::warn() { printf '[WARN] %s\n' "$*" >&2; }
ccr::error() { printf '[ERROR] %s\n' "$*" >&2; }
ccr::die() { ccr::error "$*"; exit 1; }

ccr::env_file() {
  printf '%s\n' "$CCR_ENV_FILE"
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

ccr::ensure_shell_init() {
  local block_content
  block_content='export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$HOME/.config/cc-reset/env.sh" ] && . "$HOME/.config/cc-reset/env.sh"'
  ccr::append_block_once "${HOME}/.bashrc" "$CCR_NVM_BLOCK_ID" "$block_content"
  if [[ -f "${HOME}/.zshrc" ]]; then
    ccr::append_block_once "${HOME}/.zshrc" "$CCR_NVM_BLOCK_ID" "$block_content"
  fi
}

ccr::load_nvm() {
  export NVM_DIR="${HOME}/.nvm"
  if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "${NVM_DIR}/nvm.sh"
  else
    return 1
  fi
}

ccr::install_system_packages() {
  local dry_run="$1"
  local pkg_manager
  pkg_manager="$(ccr::detect_pkg_manager 2>/dev/null || true)"
  if [[ -z "$pkg_manager" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      pkg_manager="yum"
      ccr::warn "No yum/dnf detected on this host; dry-run will use yum-compatible commands for preview."
    else
      ccr::die "Neither yum nor dnf is available."
    fi
  fi
  ccr::info "Using package manager: ${pkg_manager}"
  ccr::run "$dry_run" sudo "$pkg_manager" update -y
  ccr::run "$dry_run" sudo "$pkg_manager" install -y git curl wget gcc-c++ make tar
}

ccr::install_nvm() {
  local dry_run="$1"
  ccr::ensure_shell_init
  if [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
    ccr::info "nvm already installed."
    return 0
  fi
  ccr::run "$dry_run" bash -lc 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
}

ccr::install_node_lts() {
  local dry_run="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    ccr::run 1 bash -lc 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm install --lts; nvm alias default lts/*; nvm use --lts'
    return 0
  fi
  ccr::load_nvm || ccr::die "nvm is not available after installation."
  nvm install --lts >/dev/null
  nvm alias default 'lts/*' >/dev/null
  nvm use --lts >/dev/null
}

ccr::latest_claude_version() {
  npm view @anthropic-ai/claude-code version
}

ccr::install_claude_code() {
  local dry_run="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    ccr::run 1 bash -lc 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use --lts >/dev/null && npm view @anthropic-ai/claude-code version && npm install -g @anthropic-ai/claude-code@"$(npm view @anthropic-ai/claude-code version)"'
    return 0
  fi

  ccr::load_nvm || ccr::die "nvm must be loaded before installing Claude Code."
  nvm use --lts >/dev/null
  local latest
  latest="$(ccr::latest_claude_version)"
  ccr::info "Installing Claude Code @ ${latest}"
  npm install -g "@anthropic-ai/claude-code@${latest}"
}

ccr::print_versions() {
  {
    ccr::has_cmd git && printf 'git: %s\n' "$(git --version | awk '{print $3}')" || printf 'git: missing\n'
    ccr::has_cmd curl && printf 'curl: present\n' || printf 'curl: missing\n'
    ccr::has_cmd wget && printf 'wget: present\n' || printf 'wget: missing\n'
    if ccr::load_nvm >/dev/null 2>&1; then
      nvm use --lts >/dev/null 2>&1 || true
    fi
    ccr::has_cmd node && printf 'node: %s\n' "$(node -v)" || printf 'node: missing\n'
    ccr::has_cmd npm && printf 'npm: %s\n' "$(npm -v)" || printf 'npm: missing\n'
    ccr::has_cmd claude && printf 'claude: %s\n' "$(claude --version)" || printf 'claude: missing\n'
  } | sed 's/^/[OK] /'
}

ccr::doctor() {
  local json="$1"
  local os_name="unknown"
  local pkg_manager="missing"
  local nvm_status="missing"
  local node_version=""
  local npm_version=""
  local claude_version=""
  local git_status="missing"
  local curl_status="missing"
  local wget_status="missing"
  local gcc_status="missing"
  local make_status="missing"

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
  [[ -s "${HOME}/.nvm/nvm.sh" ]] && nvm_status="present"
  ccr::has_cmd node && node_version="$(node -v)"
  ccr::has_cmd npm && npm_version="$(npm -v)"
  ccr::has_cmd claude && claude_version="$(claude --version)"

  if [[ "$json" -eq 1 ]]; then
    cat <<EOF
{"os":"${os_name}","packageManager":"${pkg_manager}","git":"${git_status}","curl":"${curl_status}","wget":"${wget_status}","gcc":"${gcc_status}","make":"${make_status}","nvm":"${nvm_status}","node":"${node_version}","npm":"${npm_version}","claude":"${claude_version}"}
EOF
    return 0
  fi

  cat <<EOF
Claude Code VPS Bootstrap Doctor
================================
OS              : ${os_name}
Package manager : ${pkg_manager}
git             : ${git_status}
curl            : ${curl_status}
wget            : ${wget_status}
gcc             : ${gcc_status}
make            : ${make_status}
nvm             : ${nvm_status}
node            : ${node_version:-missing}
npm             : ${npm_version:-missing}
claude          : ${claude_version:-missing}
session file    : ${CCR_SESSION_FILE}
env file        : ${CCR_ENV_FILE}
EOF
}

ccr::require_node() {
  ccr::has_cmd node || ccr::die "node is required. Run ./bin/cc-reset install first."
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
