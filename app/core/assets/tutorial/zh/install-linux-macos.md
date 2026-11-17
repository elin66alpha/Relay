---
title: 在 Linux 和 macOS 上安装
category: 部署后端
order: 210
summary: 一行命令安装和升级、安装菜单的每一项、服务管理与日志位置。
keywords: linux, macos, ubuntu, debian, install.sh, pm2, launchd, homebrew, 安装, 升级, 日志
---

Linux 和 macOS 共用同一套脚本（`scripts/install/unix/`），菜单和安装步骤完全一样，只有软件包管理器和服务管理器不同。

| | Linux | macOS |
|---|---|---|
| 补齐系统软件 | `sudo apt-get`（Debian/Ubuntu） | Homebrew |
| 运行服务 | PM2（`relay-server`、`relay-tunnel`） | LaunchAgents（`dev.relay.app.backend`、`dev.relay.app.tunnel`），登录后自启 |
| 日志 | `~/.pm2/logs/relay-server-*.log` | `~/Library/Logs/Relay/backend.*.log` |

## 一行命令安装或升级

```bash
curl -fsSL https://github.com/elin66alpha/Relay/releases/latest/download/install.sh | bash
```

它会下载最新版本，用 `SHA256SUMS` 校验，解压到 `~/relay`（可在提示时修改，或设置 `RELAY_DIR`），然后运行安装。再次运行就是**原地升级**：保留 `server/.env`、令牌、聊天和设置，并重启后端。`RELAY_VERSION=<版本>` 可以安装指定版本。

请以将来运行 Relay 的那个普通用户运行，**不要加 sudo**。

## 系统要求

- Node.js 22+。缺失或过旧时，Linux 会从 NodeSource 安装 Node.js 24，macOS 用 Homebrew 安装当前版本。
- Linux 需要 PM2、Python 3、`make`、C++ 编译器（Debian/Ubuntu 的 `build-essential`）。
- 下载文件夹需要 `zip`。
- 隧道模式需要 `cloudflared`，脚本会按需安装。
- macOS 如果终端模块需要编译，会弹出 Xcode Command Line Tools 安装器。

## 安装菜单

运行 `setup.sh` 会打开菜单：

| 选项 | 作用 |
|---|---|
| 安装 / 重装 | 重装保留令牌、聊天和设置 |
| 卸载 | 移除服务和网页客户端；保留数据、令牌和凭证；会询问是否删除命名隧道及 PM2、`cloudflared`、Node.js |
| 服务状态 | 地址、隧道域名、网页客户端、各 CLI 的安装和登录状态、令牌、文件访问方式 |
| 安装 CLI 智能体 | 列出 Claude Code、Codex、Cursor、OpenCode、Hermes 的安装状态，用官方安装器安装选中的，并打印登录命令 |
| 设备令牌 | 创建、删除、列出令牌，或重新显示二维码 |

安装过程依次询问：端口、网络方式（见[网络方式与 HTTPS](network-modes.md)）、是否在后端地址提供网页客户端（默认是）、文件访问方式（见[文件访问：开放与隔离](file-access-mode.md)）、凭证密码。

## 服务管理

在安装目录（默认 `~/relay`）下：

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

三种方式效果相同：再次运行一行命令；在安装菜单里重装；或在 App 的机器详情里点「更新到 x 并重启」，见[更新后端](backend-update.md)。
