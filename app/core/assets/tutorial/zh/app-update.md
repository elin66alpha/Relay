---
title: 更新 App
category: 应用设置
order: 930
summary: 启动时或在「关于」里检查更新，并在各平台下载安装新版本。
keywords: 更新, 升级, 版本, update, 下载, 安装, apk, release
---

## 检查更新

- App 启动时，如果有更新的版本，会弹窗询问是否下载安装。
- 也可以在「设置 → 关于 → 检查更新」手动检查。

App 会和 GitHub 上的最新版本比较。

## 各平台的安装方式

| 平台 | 方式 |
|---|---|
| Android | 下载 APK，打开系统安装器 |
| Windows | 替换 App 的文件并重启 |
| Linux | 下载 `.deb`，在软件安装器里打开 |
| macOS | 在「下载」文件夹解压新版 App |
| iOS | 提示有新版本，请在 TestFlight 中安装 |
| 网页 | 随后端一起更新 |

Windows 上的 0.2.0 和 0.2.1 点「更新」后 App 会直接关闭，重新打开仍是旧版本。请手动安装一次 0.2.2：从 GitHub Releases 下载 `relay-client-windows-x64-v0.2.2.zip`，退出 Relay，把它解压覆盖到 App 所在的文件夹。之后如果更新失败，原因记录在临时文件夹（`%TEMP%`）的 `relay-client-update.log` 里。

后端的更新见[更新后端](backend-update.md)。
