---
title: 文件访问：开放与隔离
category: 部署后端
order: 240
summary: 安装时的文件访问选择、RELAY_FS_ROOTS，以及始终受保护的敏感路径。
keywords: 隔离, 开放, isolated, workspace, RELAY_WORKSPACE_ROOT, RELAY_FS_ROOTS, 权限, 敏感文件, denylist
---

## 安装时的两个选项

| 选项 | 效果 |
|---|---|
| **开放**（默认） | 智能体和文件浏览器能访问后端用户能访问的所有文件 |
| **隔离** | 工作区、文件浏览器和 SSH 的起始目录都限制在安装目录下的 `workspace/`（一行命令安装时是 `~/relay/workspace`）；智能体不再提供「完全自动 / 不受沙箱限制」的权限档 |

隔离会写入 `server/.env` 的 `RELAY_WORKSPACE_ROOT`。重装时会把当前选择作为默认值；「服务状态」里显示为 `File access`。卸载会保留 `workspace/` 和里面的文件。

> 隔离是 Relay 自己的路径策略，**不是操作系统沙箱**。CLI 智能体和终端仍以后端用户身份运行。

隔离模式下，文件浏览器不提供切换磁盘的菜单。

## 进一步限制：RELAY_FS_ROOTS

在 `server/.env` 里把 `RELAY_FS_ROOTS` 设为允许访问的绝对路径，文件 API 就只能访问这些目录。未设置时，除了下面的内置禁止列表，文件 API 可以访问整个文件系统。

## 始终禁止访问的路径

无论哪种模式，文件浏览器、预览和下载都不能读取：

- Relay 的令牌文件、`.env`、生成的凭证目录、推送令牌存储、FCM 服务账号密钥
- `~/.ssh`
- Claude Code 的 OAuth 凭据、Codex 的登录文件、Cursor 的 `auth.json`、Antigravity 的登录文件、Relay 自己的 Cursor 配置目录 `server/cursor-config/`
- 以上文件名后加点的同名备份，例如 `.env.bak-x`、`tokens.json.bak`

打包下载文件夹时，如果里面含有禁止的路径，整个下载会被拒绝。

这个列表不是通用的密钥扫描器，不覆盖所有第三方 CLI 的配置。生产环境请配合 `RELAY_FS_ROOTS` 和受限用户，见[安全须知](security.md)。
