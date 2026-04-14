# cc-reset

一个面向 **yum 系 Linux VPS** 的 Claude Code 一键初始化与 OAuth 登录辅助工具。

目标场景：
- 新买的 OpenCloudOS / RHEL 风格 VPS
- 机器上几乎只有 `git`
- 你想尽快把 Claude Code 环境装好，并完成 SSH 场景下的登录

> 当前版本只支持 **yum / dnf**，不支持 `apt`。

## 功能

- 一键安装系统依赖
- 安装/复用 `nvm`
- 安装 Node.js LTS / npm
- 安装最新 `@anthropic-ai/claude-code`
- 提供 `doctor` 环境检查
- 提供 OAuth 手动登录辅助：
  - 输出授权链接
  - 尝试复制链接
  - 支持粘贴最终回调 URL
  - 自动完成 token exchange
  - 生成 `ANTHROPIC_API_KEY` 环境文件
  - 已认证时自动跳过重复登录
- 提供 git 仓库初始化 / remote 配置辅助
- 提供一键发布脚本

## 项目结构

```text
bin/cc-reset          # 主 CLI
lib/common.sh         # shell 公共函数
lib/oauth-helper.mjs  # OAuth / PKCE helper
```

## 快速开始

### 0) 只有 git 时的一条命令

如果机器上几乎只有 `git`，直接执行下面这一条：

```bash
REPO_DIR="${HOME}/.cc-reset" && \
([ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" fetch --depth=1 origin main && git -C "$REPO_DIR" reset --hard origin/main || git clone --depth=1 https://github.com/yiancode/cc-reset.git "$REPO_DIR") && \
"$REPO_DIR/scripts/bootstrap-login.sh"
```

这条命令会：
- 拉取或更新最新代码
- 安装系统依赖
- 尝试安装 `xclip` 以支持 Linux 终端复制链接
- 安装 nvm / Node LTS / Claude Code
- 如果尚未认证则进入 `login`
- 如果已认证则自动跳过重复登录

你只需要：
1. 复制终端给出的链接到外部浏览器
2. 登录后拿到回调 URL
3. 粘贴回 VPS

如果你想在一条命令里预填邮箱：

```bash
REPO_DIR="${HOME}/.cc-reset" && \
([ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" fetch --depth=1 origin main && git -C "$REPO_DIR" reset --hard origin/main || git clone --depth=1 https://github.com/yiancode/cc-reset.git "$REPO_DIR") && \
"$REPO_DIR/scripts/bootstrap-login.sh" -- --email you@example.com
```

如果你要强制重新登录：

```bash
REPO_DIR="${HOME}/.cc-reset" && \
([ -d "$REPO_DIR/.git" ] && git -C "$REPO_DIR" fetch --depth=1 origin main && git -C "$REPO_DIR" reset --hard origin/main || git clone --depth=1 https://github.com/yiancode/cc-reset.git "$REPO_DIR") && \
"$REPO_DIR/scripts/bootstrap-login.sh" -- --force
```

如果你想让仓库直接帮你生成这条 one-liner：

```bash
./scripts/print-quickstart.sh
./scripts/print-quickstart.sh --email you@example.com
./scripts/print-quickstart.sh --force
```

### 1) 拉取仓库

```bash
git clone <your-repo-url>
cd cc-reset
chmod +x bin/cc-reset
```

### 2) 安装环境

```bash
./bin/cc-reset install
```

它会完成：
- `yum` / `dnf` 依赖安装
- `nvm` 安装
- Node LTS 安装
- Claude Code 最新版本安装

安装完成后，可检查：

```bash
./bin/cc-reset doctor
claude --version
```

### 3) 完成登录

```bash
./bin/cc-reset login
```

流程：
1. 终端输出授权链接
2. 在你本地浏览器中打开该链接并完成登录
3. 浏览器最终跳转到类似下面的地址：

```text
https://platform.claude.com/oauth/code/callback?code=...&state=...
```

4. 把 **完整回调 URL** 粘贴回 VPS 终端
5. 工具会：
   - 交换 OAuth token
   - 写入 `~/.config/cc-reset/env.sh`
   - 同步更新 Claude 全局配置中的 onboarding 状态，避免再次进入首次登录选择界面

如果是 **Claude 订阅登录**（当前默认路径），会写入：

- `CLAUDE_CODE_OAUTH_TOKEN`
- `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`
- `CLAUDE_CODE_OAUTH_SCOPES`

只有在非订阅 / 非 inference scope 的路径下，才会尝试生成 `ANTHROPIC_API_KEY`。

### 4) 激活环境变量

```bash
source ~/.config/cc-reset/env.sh
claude auth status --text
```

