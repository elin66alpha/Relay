---
title: 在 Linux 和 macOS 上安装
category: 部署后端
order: 210
summary: 从压缩包安装和原地升级、安装菜单的每一项、服务管理与日志位置。
keywords: linux, macos, ubuntu, debian, install.sh, pm2, launchd, homebrew, 安装, 升级, 日志
---

Linux 和 macOS 共用同一套脚本（`scripts/install/unix/`），菜单和安装步骤完全一样，只有软件包管理器和服务管理器不同。

| | Linux | macOS |
|---|---|---|
| 补齐系统软件 | `sudo apt-get`（Debian/Ubuntu） | Homebrew |
| 运行服务 | PM2（`relay-server`、`relay-tunnel`），开机由 PM2 的 systemd 服务拉起 | LaunchAgents（`dev.relay.app.backend`、`dev.relay.app.tunnel`），登录后自启 |
| 日志 | `~/.pm2/logs/relay-server-*.log` | `~/Library/Logs/Relay/backend.*.log` |

## 从后端包安装

从 [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest) 下载 `relay-backend-linux-macos-v<版本>.tar.gz`，解压到固定、可写的目录，进入包含 `server/` 的文件夹，运行 `./install.sh`。

请以将来运行 Relay 的那个普通用户运行，**不要加 sudo**。

## 系统要求

- Node.js 22+。缺失或过旧时，Linux 会从 NodeSource 安装 Node.js 24，macOS 用 Homebrew 安装当前版本。
- Linux 需要 PM2、Python 3、`make`、C++ 编译器（Debian/Ubuntu 的 `build-essential`）。
- 下载文件夹需要 `zip`。
- 隧道模式需要 `cloudflared`，脚本会按需安装。
- macOS 的终端模块自带预编译版本；只有它加载失败、需要编译时，才会弹出 Xcode Command Line Tools 安装器。

安装脚本在请求 `sudo` 或使用 Homebrew 之前，会先说明要装什么。Linux 安装时还会询问是否开机自动启动 Relay（`pm2 startup`，需要一次 `sudo`）；没有 systemd 的主机，每次开机后要运行 `start.sh`。macOS 的 LaunchAgents 在登录后启动，所以 Mac 重启后要等有人登录。用 nvm、fnm 或 Volta 装的 Node.js 也可以：LaunchAgent 会用完整路径运行同一个 `node`。

## 安装菜单

运行 `setup.sh` 会打开菜单：

| 选项 | 作用 |
|---|---|
| 安装 / 重装 | 重装保留令牌、聊天和设置 |
| 卸载 | 移除服务和网页客户端；保留数据、令牌和凭证；会询问是否删除命名隧道及 PM2、`cloudflared`、Node.js |
| 服务状态 | 地址、隧道域名、网页客户端、各 CLI 的安装和登录状态、令牌、文件访问方式 |
| 安装 CLI 智能体 | 列出 Claude Code、Codex、Cursor、OpenCode、Antigravity、Hermes 在后端看来的安装状态，用官方安装器安装选中的，并打印登录命令 |
| 设备令牌 | 创建、删除、列出令牌，或重新显示二维码 |

安装过程依次询问：要安装哪些 CLI 智能体、是否在后端地址提供网页客户端（默认是）、文件访问方式（见[文件访问：开放与隔离](file-access-mode.md)）、端口（默认 8787）、网络方式（见[网络方式与 HTTPS](network-modes.md)）、凭证密码。本机已连上 Tailscale 时，网络方式默认选 Tailscale，否则默认 Quick Tunnel。

Quick Tunnel 的 `trycloudflare.com` 地址在隧道每次重启后都会变。安装结束时会提醒这一点；之后在菜单里选 **9**，用当前地址重新显示令牌的二维码，再在每台设备上扫一次。

如果菜单提示 Relay 是从另一个文件夹安装的（比如把新版本解压到了旧版本旁边），请用它打印的 `update.sh` 命令升级那个安装。在新文件夹里重装会从头开始，没有原来的令牌和聊天。

## 服务管理

在安装目录下：

```bash
./scripts/install/linux/status.sh
./scripts/install/linux/start.sh
./scripts/install/linux/stop.sh
./scripts/install/linux/uninstall.sh
```

macOS 把 `linux` 换成 `macos`。Linux 上也可以直接用 PM2：

```bash
pm2 list
pm2 logs relay-server
pm2 restart relay-server --update-env
```

## 升级

需要升级时，在安装目录运行 `./scripts/install/unix/update.sh`，或在 App 的机器详情中选择「更新并重启」。升级脚本按发行版的 `SHA256SUMS` 校验压缩包，保留配置、令牌和聊天。已经是最新版本时它什么都不做；新版本起不来时会换回旧版本。见[更新后端](backend-update.md)。
