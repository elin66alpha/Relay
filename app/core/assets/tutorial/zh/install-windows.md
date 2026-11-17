---
title: 在 Windows 上安装
category: 部署后端
order: 220
summary: 用 setup.cmd 安装、把 CLI 加入 PATH、服务管理、日志与原地升级。
keywords: windows, setup.cmd, powershell, 计划任务, update.cmd, 安装
---

## 安装

1. 从 [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest) 下载 `relay-backend-windows-x64-v<版本>.zip`。注意不要下成 `relay-windows-x64-v<版本>.zip`，那个是桌面客户端。
2. **完整解压**到一个固定、可写的目录（以后不要移动它）。
3. 在该目录打开 PowerShell，运行 `.\setup.cmd` 并选择 `1) Install`。安装是命令行菜单，与 Linux、macOS 相同（双击 `setup.cmd` 也能打开）。

压缩包自带 Node.js 运行时、npm、生产依赖和网页客户端；网页和 API 由同一个 Node.js 进程提供。

## Setup 能做什么

- 安装、重装、卸载、查看状态、管理设备令牌。
- 选择是否提供网页客户端（默认开启）、网络方式，以及[文件访问方式](file-access-mode.md)。隧道模式缺少 `cloudflared` 时会自动下载。
- 用官方 Windows 安装器安装 Claude Code、Codex、Cursor、OpenCode、Hermes 中的任意几个，以及 Antigravity。装好后需要你自己登录或配置。
- 把智能体 CLI 所在的文件夹（例如 Codex 和 OpenCode 所在的 `%APPDATA%\npm`）加入**用户 PATH**；主机没有 Node.js 时也会加入自带的 Node（npm 的命令垫片需要它）。卸载只删除它添加的条目。
- 菜单选项 `t` 会打开一个带后端 PATH 的 PowerShell，并列出每个 CLI 的登录命令。

后端以当前用户的**计划任务**运行，登录 Windows 后自动启动。

## 常用命令

在 Relay 目录下：

| 命令 | 作用 |
|---|---|
| `.\start.cmd` / `.\stop.cmd` | 启动 / 停止 |
| `.\status.cmd` | 查看状态 |
| `.\credential.cmd` | 生成凭证 |
| `.\update.cmd` | 升级到最新版本（用 `SHA256SUMS` 校验），隧道不中断 |
| `.\update.cmd -Archive <zip>` | 用手动下载的压缩包升级 |
| `.\uninstall.cmd` | 卸载服务，保留配置、令牌、凭证、历史和日志 |

从源码仓库运行时，对应脚本是 `.\scripts\install\windows\setup.ps1`、`status.ps1`、`start.ps1`、`stop.ps1`、`uninstall.ps1`。如果 PowerShell 拦截脚本，只对当前窗口放行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 日志

Relay 目录下的 `logs\`：后端和隧道的 `.out` / `.err` 日志。安装过程直接显示在命令行窗口中。PID 文件在 `%LOCALAPPDATA%\Relay\runtime\`。

## 磁盘

Windows 后端会报告所有盘符，文件浏览器第一个路径段可以在 `C:\`、`D:\` 等之间切换，见[浏览文件与切换磁盘](file-browser.md)。
