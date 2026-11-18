---
title: 连接排错
category: 部署后端
order: 270
summary: 解密失败、连接失败、智能体不可用时，按顺序检查什么。
keywords: 排错, 故障, 连接失败, 解密失败, 日志, 401, troubleshooting, 无法连接
---

## 第一步：分清错误类型

| 现象 | 方向 |
|---|---|
| 凭证解密失败 | 密码或凭证文件不对 |
| 令牌被拒绝 | 令牌被撤销，或已生成新凭证。重新生成并导入 |
| 无法解析地址、端口拒绝、网络不可达 | 后端服务、端口、防火墙、地址 |
| 已连接但智能体不可用 | 主机上 CLI 的安装和登录 |

## 后端是否在运行

在安装目录运行状态命令：

| 系统 | 命令 |
|---|---|
| Linux | `./scripts/install/linux/status.sh` |
| macOS | `./scripts/install/macos/status.sh` |
| Windows | `.\status.cmd` 或 `.\scripts\install\windows\status.ps1` |

## 查看日志

| 系统 | 位置 |
|---|---|
| Linux | `pm2 logs relay-server`，文件在 `~/.pm2/logs/` |
| macOS | `~/Library/Logs/Relay/` |
| Windows | Relay 目录下的 `logs\` |

## 地址问题

- 用快速隧道时，地址重启后会变。从日志找到新地址，重新生成凭证，见[网络方式与 HTTPS](network-modes.md)。
- 其他设备不能用 `localhost` 访问后端。
- HTTPS 网页客户端必须连接 HTTPS 后端。

## 智能体不可用

1. 在主机终端直接运行那个 CLI，确认能对话。
2. 确认 CLI 在后端能找到的位置（PATH、`~/.local/bin`、`~/.opencode/bin` 等）。Windows 可用 Setup 的「Open terminal」检查。
3. 回到[机器详情](machine-details.md)点「重新检查」。

Codex 的「重新检查」会实际验证登录；网络或验证错误不一定代表需要重新登录。

## 其他

- **后端版本过旧**：App 调用了旧后端没有的接口，更新后端即可，见[更新后端](backend-update.md)。
- **工作路径无法修改**：有任务正在运行，等它结束再改。
- 机器详情的「状态」一栏列出工作目录是否存在、是否可写，以及各个存储文件的状态，可以截图用于排查。
