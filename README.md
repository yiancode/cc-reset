# cc-reset

一个面向 **yum 系 Linux VPS** 的 Claude Code 一键初始化与 OAuth 登录辅助工具。

目标场景：
- 新买的 OpenCloudOS / RHEL 风格 VPS
- 机器上几乎只有 `git`
- 你想尽快把 Claude Code 环境装好，并完成 SSH 场景下的登录

> 当前版本只支持 **yum / dnf**，不支持 `apt`。

---

## 背景说明

Claude Code 在 SSH/VPS 场景下的登录流程与桌面端不同：它无法自动打开浏览器完成 OAuth 回调，用户需要手动复制授权链接、在本地浏览器完成授权、再把回调 URL 粘贴回终端。

`cc-reset` 的目标就是把这个流程自动化：

1. 生成 PKCE OAuth 授权链接
2. 引导用户完成浏览器授权
3. 接收回调参数，完成 token 交换
4. 将凭证写入正确的位置，让 Claude Code 可以直接使用

---

## 问题分析：v0.1.0 的设计缺陷

### 现象

用 `cc-reset login` 登录成功后，`claude` 命令仍然报 **401 Invalid authentication credentials**。即使反复执行 `claude /login` 重新登录，问题依旧复现。

### 根因

v0.1.0 的登录流程如下：

```text
cc-reset login
  └─ OAuth 完成
       └─ 写入 ~/.config/cc-reset/env.sh
            export CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-...'
            export CLAUDE_CODE_OAUTH_REFRESH_TOKEN='sk-ant-ort01-...'
            export CLAUDE_CODE_OAUTH_SCOPES='...'
```

同时，`cc-reset install` 会在 `~/.bashrc` 中追加：

```bash
[ -s "$HOME/.config/cc-reset/env.sh" ] && . "$HOME/.config/cc-reset/env.sh"
```

这导致**每次登录终端，旧 token 都会被自动注入到环境变量**。

问题在于：Claude Code 在读取认证凭证时，**环境变量的优先级高于 `~/.claude/.credentials.json`**。

当 token 过期后：

```text
用户执行 claude /login
  └─ 新 token 写入 ~/.claude/.credentials.json  ✓

但下次打开终端：
  └─ ~/.bashrc 加载 env.sh
       └─ 旧的过期 token 注入环境变量           ✗
            └─ 覆盖了 credentials.json 里的新 token
                 └─ API 请求用旧 token → 401
```

这个问题有以下几个特点，导致难以排查：

- `claude /stats`、`/login` 等本地命令正常，因为它们读取的是 credentials 文件
- 只有实际发起 API 请求时才触发 401
- 每次新开终端都会重新注入旧 token，`unset` 只在当前 session 有效
- `grep ~/.bashrc` 找不到，因为注入逻辑藏在 `env.sh` 的 sourcing 中

### 为什么不直接删掉 env.sh 就好了？

因为 `env.sh` 每次 `cc-reset login` 都会重新生成，且 `.bashrc` 里的 sourcing 是 `install` 写入的，用户通常不知道它的存在。这是一个会反复触发的系统性问题，而不是一次性的配置错误。

---

## 改造说明（v0.2.0）

### 核心思路

**不用环境变量持久化 token，改用 Claude Code 的原生凭证存储。**

Claude Code 有一套内置的凭证管理机制：

```text
~/.claude/.credentials.json
```

