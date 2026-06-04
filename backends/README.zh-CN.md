# Relay 后端平台目录

Relay 的后端核心仍然放在 `server/`，不同操作系统的安装和服务管理脚本放在本目录。

- `linux/`：Linux 后端入口，封装现有基于 PM2 的安装流程。
- `macos/`：macOS 后端入口，使用 LaunchAgent 管理 Node 后端。
- `windows/`：Windows 后端入口，使用 PowerShell 后台进程和当前用户计划任务。

安装脚本提供三种网络模式：不用隧穿/公网直连、稳定域名的正式 Cloudflare Tunnel、以及临时 `https://*.trycloudflare.com` 的 Cloudflare Quick Tunnel 快速试用。

Flutter app 在所有后端平台上都调用同一套 HTTP/SSE API。平台目录只负责安装、服务管理、
日志、PATH 和隧道地址发现。
