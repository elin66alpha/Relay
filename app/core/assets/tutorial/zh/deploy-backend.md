---
title: 部署后端
category: 入门
order: 120
summary: 准备主机、运行安装脚本、选择网络方式、拿到凭证，一页走完。
keywords: 安装, 部署, setup, install, 后端, Node.js, 二维码, 凭证
---

Relay 的智能体跑在你自己的电脑或服务器上，App 只是入口。这一页按顺序走完整个部署过程；各系统的细节见[在 Linux 和 macOS 上安装](install-linux-macos.md)与[在 Windows 上安装](install-windows.md)。

## 1. 准备一台后端机器

家里的 PC、Mac 或一台云服务器都可以。需要：

- **Node.js 22 或更新版本**。
- **至少一个 CLI 智能体**：Claude Code、Codex、Cursor（命令是 `agent`）、OpenCode、Antigravity（`agy`）或 Hermes。
- 在主机上**亲自完成 CLI 的登录或 provider 配置**。Relay 只读取登录状态，从不替你登录。

先在主机终端里确认选定的 CLI 能正常对话。Linux 还需要 PM2、Python 3、`make` 和 C++ 编译器（终端功能需要编译）；Linux 和 macOS 下载文件夹需要 `zip`；使用 Cloudflare 隧道需要 `cloudflared`。缺少这些时，安装脚本会在你确认后自动安装（Debian/Ubuntu 用 `sudo apt-get`，macOS 用 Homebrew）。

## 2. 下载并运行安装脚本

Linux 和 macOS 共用一个后端包。从 [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest) 下载 `relay-backend-linux-macos-v<版本>.tar.gz`，解压到固定、可写的目录，进入包含 `server/` 的文件夹，运行 `./install.sh`。

Windows 从 [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest) 下载 `relay-backend-windows-x64-v<版本>.zip`，**完整解压**到一个固定目录，在该目录运行 `.\setup.cmd`：与 Linux、macOS 相同的命令行菜单。压缩包已包含 Node.js、依赖和网页客户端。

用源码仓库安装时，在仓库根目录运行对应系统的脚本：

| 系统 | 命令 |
|---|---|
| Linux | `./scripts/install/linux/setup.sh` |
| macOS | `./scripts/install/macos/setup.sh` |
| Windows PowerShell | `.\scripts\install\windows\setup.ps1` |

安装过程中会询问端口、是否提供网页客户端、文件访问方式（见[文件访问：开放与隔离](file-access-mode.md)），还可以顺便安装缺少的 CLI 智能体；装完后在主机终端运行它打印的登录命令。

## 3. 选择 App 连接后端的方式

| 方式 | 适合 | 注意 |
|---|---|---|
| 直连 | 局域网，或自己有 HTTPS 反向代理 | 填写客户端设备真正能访问的地址；其他设备不能用 `localhost` 访问你的主机。公开到互联网前要配 HTTPS |
| Cloudflare 命名隧道 | 长期使用 | 需要你自己在 Cloudflare 上的域名，地址稳定且自带 HTTPS |
| Cloudflare 快速隧道 | 试用 | 不需要域名；但 `trycloudflare.com` 地址在重启后可能变化，变了就要重新生成并导入凭证 |
| Tailscale | tailnet 私网直连 | 自动读取本机 `tailscale ip -4`，流量经 WireGuard 加密 |

详见[网络方式与 HTTPS](network-modes.md)。

## 4. 拿到加密凭证

安装脚本启动后端后，会在终端打印一个加密的凭证二维码，并在 `server/credentials/` 下生成 `.relay.png` 和 `.relay.json`。生成时你要设置一个密码，它不会被保存，请记好。

**每台设备单独生成一份凭证**，这样以后可以单独撤销某台设备。

## 5. 在 App 里连接

回到 App 的「设置」最上方的「机器凭证」（点击「添加机器」；若尚无机器则在首屏直接导入）：手机可以扫码；所有平台都可以上传二维码图片或粘贴 JSON，然后输入密码。详见[导入凭证与管理机器](import-credential.md)。

连上后建议依次：

1. 点首页的机器打开[机器详情](machine-details.md)，确认 CLI 状态是「已就绪」。
2. 打开「文件系统」，进入项目目录，点「设为工作路径」。
3. 选一个可用的智能体，发一条简单任务试试，见[第一次任务](first-task.md)。

## 连接失败？

先分清是**解密失败**（核对密码和凭证文件）还是**连接失败**（检查后端服务、端口、防火墙和地址）。完整排查步骤见[连接排错](troubleshooting.md)。

长期、加固的部署（开机自启、HTTPS、反向代理、限制目录）请参考仓库里的 `docs/handbook.md`。
