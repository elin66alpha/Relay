# AgentDeck 后端平台目录

AgentDeck 的后端核心仍然放在 `server/`，不同操作系统的安装和服务管理脚本放在本目录。

- `linux/`：Linux 后端入口，封装现有基于 PM2 的安装流程。
- `macos/`：macOS 后端入口，使用 LaunchAgent 管理 Node 后端。

网络默认走 Cloudflare Quick Tunnel：后端监听 localhost，`cloudflared` 暴露一个临时的 `https://*.trycloudflare.com` URL，凭证二维码指向这个 URL。对已有公网 IP/域名的主机另有直连模式。

Flutter app 在所有后端平台上都调用同一套 HTTP/SSE API。平台目录只负责安装、服务管理、
日志、PATH 和隧道地址发现。
