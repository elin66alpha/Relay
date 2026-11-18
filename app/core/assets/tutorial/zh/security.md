---
title: 安全须知
category: 进阶
order: 1020
summary: Relay 保护了什么、没保护什么，以及公开部署前的检查清单。
keywords: 安全, security, https, 令牌, 沙箱, 权限, 加固, 生产
---

## Relay 保护了什么

- 每个 HTTP API 请求都需要可撤销的令牌；错误尝试有限流。
- 凭证用 PBKDF2-HMAC-SHA256 和 AES-256-GCM 加密。
- 终端和浏览器用 30 秒有效、只能用一次的票据连接，长期令牌不出现在 WebSocket 地址里。
- 文件 API 禁止访问 Relay、SSH、Claude、Codex、Cursor、Antigravity 的敏感文件，可以用 `RELAY_FS_ROOTS` 进一步限制，见[文件访问：开放与隔离](file-access-mode.md)。
- 额度查询可能读取和刷新主机上的 OAuth 文件，但令牌值不会发给 API 或 App。
- 其他机器的凭证只在请求时由 App 附带，后端不保存，见[其他机器上的成员](swarm-remote-members.md)。

## Relay 不是沙箱

智能体和终端拥有后端操作系统用户的全部权限。路径限制只作用于文件浏览器，不约束智能体执行的命令。

## 公开部署前

- 在命名隧道或反向代理（Caddy、Nginx 等）处终止 TLS。
- 隧道或同机代理时保持 `HOST=127.0.0.1`；直连只在 HTTPS 和防火墙之后暴露。
- `PUBLIC_BASE_URL` 设为客户端导入的确切地址；它变化后重新生成凭证。
- 用非 root 的受限用户运行 Relay，并限制它能访问的文件。
- 设置 `RELAY_FS_ROOTS`。
- 每台设备一份凭证；不用的设备先撤销再删除，见[设备令牌](device-tokens.md)。
- 网页版只在可信设备、最好是专用浏览器配置里使用。

详细说明见仓库里的 `docs/SECURITY.md` 和 `docs/handbook.md`。
