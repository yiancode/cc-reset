# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2026-04-15

### Changed

- **Install path: dnf Node 20 instead of nvm + Node LTS.**
  - `install` now runs `sudo dnf install -y nodejs20 nodejs20-npm` and symlinks
    `/usr/bin/{node,npm,npx}-20` into `/usr/local/bin`, so `node`/`npm`/`claude`
    are available to every Linux user on the host, not just the invoking one.
  - `@anthropic-ai/claude-code` is now installed via `sudo npm install -g`,
    landing in system `/usr/bin/claude` (or wherever the system npm prefix
    resolves to).
  - `ccr::install_nvm` / `ccr::install_node_lts` are removed; their
    responsibility is now held by a single `ccr::install_system_node`.
  - `ccr::run_nvm_shell` is removed — no subshell is needed to use Node now.

### Fixed

- **Multi-user VPS: non-invoking users could not run `claude`.** Previously
  Node + claude lived under `~/.nvm/...`, which is unreachable from any
  non-root user because `/root` is mode 700. With the system-wide install,
  a freshly created Linux user can run `claude` immediately (paired with a
  shared-auth tool like `claude-share`, no re-login required).

### Migration

- Upgrading from v0.1 / v0.2 automatically removes the `cc-reset-nvm` shell
  startup block from `~/.bashrc` / `~/.zshrc`. `~/.nvm/` itself is left in
  place; if you no longer need it, delete it manually.
- `doctor` now reports `Node source` as one of `system (nodejs20)`,
  `nvm (legacy)`, or `missing`.
- `doctor --json` replaces the `nvm` key with `nodeSource` and now reports
  the discovered install source.

## [0.2.0] - 2026-04-15

### Fixed

- **Critical: Stale OAuth token override after re-login**
  - Root cause: `cc-reset login` wrote `CLAUDE_CODE_OAUTH_TOKEN` to `env.sh`, and `install` injected that file into shell startup. Expired tokens then overrode fresh credentials from `claude /login`.
  - Fix: Claude subscription login now writes OAuth credentials to `~/.claude/.credentials.json`, matching Claude Code's native credential store.
  - `env.sh` no longer stores OAuth token fields in subscription mode; it keeps only non-sensitive identity metadata.
  - Existing `cc-reset-nvm` shell blocks are replaced during install so old `env.sh` sourcing is removed on upgrade, not just on fresh installs.
  - `credentials.json` updates now preserve unrelated existing fields instead of overwriting the whole file.

### Changed

- `doctor` and login detection now recognize native Claude credentials in `~/.claude/.credentials.json`.
- API key mode still writes `ANTHROPIC_API_KEY` to `env.sh`, but shell startup no longer auto-sources `env.sh`; API key users must source it explicitly in new shells.

## [0.1.0] - 2026-04-15

Initial public release of `cc-reset`.

### Added

- `bin/cc-reset` main CLI with:
  - `install`
  - `doctor`
  - `login`
  - `repo-init`
  - `quickstart`
- `lib/common.sh` shared shell helpers
- `lib/oauth-helper.mjs` PKCE + OAuth helper for Claude subscription login
- `scripts/bootstrap-login.sh` one-shot install + login wrapper
- `scripts/publish.sh` repeatable GitHub publish helper
- `scripts/print-quickstart.sh` canonical one-liner generator
- MIT `LICENSE`

### Installation & Bootstrap

- yum/dnf-based system dependency installation
- nvm installation / reuse
- Node.js LTS installation / reuse
- latest `@anthropic-ai/claude-code` installation
- git-only bootstrap path for fresh VPS hosts

### Authentication

- Manual browser-assisted OAuth flow for SSH/VPS environments
- Support for pasting full callback URL or `code#state`
- Correct handling of Claude subscription OAuth tokens
- Writes `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, and `CLAUDE_CODE_OAUTH_SCOPES`
- Syncs Claude onboarding state to avoid first-run login picker loops
- Skips redundant login when Claude is already authenticated
- Supports explicit re-authentication with `--force`

### UX / CLI Output

- PASS/WARN/INFO status-card output for:
  - `doctor`
  - `install`
  - `install --dry-run`
  - authenticated login skip path
- Linux clipboard enhancement via optional `xclip` installation

### Docs

- README quickstart for git-only hosts
- quickstart one-liner generation via CLI and script
- force-login and no-clipboard examples

### Fixes

- Avoided `org:create_api_key` failure for Claude subscription OAuth tokens
- Avoided `nvm` `PROVIDED_VERSION` unbound-variable failures under strict shell mode
