---
title: 更新后端
category: 部署后端
order: 260
summary: 在 App 里一键更新并重启后端，或在主机上手动升级。
keywords: 更新, 升级, update, 版本, 重启, self-update
---

## 在 App 里更新

打开[机器详情](machine-details.md)，「Relay 后端」一栏显示后端当前版本。有更新的版本时会出现 **更新到 \<版本\> 并重启**。

确认后，后端下载最新版本并重启。**正在运行的任务和终端会中断**，所以先等任务结束。更新保留 `server/.env`、令牌、聊天和设置。

它使用和主机上相同的升级方式：Linux 和 macOS 运行包内的 `scripts/install/unix/update.sh`，Windows 运行 `update.cmd`。升级输出写到系统临时目录的 `relay-update.log`。十分钟后后端仍是旧版本时，App 会提示更新没有完成，并重新提供更新按钮；原因在这个日志里。

以下情况不能从 App 更新：

- 后端是从 git 仓库副本运行的（请用 `git pull` 自行更新）。
- 十分钟内已经发起过一次更新。

## 在主机上更新

| 系统 | 命令 |
|---|---|
| Linux / macOS | 在 Relay 目录运行 `./scripts/install/unix/update.sh` |
| Windows | 在 Relay 目录运行 `.\update.cmd` |

已经是最新版本时，两者都什么都不做。它们先装好新版本的依赖再动现有文件；新版本 30 秒内没有在端口上应答时，会换回旧版本并重新启动。在 Linux 和 macOS 上，被打断的更新（比如突然断电）会在下次运行时自动撤销。

在 Windows 上，如果仍有其他进程从 Relay 目录运行或占用后端端口（例如用 `npm start` 启动的后端，或残留的 agent），更新不做任何改动，并列出该进程，停止它后再更新即可。

从 0.1.12 或更早版本升级时，先将新包解压到另一个目录。在新目录运行 `RELAY_DIR="/原安装目录的绝对路径" ./scripts/install/unix/update.sh`，把路径换成现有 Relay 安装目录。

## 客户端版本

App 本身的更新见[更新 App](app-update.md)。新客户端可以连接旧后端；旧后端缺少新接口时，App 会提示后端版本过旧。