`install` 也会把下面这段初始化逻辑追加到 `~/.bashrc`（若存在 `~/.zshrc` 也会同步写入）：

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$HOME/.config/cc-reset/env.sh" ] && . "$HOME/.config/cc-reset/env.sh"
```

## 命令说明

### `install`

```bash
./bin/cc-reset install
./bin/cc-reset install --dry-run
./bin/cc-reset install --no-clipboard
```

- `--dry-run`：只打印计划动作，不真正执行
- 默认会尝试安装 `xclip`，用于 Linux 终端复制登录链接
- 如不需要，可加 `--no-clipboard`

### `doctor`

```bash
./bin/cc-reset doctor
./bin/cc-reset doctor --json
```

检查项：
- OS / package manager
- git / curl / wget / gcc / make
- nvm
- node / npm
- claude

### `login`

```bash
./bin/cc-reset login
./bin/cc-reset login --print-url
./bin/cc-reset login --callback-url 'https://platform.claude.com/oauth/code/callback?code=...&state=...'
./bin/cc-reset login --code-state '<code>#<state>'
./bin/cc-reset login --email you@example.com
./bin/cc-reset login --force
./bin/cc-reset login --no-clipboard
```

说明：
- `--print-url`：只生成登录链接，不进入完成阶段
- `--callback-url`：直接喂给回调 URL
- `--code-state`：如果你拿到的是 `code#state` 形式，也可以直接完成
- `--email`：预填登录邮箱
- 默认会先检查是否已认证；如需强制重新认证，使用 `--force`
- 默认会尝试安装 `xclip`；如不需要，可用 `--no-clipboard`
- 已认证时会输出 PASS/WARN/INFO 风格状态卡片
- `install` / `doctor` / 已认证跳过登录场景都会输出 PASS/WARN/INFO 卡片
- `install --dry-run` 也会输出预览卡片

### `repo-init`

```bash
./bin/cc-reset repo-init
./bin/cc-reset repo-init --remote https://github.com/yiancode/cc-reset.git
```

功能：
- 当前目录未初始化 git 时执行 `git init`
- 配置 `origin`

### `bootstrap-login.sh`

```bash
./scripts/bootstrap-login.sh
./scripts/bootstrap-login.sh -- --email you@example.com
./scripts/bootstrap-login.sh -- --force
./scripts/print-quickstart.sh
```

用途：
- 先跑 `install`
- 紧接着跑 `login`

适合你已经把仓库 clone 下来之后直接一把跑通。

## 设计说明

### 为什么不用本地监听端口接回调？

因为当前目标是 **VPS + SSH** 场景。

v1 优先保证：
- 不依赖本地端口
- 不依赖浏览器自动回调到 VPS
- 用户只需要复制 URL、登录、再粘贴回调 URL

这比自动监听回调更稳，也更容易排错。

### 为什么登录后是写环境变量，不是直接改 Claude 私有状态？

因为这条路径更透明、更可控：
- 不依赖 Claude Code 内部私有存储格式
- 易于审计与备份
- 更适合开源工具维护

登录完成后，`cc-reset` 会写入：

```bash
~/.config/cc-reset/env.sh
```

其中通常包含：

```bash
export CLAUDE_CODE_OAUTH_TOKEN='...'
export CLAUDE_CODE_OAUTH_REFRESH_TOKEN='...'
export CLAUDE_CODE_OAUTH_SCOPES='user:profile user:inference ...'
```

Claude Code 在当前 shell 中读取该环境变量后即可使用。

## 已知限制

- 只支持 yum / dnf
- 需要 Linux
- 当前开发与验证主要面向 OpenCloudOS / RHEL 风格系统
- OAuth 参数基于当前最新 Claude Code 运行时行为实现；如果上游未来调整 OAuth 参数，可能需要同步更新本项目

## 故障排查

### 1. `install` 提示不是 Linux

这是正常保护。  
在 macOS / Windows 上请用：

```bash
./bin/cc-reset install --dry-run
```

### 2. `yum` / `dnf` 不存在

当前版本不支持 apt。请在 yum / dnf 系统上使用。

### 3. `login` 完成后 `claude auth status --text` 仍异常

先确认：

```bash
source ~/.config/cc-reset/env.sh
echo "$CLAUDE_CODE_OAUTH_TOKEN"
echo "$CLAUDE_CODE_OAUTH_REFRESH_TOKEN"
echo "$CLAUDE_CODE_OAUTH_SCOPES"
```

再执行：

```bash
claude auth status --text
```

### 4. 浏览器回调 URL 解析失败

请确认你粘贴的是完整 URL，例如：

```text
https://platform.claude.com/oauth/code/callback?code=...&state=...
```

或者直接粘贴：

```text
<code>#<state>
```

## 开源发布建议

如果你要发布到 GitHub，直接执行：

```bash
./scripts/publish.sh
```

或显式指定 remote：

```bash
./scripts/publish.sh --remote https://github.com/yiancode/cc-reset.git
```

脚本会：
- 初始化 git（如果还没初始化）
- 设置/更新 `origin`
- 跑轻量检查
- 推送当前分支

如果你想手动发布，也可以：

```bash
./bin/cc-reset repo-init --remote https://github.com/yiancode/cc-reset.git
git add .
git commit -m "Bootstrap Claude Code setup and OAuth helper for yum-based VPS

Constraint: v1 is yum-only and SSH-first
Rejected: Local callback listener | adds operational complexity on VPS
Confidence: medium
Scope-risk: moderate
Directive: Keep OAuth constants aligned with current Claude Code runtime behavior
Tested: shell syntax checks and CLI smoke verification
Not-tested: real OAuth exchange on a live subscription account"
git push -u origin main
```

如果本机还没有 GitHub 凭证，`git push` 会失败；这种情况下先完成登录/凭证配置后再推送。

## License

MIT
