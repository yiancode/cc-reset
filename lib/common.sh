#!/usr/bin/env bash

set -euo pipefail

CCR_VERSION="0.1.0"
CCR_CONFIG_DIR="${HOME}/.config/cc-reset"
CCR_STATE_DIR="${CCR_CONFIG_DIR}/state"
CCR_ENV_FILE="${CCR_CONFIG_DIR}/env.sh"
CCR_SESSION_FILE="${CCR_STATE_DIR}/oauth-session.json"
CCR_NVM_BLOCK_ID="cc-reset-nvm"
CCR_CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

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

ccr::run_nvm_shell() {
  local script="$1"
  export NVM_DIR="${HOME}/.nvm"
  [[ -s "${NVM_DIR}/nvm.sh" ]] || return 1
  bash -lc "set +u; export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"; ${script}"
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

ccr::ensure_linux_clipboard_tool() {
  local dry_run="${1:-0}"
  local pkg_manager

  ccr::has_cmd xclip && return 0
  ccr::has_cmd xsel && return 0
  [[ "${OSTYPE:-}" == linux* ]] || return 1

  pkg_manager="$(ccr::detect_pkg_manager 2>/dev/null || true)"
  [[ -n "$pkg_manager" ]] || return 1

  ccr::status_line "[INFO]" "Clipboard tool" "Installing xclip for link copy support"
  ccr::run "$dry_run" sudo "$pkg_manager" install -y xclip || return 1
  ccr::has_cmd xclip
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
  ccr::run_nvm_shell 'nvm install --lts >/dev/null; nvm alias default "lts/*" >/dev/null; nvm use --lts >/dev/null' \
    || ccr::die "nvm is not available after installation."
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

  local latest
  latest="$(ccr::latest_claude_version)"
  ccr::info "Installing Claude Code @ ${latest}"
  ccr::run_nvm_shell "nvm use --lts >/dev/null; npm install -g @anthropic-ai/claude-code@${latest}" \
    || ccr::die "nvm must be loaded before installing Claude Code."
}

ccr::print_versions() {
  {
    ccr::has_cmd git && printf 'git: %s\n' "$(git --version | awk '{print $3}')" || printf 'git: missing\n'
    ccr::has_cmd curl && printf 'curl: present\n' || printf 'curl: missing\n'
    ccr::has_cmd wget && printf 'wget: present\n' || printf 'wget: missing\n'
    ccr::run_nvm_shell 'nvm use --lts >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
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
  local nvm_status="missing"
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
  [[ -s "${HOME}/.nvm/nvm.sh" ]] && nvm_status="present"
  ccr::has_cmd node && node_version="$(node -v)"
  ccr::has_cmd npm && npm_version="$(npm -v)"
  ccr::has_cmd claude && claude_version="$(claude --version)"
  ccr::is_authenticated && auth_state="authenticated"

  if [[ "$json" -eq 1 ]]; then
    cat <<EOF
{"os":"${os_name}","packageManager":"${pkg_manager}","git":"${git_status}","curl":"${curl_status}","wget":"${wget_status}","gcc":"${gcc_status}","make":"${make_status}","nvm":"${nvm_status}","node":"${node_version}","npm":"${npm_version}","claude":"${claude_version}","auth":"${auth_state}"}
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
    "$nvm_status" \
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
  grep -qE 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY' "$CCR_ENV_FILE"
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

  if ccr::auth_env_present && ccr::claude_onboarding_complete; then
    return 0
  fi

  return 1
}

ccr::print_auth_summary() {
  local env_state="missing"
  local onboarding_state="missing"
  local status_text=""

  ccr::auth_env_present && env_state="present"
  ccr::claude_onboarding_complete && onboarding_state="complete"
  status_text="$(ccr::auth_status_text)"

  ccr::status_line "$([[ "$env_state" == "present" ]] && echo "[PASS]" || echo "[WARN]")" "Auth env file" "$CCR_ENV_FILE"
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
  local nvm_status="$8"
  local node_version="$9"
  local npm_version="${10}"
  local claude_version="${11}"
  local auth_state="${12}"
  local env_state="WARN"
  local onboarding_state="WARN"
  local auth_line_state="WARN"
  local status_text=""

  ccr::auth_env_present && env_state="PASS"
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
  ccr::status_line "$([[ "$nvm_status" == "present" ]] && echo "[PASS]" || echo "[WARN]")" "nvm" "$nvm_status"
  ccr::status_line "$([[ -n "$node_version" ]] && echo "[PASS]" || echo "[WARN]")" "Node runtime" "${node_version:-missing}"
  ccr::status_line "$([[ -n "$npm_version" ]] && echo "[PASS]" || echo "[WARN]")" "npm" "${npm_version:-missing}"
  ccr::status_line "$([[ -n "$claude_version" ]] && echo "[PASS]" || echo "[WARN]")" "Claude Code" "${claude_version:-missing}"
  ccr::status_line "$([[ "$auth_state" == "authenticated" ]] && echo "[PASS]" || echo "[WARN]")" "Authentication" "$auth_state"
  ccr::status_line "[$env_state]" "Auth env file" "$CCR_ENV_FILE"
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
