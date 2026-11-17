---
title: 智能体状态与登录
category: 智能体
order: 410
summary: 状态灯的含义、为什么 Relay 不替你登录，以及重新检查和更新 CLI。
keywords: 状态, 登录, login, 认证, 未安装, 未登录, 重新检查, recheck, 状态灯, 更新 CLI
---

## 所有登录都在主机上完成

Relay 从不远程登录 CLI，也不收集 provider 密钥。每个 CLI 都要在**后端主机**上用它自己的方式登录或配置。Relay 只读取登录状态，并把规范化后的状态发给 App；账号身份和凭据值不会离开后端。

| 智能体 | 主机上的准备 |
|---|---|
| Claude Code | 用 `claude` 登录 |
| Codex | `codex login`，或 API key 等方式 |
| Cursor | `agent login`，或设置 `CURSOR_API_KEY` |
| Antigravity | `agy acp --login` |
| OpenCode | 在主机的 OpenCode 里配置 provider |
| Hermes | 在主机的 Hermes 里配置模型和密钥 |

## 状态灯

侧边栏每个智能体右侧有一到两个小灯：

- 第一个：是否已安装。
- 第二个（Claude Code、Codex、Cursor、Antigravity 等需要登录的）：登录是否就绪。

不可用的智能体收进侧边栏末尾「另有 n 个不可用」；点它会提示原因，比如「未安装在后端主机上」或「需要先在后端主机上登录」。

## 机器详情里的 CLI 智能体

[机器详情](machine-details.md)列出每个智能体的安装、登录和可用状态。在主机上完成登录后点「重新检查」。

- Codex 的「重新检查」会实际向它的 app-server 验证当前登录；网络或验证出错时显示为检查错误，不一定代表要重新登录。
- 各 CLI 都会自己续期登录，所以 Relay 不显示登录到期倒计时。

## CLI 在哪里被找到

后端按 PATH 查找，再查常见的用户安装位置（如 `~/.local/bin`、`~/.opencode/bin`），结果缓存一分钟。装了却显示未安装时，确认运行后端的那个用户能找到它。Windows 的 Setup 会把 CLI 所在目录加入用户 PATH。

## 更新 CLI

在聊天输入框的 **+** 菜单里点「更新 CLI」，会在主机上运行这个 CLI 的自更新（一两分钟），完成后刷新模型列表。也可以用安装菜单的「安装 CLI 智能体」安装缺少的 CLI。
