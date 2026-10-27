# Relay backend for Windows x64 / Windows x64 后端

This bundle contains the Relay backend, Node.js/npm, locked production packages,
a compiled Flutter Web client and a native graphical **Setup.exe**. Web and API
share the existing Node.js HTTP service; no separate Web server is needed.
The separate Windows desktop client is available in the client ZIP.

本包包含 Relay 后端、Node.js/npm、锁定的生产依赖、编译后的 Flutter Web 前端和
图形化 **Setup.exe**。Web 与 API 共用现有 Node.js HTTP 服务，不需要额外 Web 服务器。
Windows 桌面客户端在单独的客户端 ZIP 中。

## First run / 首次使用

1. Extract the entire ZIP to a permanent writable directory. Keep Setup.exe,
   server/, build/web/, backends/ and runtime/ together. Do not run inside the ZIP.
2. Double-click **Setup.exe**. Windows 10/11's .NET Framework and PowerShell run
   the installer; no extra GUI runtime is downloaded.
3. Follow the five steps: included runtime/dependencies, optional agent CLIs,
   Web on/off (default on), network, and an encrypted device credential.
   Direct mode, a named Cloudflare Tunnel and Quick Tunnel match Linux setup.
   Missing cloudflared is downloaded only for tunnel modes.
4. Choose a password of at least six characters. Import the encrypted
   server/credentials/*.relay.json or *.relay.png in Relay, or view the QR on
   the Device tokens tab and scan it. The password is not stored.
5. Sign in/configure your selected CLI yourself in a terminal:
   Claude Code: claude; Codex: codex login --device-auth; Cursor: agent login;
   OpenCode: opencode auth login; Hermes: hermes setup.
   Setup uses the publishers' official Windows installers; it does not log in.
6. When Web is enabled, open the backend address in a browser and import the
   same encrypted credential. The API still requires authentication.

1. 将整个 ZIP 解压到固定、可写的目录，保持 Setup.exe、server/、build/web/、
   backends/ 和 runtime/ 相对位置不变，不要直接在压缩包内运行。
2. 双击 **Setup.exe**，使用 Windows 10/11 自带的 .NET Framework 和 PowerShell，
   无需另外下载界面运行时。
3. 按五步完成：运行时和依赖、可选 CLI、Web 开关（默认开启）、网络、设备凭证。
   与 Linux 一样支持直连、正式 Cloudflare Tunnel 和 Quick Tunnel；仅隧道模式
   缺少 cloudflared 时下载它。
4. 设置至少六位的凭证密码，在 Relay 导入 server/credentials/ 中的 .relay.json
   或 .relay.png，或在设备令牌页查看二维码并扫码。密码不会保存。
5. 在终端自行运行上面的 CLI 登录或配置命令；安装器使用官方 Windows 安装方式，
   不会代替你登录。
6. 开启 Web 后，在浏览器打开后端地址，导入相同凭证；API 仍需要认证。

For local testing choose Direct and http://127.0.0.1:8787. Other devices need
the Windows host's reachable address and an open firewall port. Public access
needs HTTPS (a Cloudflare tunnel provides it). Quick Tunnel URLs can change on
restart; generate/import a credential for the new URL when that happens.
Named tunnel setup may open a browser for Cloudflare login. Replacing an
existing DNS record is an explicit checkbox, off by default.

本机测试可选择直连并填 http://127.0.0.1:8787。其他设备需要使用主机可达的地址并放行
防火墙端口。公网访问需要 HTTPS（Cloudflare 隧道自带）。Quick Tunnel 重启后地址
可能变化，变化后需重新生成并导入凭证。正式隧道可能打开浏览器进行 Cloudflare 登录。
覆盖已有 DNS 记录需要明确勾选，默认不覆盖。

## Management / 管理

Setup.exe and the setup.cmd console menu share the same operations:
install, reinstall (retains tokens/chats/settings), uninstall, service status
(address, Web, agents and tokens), optional installation of any of the five
CLIs, and token create/delete/list/re-show. Re-show keeps the token and asks for
a new QR password. Deleting a token immediately removes that device's access.
Services / Uninstall also offers Start, Stop, Open Web and Open logs.

Setup.exe 和 setup.cmd 命令行菜单共用安装、保留数据的重装、卸载、服务信息、
五个 CLI 的选装，以及新建、删除、列出、重新显示设备令牌等功能。重新显示沿用原令牌，
但需要设置新的二维码密码；删除令牌会立即撤销对应设备的访问权限。服务页还可启动、
停止、打开 Web 页面和查看日志。

Console commands from the extracted directory / 解压目录的命令：

~~~powershell
.\setup.cmd
.\status.cmd
.\start.cmd
.\stop.cmd
.\credential.cmd --url https://YOUR-BACKEND
.\uninstall.cmd
~~~

Setup registers a current-user login Scheduled Task, not a system service.
Only one managed Relay installation per Windows user is supported. Logs and
PID files are in %LOCALAPPDATA%\Relay\logs and %LOCALAPPDATA%\Relay\runtime.
Uninstall removes services and, by default, Web; the GUI also offers deleting
the named Cloudflare tunnel and the bundle-owned cloudflared. Backend
configuration, tokens, encrypted credentials, chats, settings and logs remain.
Shared host runtimes and agent CLIs remain. Extract the bundle again to
restore Web after uninstall.

安装会创建当前用户登录计划任务，不是系统服务。每个 Windows 用户支持一个受管理的
Relay 实例。日志和 PID 位于 %LOCALAPPDATA%\Relay\logs 和
%LOCALAPPDATA%\Relay\runtime。卸载移除服务并默认删除 Web；图形界面还可选择删除
正式 Cloudflare 隧道和本包下载的 cloudflared。后端配置、设备令牌、加密凭证、
聊天、设置和日志保留，共用的主机运行时和 CLI 也会保留；卸载后重新解压可恢复 Web。

## Update / 升级

Stop the old installation and back up server/. Extract the new ZIP separately,
copy your deployment configuration and generated state into its server/
(excluding node_modules), then run Reinstall in the new directory to update
the task path. Keep the included fresh build/web/ and runtime/ from the new
bundle. Read SECURITY.md before public deployment. Node's license is at
runtime/node/LICENSE; package licenses remain in server/node_modules/.

先停止旧实例并备份 server/；把新 ZIP 解压到另一目录，将部署配置和生成的状态复制到
新目录的 server/（不复制 node_modules），然后在新目录选择重装以更新计划任务路径。
保留新包自带的 build/web/ 和 runtime/。公网部署前阅读 SECURITY.md。Node 许可证在
runtime/node/LICENSE，依赖许可证在 server/node_modules/ 各包目录中。
