---
title: 网络方式与 HTTPS
category: 部署后端
order: 230
summary: 直连、Cloudflare 命名隧道、快速隧道、Tailscale 的区别，以及反向代理的要求。
keywords: 网络, 隧道, cloudflare, tunnel, trycloudflare, https, 反向代理, caddy, nginx, 直连, tailscale
---

安装时要选择 App 怎么访问后端。凭证里保存的就是这个地址（`PUBLIC_BASE_URL`），地址变了就要重新生成并导入凭证。

## 四种方式

**1. 直连**

后端监听 `0.0.0.0`，你填写一个客户端设备能访问到的地址，例如局域网 IP、Tailscale 地址，或你自己反向代理后的域名。

- 其他设备不能用 `localhost` 访问你的主机。
- 公开到互联网前，请在前面加 HTTPS 和防火墙。用 `http://` 公网地址时后端会给出警告，但不会阻止。

**2. Cloudflare 命名隧道**

使用你在 Cloudflare 上的域名，地址稳定并自带 HTTPS，后端只监听 `127.0.0.1`。适合长期使用。

**3. Cloudflare 快速隧道**

不需要域名，最快上手。但 `trycloudflare.com` 地址在 `cloudflared` 重启后可能改变。变化后，在服务日志里找到新地址，然后在仓库根目录运行：

```bash
npm --prefix server run credential -- --url https://新地址
```

再把新凭证导入 App。[Relay MCP](relay-mcp.md) 不接受快速隧道地址。

**4. Tailscale**

Relay 只监听检测到的 tailnet IPv4。原生客户端可以通过 WireGuard 使用 `http://<tailscale-ip>:<端口>`。Web 客户端需要 HTTPS 才能保存凭证。请先配置使用受信任证书的反向代理，让它在 443 端口接收 HTTPS 并转发到该 tailnet IP 和后端端口，再在安装时填写代理主机名。用浏览器打开这个 HTTPS 地址并导入生成的凭证。主机名留空将关闭 Web，仅供原生客户端连接。

- 每台使用 Relay 的手机或电脑都要装 Tailscale，并登录同一个 tailnet。
- 没装 Tailscale 或没登录时，安装脚本会提示，并重新显示菜单，你可以先去安装，或改选其他方式。

## 网页客户端与 HTTPS

后端可以在同一地址提供网页客户端（安装时选择，默认开启）。通过 HTTPS 打开的网页版也必须连接 HTTPS 后端，否则浏览器会拦截。

## 使用自己的反向代理

如果用 Caddy、Nginx 等放在后端前面：

- 后端保持 `HOST=127.0.0.1`。
- 不要缓冲 `/api/events`、`/api/chat`、`/api/group/chat` 的 SSE 响应。
- 为 `/api/terminal/connect` 和 `/api/browser/connect` 转发 WebSocket 的 `Upgrade` / `Connection` 头；不要记录它们的 `ticket` 参数。
- 超时时间要长于 `AGENT_TIMEOUT_MS`（默认 60 分钟）。
- 用 `X-Forwarded-For` 传递真实客户端地址（只信任本机代理）。
- 上传 100 MB、下载 300 MB 的默认上限要和代理一致。

## 限流

普通 API 每个 IP 每分钟 600 次；令牌错误每个 IP 每分钟 15 次。聊天流和文件传输不计入普通次数，但同样需要令牌。
