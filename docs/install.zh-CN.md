# 后端安装

[English](install.md) · [生产部署手册](handbook.md#production-deployment)

Relay 在所有后端操作系统上使用同一个 Node.js 服务和同一套 HTTP/SSE API。`scripts/install/`
下的脚本只负责各平台的依赖安装、进程管理、日志和可选 Cloudflare Tunnel。Linux 和 macOS
共用 `scripts/install/unix/` 中的同一套实现，问题和顺序完全一样，只有包管理器和服务管理器不同。

## 前置要求

- Node.js 22 或更新版本。
- 后端至少安装一个支持的 CLI：Claude Code、Codex、Cursor、OpenCode 或 Hermes。
- 每个 CLI 都必须直接在后端主机上完成认证或 provider 配置。Relay 只报告状态，
  不执行 OAuth 登录，也不收集 provider 密钥。
- Unix 主机下载文件夹时需要 `zip`。Linux 安装还需要 PM2、Python 3、`make` 和
  C++ 编译器，以编译终端的 PTY 依赖。
- 只有正式 Cloudflare Tunnel 或 Quick Tunnel 模式需要 `cloudflared`。
- 在 Debian 和 Ubuntu 上，Linux 安装脚本会检查上面除 agent CLI 以外的所有项，包括
  Node.js 版本，确认一次后用 `sudo apt-get` 安装缺少的软件：Node.js 缺失或低于 22
  时从 NodeSource 安装 Node.js 24；选择隧道模式时从 Cloudflare 发布的 `.deb`
  安装 `cloudflared`。请用将来运行 Relay 的普通用户执行，不要加 `sudo`。
- 在 macOS 上，安装脚本确认一次后用 Homebrew 做同样的事：Node.js 缺失或低于 22 时安装
  当前版本，以及 `zip`，选择隧道模式时安装 `cloudflared`。没有 Homebrew 时会列出需要
  安装的软件。终端的 PTY 依赖需要编译时，会打开 Xcode Command Line Tools 安装程序。
- 将现有 Relay 升级到 0.1.10 或更新版本前，请先把 Node.js 更新到 22 或更新版本。
  升级脚本会在替换文件前检查；版本过低时不会改动现有安装。

## 安装

Linux 和 macOS 共用 `relay-backend-linux-macos-v<版本>.tar.gz`。从 [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest) 下载后，对照 `SHA256SUMS` 中的同名记录校验文件。解压到固定、可写的目录，进入包含 `server/` 的文件夹，运行 `./install.sh`。

需要升级时，在安装目录运行 `./scripts/install/unix/update.sh`，或在 App 的机器详情中选择「更新并重启」。升级脚本按发行版的 `SHA256SUMS` 校验压缩包，保留配置、令牌和聊天。

从 0.1.12 或更早版本升级时，先将新包解压到另一个目录。在新目录运行 `RELAY_DIR="/原安装目录的绝对路径" ./scripts/install/unix/update.sh`，把路径换成现有 Relay 安装目录。

使用仓库副本时，在仓库根目录运行一个命令：

| 后端系统 | 命令 | 服务管理 |
|---|---|---|
| Linux | `./scripts/install/linux/setup.sh` | PM2 |
| macOS | `./scripts/install/macos/setup.sh` | 当前用户 LaunchAgent |
| Windows | `.\scripts\install\windows\setup.ps1` | 当前用户计划任务 |

安装脚本会按需创建 `server/.env`、安装服务端依赖、配置网络模式、启动服务并生成加密
凭证。然后在 app 中导入生成的 `.relay.png` 或 `.relay.json`，输入生成时设置的密码。

在 Linux 和 macOS 上，`setup.sh` 会打开同一个菜单：安装、重新安装（保留令牌、聊天和设置）、卸载、
查看服务信息（地址、隧道域名、Web 前端、各 agent 的安装和登录状态、令牌）、安装 agent
CLI，以及新建、删除、列出或重新展示设备令牌。安装 agent CLI 会列出 Claude Code、Codex、
Cursor、OpenCode 和 Hermes 的安装状态（查找位置与后端一致：PATH、`~/.local/bin`、
`~/.opencode/bin`），用各 CLI 的官方安装方式安装你选的几个（Codex 用
`npm install -g @openai/codex`），并打印登录命令；Relay 不会替 CLI 登录。安装流程里也
有这一步。重新展示会沿用原令牌，并要求设置新的二维码密码，因为旧密码
不会保存。安装和重新安装时会询问是否在后端地址上提供 Web 前端（默认提供），然后询问文件访问方式：

- **开放**（默认）：agent 和文件浏览器能访问后端用户可访问的所有文件。
- **隔离**：工作目录、文件浏览器和 SSH 的起始目录都限制在安装目录下的 `workspace/` 中，
  agent 也不再提供完全自动 / 不受沙箱限制的权限
  档位。安装脚本把该目录写入 `server/.env` 的 `RELAY_WORKSPACE_ROOT`。这是 Relay 自己的路径
  策略，不是操作系统级沙箱：agent CLI 和终端仍以后端用户身份运行。

再次安装或重新安装时默认沿用当前选择；服务信息中以 `File access` 显示。卸载会保留
`workspace/` 及其中的文件。

源码安装包（`relay-backend-linux-macos-v<版本>.tar.gz`）在 `app/shell/build/web` 中自带编译好的
Web 前端；除非 `server/.env` 设置了 `RELAY_SERVE_WEB=0`，后端会在 `/` 上提供它。`/api`
下的接口始终需要设备令牌。Windows 后端 ZIP 也包含相同的 Web 前端：

- Linux、macOS 和 Windows 安装会询问是否提供 Web 前端；卸载会删除它，同时保留后端状态。
  Windows 的 Web 与 API 共用一个 Node.js 进程，不需要额外的 Web 服务器。
- 源码仓库需要先运行 `flutter build web` 才有。

### 网络模式

1. **直连：** 使用自己可访问的地址。服务会绑定 `0.0.0.0`；公开暴露前必须在前面
   配置 HTTPS。
2. **正式 Cloudflare Tunnel：** 使用 Cloudflare zone 下的稳定域名，服务保持绑定
   `127.0.0.1`。
3. **Cloudflare Quick Tunnel：** 适合试用。重启后 `trycloudflare.com` 地址可能变化，
   地址变化时需要重新生成并导入凭证。先从服务日志找到新地址，再在仓库根目录运行
   `npm --prefix server run credential -- --url https://新地址`。
4. **Tailscale。** Relay 只监听检测到的 tailnet IPv4。原生客户端可以通过 WireGuard 使用 `http://<tailscale-ip>:<端口>`。Web 客户端需要 HTTPS 才能保存凭证。请先配置使用受信任证书的反向代理，让它在 443 端口接收 HTTPS 并转发到该 tailnet IP 和后端端口，再在安装时填写代理主机名。用浏览器打开这个 HTTPS 地址并导入生成的凭证。主机名留空将关闭 Web，仅供原生客户端连接。 Tailscale 不可用时会返回网络菜单。

## 服务管理

### Linux

```bash
./scripts/install/linux/status.sh
./scripts/install/linux/start.sh
./scripts/install/linux/stop.sh
./scripts/install/linux/uninstall.sh
```

这些脚本封装 PM2，也可以继续直接使用 PM2 命令：

```bash
pm2 list
pm2 logs relay-server
pm2 restart relay-server --update-env
pm2 logs relay-tunnel
```

Linux 安装需要 PM2（`npm install -g pm2`）。进程名为 `relay-server`；隧道模式还会创建
`relay-tunnel`。日志位于 `~/.pm2/logs/`，文件名为 `relay-server-*.log` 和
`relay-tunnel-*.log`。`uninstall.sh` 会删除 PM2 进程和 Web 前端，询问是否删除正式
Cloudflare Tunnel，并逐项询问是否卸载 PM2、`cloudflared` 和 Node.js；后端数据、令牌和
凭证保留不动。
交互终端的 PTY 依赖会在 Linux 上本地编译，因此首次安装还需要 Python 3、
`make` 和 C++ 编译器（Debian/Ubuntu 可安装 `build-essential`）。如果客户端需要下载
文件夹，还要安装 `zip`。

### macOS

```bash
./scripts/install/macos/status.sh
./scripts/install/macos/start.sh
./scripts/install/macos/stop.sh
./scripts/install/macos/uninstall.sh
```

它们就是 Linux 的那组脚本，只是用 launchd 代替 PM2：后端以及隧道模式下的隧道分别以
LaunchAgent `dev.relay.app.backend` 和 `dev.relay.app.tunnel` 运行，位于
`~/Library/LaunchAgents`，登录时启动，退出后自动重启。日志在 `~/Library/Logs/Relay/` 下，
文件名为 `backend.*.log` 和 `tunnel.*.log`。生成的服务 PATH 已包含常见 Homebrew 和用户
bin 路径。`uninstall.sh` 会删除 LaunchAgent 和 Web 前端，询问是否删除正式 Cloudflare
Tunnel，并逐项询问是否卸载 Homebrew 安装的 `cloudflared` 和 Node.js；后端数据、令牌和凭证
保留不动。

### Windows

每个 release 的 `relay-backend-windows-x64-v<版本>.zip` 包含 Node.js、npm、按锁文件安装的
生产依赖和 Web 前端。将整个 ZIP 解压到固定、可写的目录，在该目录运行 `.\setup.cmd`。
与 Linux、macOS 一样只有命令行安装：菜单相同（安装、重装、卸载、状态查询、CLI 安装和
设备令牌管理），安装同样分六步，包括开放/隔离的文件访问选择。Web 默认开启；隧道模式缺少 `cloudflared`
时自动下载；五个 CLI 可选用官方 Windows 安装器安装，之后由你自行登录或配置。安装器会把装有
agent CLI 的目录（如 `%APPDATA%\npm`）追加到用户 PATH，主机没有 Node 时再加上包内 Node，
之后新开的终端即可直接调用；菜单选项 `t` 可立即打开一个。卸载只移除安装器添加的条目。包内 `README.md`
说明安装与升级；`.\start.cmd`、`.\stop.cmd`、`.\status.cmd`、`.\credential.cmd` 和
`.\uninstall.cmd` 是下面相同服务脚本的入口，`.\update.cmd` 把安装原地升级到最新版本。计划任务在当前用户登录时启动。

```powershell
.\scripts\install\windows\status.ps1
.\scripts\install\windows\start.ps1
.\scripts\install\windows\stop.ps1
.\scripts\install\windows\uninstall.ps1
```

日志位于 Relay 目录下的 `logs\`（后端和隧道的 `.out`/`.err` 日志）；PID 文件位于 `%LOCALAPPDATA%\Relay\runtime\`。如果 PowerShell
阻止脚本执行，只为当前会话临时放开：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

三个平台的卸载脚本都只移除受管理的服务，配置、token、凭证、历史和日志会保留，需按需
手动清理。

## 手动启动

开发或排障时可以绕过平台服务脚本：

```bash
cd server
npm install
cp .env.example .env
npm start
```

在这台主机上完成所选 agent CLI 的认证，再用 `npm run credential` 单独生成凭证。
配置项见 `server/.env.example`，生产加固见技术手册。
