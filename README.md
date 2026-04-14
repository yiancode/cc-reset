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
- 提供 git 仓库初始化 / remote 配置辅助

## 项目结构

```text
bin/cc-reset          # 主 CLI
lib/common.sh         # shell 公共函数
lib/oauth-helper.mjs  # OAuth / PKCE helper
```

## 快速开始

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
   - 调用 Anthropic OAuth API 生成可用 API key
   - 写入 `~/.config/cc-reset/env.sh`

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
```

- `--dry-run`：只打印计划动作，不真正执行

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
```

说明：
- `--print-url`：只生成登录链接，不进入完成阶段
- `--callback-url`：直接喂给回调 URL
- `--code-state`：如果你拿到的是 `code#state` 形式，也可以直接完成
- `--email`：预填登录邮箱

### `repo-init`

```bash
./bin/cc-reset repo-init
./bin/cc-reset repo-init --remote https://github.com/yiancode/cc-reset.git
```

功能：
- 当前目录未初始化 git 时执行 `git init`
- 配置 `origin`

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

其中包含：

```bash
export ANTHROPIC_API_KEY='...'
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
echo "$ANTHROPIC_API_KEY"
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

如果你要发布到 GitHub：

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
