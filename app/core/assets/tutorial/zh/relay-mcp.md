---
title: Relay MCP
category: 进阶
order: 1010
summary: 让你自己的智能体（MCP 客户端）像 App 一样使用 Relay 后端。
keywords: mcp, 机器人, bot, 个人智能体, stdio, RELAY_CREDENTIAL, 自动化
---

`mcp/` 是一个 stdio [MCP](https://modelcontextprotocol.io) 服务器，让个人智能体（例如聊天机器人）像 App 一样使用 Relay 后端。它没有 npm 依赖，运行 MCP 客户端的机器需要 Node.js 22+，不必是后端主机。

它的登录方式和 App 完全一样：一份凭证 JSON 加上它的密码，只通过后端的 HTTP API 通信。

## 配置

**1. 为机器人单独生成凭证**，以便单独撤销。在后端的 `server/` 目录：

```bash
npm run credential -- --label grokbot
```

凭证地址必须固定：命名隧道或其他域名，或者机器人能访问的局域网 / Tailscale 地址。**不接受 Cloudflare 快速隧道**（`*.trycloudflare.com`），因为它每次重启都会变。

**2. 在机器人所在的机器上获取代码**：

```bash
git clone --depth 1 https://github.com/elin66alpha/Relay.git
```

**3. 给机器人添加一个 stdio MCP 服务器**：

| 字段 | 值 |
|---|---|
| command | `node` |
| args | `["<clone>/mcp/index.js"]` |
| env `RELAY_CREDENTIAL` | 凭证 JSON 文本，或 `.relay.json` 文件路径 |
| env `RELAY_CREDENTIAL_PASSPHRASE` | 凭证密码 |
| env `RELAY_WORKDIR`（可选） | 起始工作区，默认用后端的 |
| env `RELAY_MCP_NAME`（可选） | 在机器详情里显示的名称 `Relay MCP (<name>)` |

请把密码放在机器人的密钥存储里，不要放在聊天里或凭证旁边的文件里。

## 能做什么

状态与智能体列表；模型、思考、权限等设置；发送消息、查询任务进度、取消；历史、搜索和导出；会话管理；工作区；浏览和读写文本文件；蜂群（不能运行其他机器上的成员）；额度和定时消息；机器硬件和诊断；在这份凭证自己的终端里输入并读取输出。

不能做的：壁纸、推送注册、切换机器（每台后端配一个 MCP 服务器）、令牌管理，以及 App 本地的设置页。

## 需要知道的行为

- 发送消息后最多等 `waitSeconds`（默认 20 秒），之后返回 `running` 和 `requestId`；后端会继续运行，用任务查询工具轮询直到完成。
- 工作区属于 MCP 进程，切换它不影响其他设备；但**对话是共享的**：App 在同一工作区、智能体和会话里能看到机器人的消息。
- 这份凭证拥有和 App 一样的权限：所有智能体、禁止列表以外的文件和一个 shell。在[机器详情](machine-details.md)撤销它的令牌即可切断。
- 如果机器人本身也是编程智能体，不要让它指向它自己正在工作的目录，否则两个智能体会同时修改同一批文件。
