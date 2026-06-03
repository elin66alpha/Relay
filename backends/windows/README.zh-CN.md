# Windows 后端

Windows 后端复用 `server/` 中的共享 Node 后端，通过 PowerShell 管理后台进程，并创建一个当前用户的计划任务，让 Relay 在用户登录后自动启动。

## 前置要求

- Windows 10/11，Node.js 18 或更新版本。
- Claude Code / Codex / Antigravity CLI 已安装并在 Windows 上登录完成。
- Cloudflare Tunnel 或 Quick Tunnel 模式需要 `cloudflared`。
- PowerShell。Windows PowerShell 5.1 即可，PowerShell 7 也可以。

Node.js 从 <https://nodejs.org/> 安装。`cloudflared` 可使用 Cloudflare 的 Windows 安装包，或把 `cloudflared.exe` 放到 `PATH` 中。

## 安装

在仓库根目录打开 PowerShell：

```powershell
.\backends\windows\setup.ps1
```

如果当前机器禁止执行脚本，可以先只对当前 PowerShell 会话放开限制，然后重试：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

安装脚本会：

- 在需要时从 `server\.env.example` 创建 `server\.env`；
- 安装后端 npm 依赖；
- 提供直连模式、正式 Cloudflare Tunnel 模式、Quick Tunnel 模式；
- 以后台进程启动后端和可选隧道；
- 注册名为 `Relay Backend` 的当前用户计划任务，用户下次登录后自动启动后端；
- Quick Tunnel 下从隧道日志读取最新的 `trycloudflare.com` 地址；
- 运行 `npm run credential`，在终端显示并保存指向当前公网地址的加密凭证二维码。

## 服务命令

```powershell
.\backends\windows\status.ps1
.\backends\windows\start.ps1
.\backends\windows\stop.ps1
.\backends\windows\uninstall.ps1
```

日志和 PID 文件位置：

```text
%LOCALAPPDATA%\Relay\logs\
%LOCALAPPDATA%\Relay\runtime\
```

## 说明

Windows 脚本不依赖 PM2。平台相关的进程管理放在 `backends/windows/`，HTTP API、凭证、会话与 agent 调度仍保持在共享的 `server/` 中。

Cloudflare Tunnel 和 Quick Tunnel 模式下后端绑定到 `127.0.0.1`，cloudflared 从本机访问后端。若用直连模式（公网 IP/域名），后端绑定到 `0.0.0.0`，对外暴露前请在前面放 HTTPS 反向代理。
