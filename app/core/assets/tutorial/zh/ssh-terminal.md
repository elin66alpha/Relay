---
title: SSH 终端
category: 机器与工具
order: 730
summary: 从机器详情进入交互终端：可恢复的会话、手机按键栏和权限边界。
keywords: ssh, 终端, terminal, shell, pty, ctrl, 按键栏, 命令行
---

在[机器详情](machine-details.md)点「进入SSH」，打开后端机器上的交互终端。它使用后端运行账号的登录 shell，从该账号的主目录开始（隔离安装时从 `workspace/` 开始）。颜色跟随 App 的浅色 / 深色主题。

## 可恢复

每个设备令牌拥有一个终端。返回机器详情不会关闭它，下次「进入SSH」会重新连上；在另一处打开会接管它，而不是新开一个 shell。

断开后终端保留 12 小时，最多 2 MB 输出用于恢复显示；终端内容不写入磁盘。部署方可以用 `TERMINAL_IDLE_TIMEOUT_MS`、`TERMINAL_BUFFER_MAX_BYTES` 调整，用 `RELAY_TERMINAL_SHELL` 选择 shell。

## 手机按键栏

Android 和 iOS 在终端下方提供手机键盘没有的键：Ctrl、Shift、Esc、Tab 和四个方向键。

- Ctrl 和 Shift 只作用于**下一个**按键：点 Ctrl 再输入 `c` 就是 Ctrl+C；再点一次取消。
- Esc、Tab 和方向键立即发送。
- Shift+Tab、Ctrl+← 这类组合和实体键盘一样。

## 权限

终端拥有后端操作系统用户的**全部权限**，不受文件浏览器的路径限制和禁止列表约束。撤销设备令牌会关闭它的终端。

## 安全细节

连接时 App 先用令牌换一个 30 秒内有效、只能用一次的票据，长期令牌不会出现在 WebSocket 地址里。
