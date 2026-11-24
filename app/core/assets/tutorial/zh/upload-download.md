---
title: 上传与下载
category: 文件
order: 630
summary: 上传文件、拖拽上传、下载文件和打包下载文件夹，以及大小上限。
keywords: 上传, 下载, upload, download, zip, 打包, 拖拽, 大小限制
---

## 上传

在文件系统里点「上传文件」，文件会上传到**当前显示的目录**。桌面端（Linux、Windows、macOS）和网页版也可以直接把文件拖到窗口中：拖动文件经过窗口时会出现上传提示框，松开即可上传到当前目录（手机端不显示此功能）。

单个文件默认上限 100 MB（`UPLOAD_MAX_BYTES`）。在聊天里附加的文件会上传到工作区的 `.relay/uploads/`，见[输入框工具](composer-tools.md)。

## 下载

文件和文件夹都可以下载。文件夹会被打包成 zip：Linux 和 macOS 用主机的 `zip` 命令，Windows 用 PowerShell。文件夹里含有被禁止的路径时，整个下载会被拒绝。

单次下载（含打包的文件夹）默认上限 300 MB（`DOWNLOAD_MAX_BYTES`）。

下载时会显示进度，完成后提示保存位置：

| 平台 | 位置 |
|---|---|
| 网页 | 浏览器的下载文件夹（大文件可能占用较多内存） |
| iOS | App 的「文稿」目录，在「文件 → 我的 iPhone → Relay」里 |
| Android 10 及以上 | Download 文件夹 |
| Android 9 及以下 | 内部存储的 `Android/data/dev.relay.app/files/Download` |
| 其他 | 提示里显示的路径 |