格式如下：

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1776265049059,
    "scopes": ["user:inference", "user:profile", "..."],
    "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_20x"
  }
}
```

这套机制的优点：

- Claude Code 会**自动用 refresh token 续期**，无需手动重新登录
- 不依赖环境变量，不会被 `.bashrc` 里的旧值覆盖
- 与 `claude /login` 原生登录写入同一个文件，完全兼容

### 具体改动

**`lib/oauth-helper.mjs`**

- 新增 `writeCredentialsJson()`，将订阅登录的 OAuth token 写入 `~/.claude/.credentials.json`
- 写入前会保留现有 `credentials.json` 中的其他字段，只更新 `claudeAiOauth`
- `writeEnvFile()` 在订阅模式下不再写 `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` / `CLAUDE_CODE_OAUTH_SCOPES`
- 订阅模式下 `env.sh` 只保留用户邮箱、UUID 等非敏感身份元数据
- API key 模式仍写入 `ANTHROPIC_API_KEY`

**`lib/common.sh`**

- `ccr::ensure_shell_init()` 从 shell 启动 block 中移除了 `env.sh` 的 sourcing，只保留 nvm 初始化
- 旧用户升级时会替换已有的 `cc-reset-nvm` block，不再继续保留旧的 `env.sh` 注入逻辑
- 新增 `ccr::claude_credentials_present()`，让 `ccr::is_authenticated()` 和 `doctor` 能识别原生凭证文件

### 兼容性

- **Claude 订阅模式**：登录完成后无需 `source` 任何文件，直接运行 `claude`
- **API key 模式**：仍会写入 `~/.config/cc-reset/env.sh`，但为了避免对订阅模式重新引入旧问题，`install` 不再自动在 shell 启动时 source 这个文件
- 这意味着 API key 模式在新 shell 中需要手动执行：

```bash
source ~/.config/cc-reset/env.sh
```

如果你是从 v0.1.0 升级，`./bin/cc-reset install` 会自动把旧的 shell block 更新为新版本。若你手动写过其他自定义 sourcing 逻辑，再清理一次即可：

```bash
sed -i '/cc-reset/d' ~/.bashrc
source ~/.bashrc
```

---

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
  - **订阅模式 token 写入 `~/.claude/.credentials.json`**
  - **API key 模式写入 `~/.config/cc-reset/env.sh`**
  - 已认证时自动跳过重复登录
- 提供 git 仓库初始化 / remote 配置辅助
- 提供一键发布脚本
- 提供 `CHANGELOG.md`

## 版本记录

- 变更记录见：`CHANGELOG.md`

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
./bin/cc-reset quickstart
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
   - 订阅模式写入 `~/.claude/.credentials.json`
   - API key 模式写入 `~/.config/cc-reset/env.sh`
   - 同步更新 Claude 全局配置中的 onboarding 状态

### 4) 验证登录状态

```bash
claude auth status --text
./bin/cc-reset doctor
```

如果是 API key 模式，再执行：

```bash
source ~/.config/cc-reset/env.sh
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
- `~/.claude/.credentials.json` 是否存在

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

### `quickstart`

```bash
./bin/cc-reset quickstart
./bin/cc-reset quickstart --email you@example.com
./bin/cc-reset quickstart --force
```

### `repo-init`

```bash
./bin/cc-reset repo-init
./bin/cc-reset repo-init --remote https://github.com/yiancode/cc-reset.git
```

## 故障排查

### 1. 登录后仍然 401

检查是否有旧的环境变量残留（v0.1.0 遗留问题）：

```bash
env | grep CLAUDE_CODE_OAUTH
```

如果有输出，说明当前 shell 仍加载着旧值。处理方式：

```bash
unset CLAUDE_CODE_OAUTH_TOKEN
unset CLAUDE_CODE_OAUTH_REFRESH_TOKEN
unset CLAUDE_CODE_OAUTH_SCOPES
exec "$SHELL" -l
```

然后重新运行：

```bash
./bin/cc-reset login --force
```

### 2. `install` 提示不是 Linux

在 macOS / Windows 上请用 `--dry-run` 预览：

```bash
./bin/cc-reset install --dry-run
```

### 3. `yum` / `dnf` 不存在

当前版本不支持 apt，请在 yum / dnf 系统上使用。

### 4. 浏览器回调 URL 解析失败

请确认你粘贴的是完整 URL：

```text
https://platform.claude.com/oauth/code/callback?code=...&state=...
```

或者直接粘贴 `<code>#<state>` 形式。

## 设计说明

### 为什么 token 写入 credentials.json 而不是环境变量？

环境变量持久化 token 有一个根本性的缺陷：**过期的 token 会一直存在于 shell 环境中，并覆盖通过其他方式获取的新 token**。

Claude Code 原生的 `~/.claude/.credentials.json` 支持 refresh token 自动续期，token 过期后会静默刷新，无需用户手动干预。写入这个文件与 `claude /login` 原生登录完全兼容，是更正确、更稳定的做法。

### 为什么不用本地监听端口接回调？

因为目标是 **VPS + SSH** 场景，本地端口在远程服务器上无法被浏览器回调访问。手动粘贴回调 URL 虽然多一步操作，但在 SSH 场景下是最通用、最不依赖额外配置的方案。

## License

MIT
