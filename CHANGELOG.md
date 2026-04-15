# Changelog

All notable changes to this project will be documented in this file.

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
