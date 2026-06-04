# 自有域名与直连模式生产加固指南

[English](production-hardening.md) | [中文 README](../README.zh-CN.md)

Relay 可以放在正式 Cloudflare Tunnel 后面，也可以在公网主机上直连部署。Quick Tunnel
适合试用；生产使用应当有稳定 URL、较小暴露面，以及清楚的恢复路径。

## 推荐形态

- 只使用 HTTPS。正式 Cloudflare Tunnel 在 Cloudflare 侧终止 HTTPS；直连公网主机建议在
  Relay 前面放 Nginx、Caddy 或其他反向代理，并在代理层终止 TLS。
- 除非代理或 tunnel 不在同一台机器，否则让 Relay 只监听本机。优先使用
  `HOST=127.0.0.1` 配合代理/tunnel，而不是直接 `HOST=0.0.0.0`。
- `PUBLIC_BASE_URL` 填用户导入 app 时使用的稳定地址，例如
  `https://agent.example.com`。修改后需要重新生成凭证。
- 不要把 `server/.env`、`server/tokens.json`、`server/credentials/` 放进源码仓库。
  它们包含部署身份、访问 token、加密凭证导出文件。
- 每个用户/设备单独生成凭证。淘汰旧设备时，在 `server/tokens.json` 里吊销对应
  token，不要多人共用一个长期 token。

## 反向代理检查项

- 转发 `GET`、`POST` 以及长连接 `GET /api/events`。
- 对 `/api/events` 和流式 `/api/chat` 响应关闭代理缓冲。
- 请求超时时间要长于 agent 超时。默认 agent 超时是 60 分钟。
- 明确设置上传/下载上限。默认单文件上传 100 MB，下载 300 MB；只有在代理和网络都能承受时，
  才调整 `FILE_UPLOAD_LIMIT`、`DOWNLOAD_MAX_BYTES`。
- 代理层不要做过宽的 CORS 暴露。Relay 的设备 token 是真正的 API 门禁，但收窄代理配置可以减少误暴露。

## 直连公网主机检查项

- 用 PM2、systemd、LaunchAgent 或 Windows 计划任务等方式守护 Node 进程。
- 使用非 root 用户运行，并让该用户只拥有必要的工作目录。
- 防火墙只开放反向代理入口端口，通常是 443。
- 后端端口尽量只在本机可见。如果必须直接暴露，请在边缘层提供 HTTPS，并在测试暴露后轮换凭证。
- 部署变更后，用已认证 app 会话访问 `GET /api/diagnostics`，检查公网 URL、token 状态、
  CLI 可用性、活动请求、存储文件和 workdir 权限。

## 运维检查

- 修改 `PUBLIC_BASE_URL` 后，重新运行凭证脚本，并在 app 里导入新凭证。
- 轮换或吊销 token 后，确认旧设备无法访问，新设备仍能通过 `GET /api/health`。
- 长 agent 任务和文件传输期间观察服务端日志；流式端点应保持连接，而不是提前结束。
- tunnel/代理变更要保留回滚路径：在后端主机上，本地
  `http://127.0.0.1:<PORT>` 应该仍可访问。

