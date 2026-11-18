# Relay backend for Windows x64 / Windows x64 后端

This bundle contains the Relay backend, Node.js/npm, locked production packages,
a compiled Flutter Web client and the **setup.cmd** command-line setup. Web and API
share the existing Node.js HTTP service; no separate Web server is needed.
The separate Windows desktop client is available in the client ZIP.

本包包含 Relay 后端、Node.js/npm、锁定的生产依赖、编译后的 Flutter Web 前端和
命令行安装脚本 **setup.cmd**。Web 与 API 共用现有 Node.js HTTP 服务，不需要额外 Web 服务器。
Windows 桌面客户端在单独的客户端 ZIP 中。

## First run / 首次使用

1. Extract the entire ZIP to a permanent writable directory. Keep the .cmd
   files, server/, app/ (the Web client), scripts/ and runtime/ together. Do not
   run inside the ZIP, and wait until extraction finishes; the .cmd files are
   the last ones written.
2. Open PowerShell in that directory and run **.\setup.cmd** (double-clicking
   setup.cmd also works), then choose 1) Install. The menu is the same as the
   Linux and macOS setup menu.
3. Follow the six steps: included runtime/dependencies, optional agent CLIs,
   Web on/off (default on), file access (open, or isolated to workspace\),
   network, and an encrypted device credential. Direct mode, a named
   Cloudflare Tunnel, Quick Tunnel and Tailscale (binds only the tailnet IP; Web requires a configured HTTPS proxy hostname)
   match Linux setup. Missing cloudflared
   is downloaded only for tunnel modes.
4. Choose a password of at least six characters. Import the encrypted
   server/credentials/*.relay.json or *.relay.png in Relay, or view the QR on
   the Device tokens tab and scan it. The password is not stored.
5. Sign in/configure your selected CLI yourself in a terminal:
   Claude Code: claude; Codex: codex login --device-auth; Cursor: agent login;
   OpenCode: opencode auth login; Antigravity: agy acp --login; Hermes: hermes setup.
   Setup adds the folders holding these CLIs (and the bundled Node when the
   host has none) to your user PATH, so terminals opened afterwards find them.
   Menu choice **t** opens one now and lists each command.
   Setup uses the publishers' official Windows installers; it does not log in.
6. When Web is enabled, open the backend address in a browser and import the
   same encrypted credential. The API still requires authentication.

1. 将整个 ZIP 解压到固定、可写的目录，保持各 .cmd 文件、server/、app/（Web 前端）、
   scripts/ 和 runtime/ 相对位置不变，不要直接在压缩包内运行；请等解压完成再运行，
   .cmd 文件是最后写出的文件。
2. 在该目录打开 PowerShell，运行 **.\setup.cmd**（双击 setup.cmd 也可以），选择
   1) Install。菜单与 Linux、macOS 的安装菜单相同。
3. 按六步完成：运行时和依赖、可选 CLI、Web 开关（默认开启）、文件访问（开放，或隔离在
   workspace\ 内）、网络、设备凭证。与 Linux 一样支持直连、正式 Cloudflare Tunnel、
   Quick Tunnel 和 Tailscale（只监听本机 tailnet IP，使用 Web 需填写已配置的 HTTPS 代理主机名）；仅隧道模式缺少 cloudflared 时下载它。
4. 设置至少六位的凭证密码，在 Relay 导入 server/credentials/ 中的 .relay.json
   或 .relay.png，或在设备令牌页查看二维码并扫码。密码不会保存。
5. 在终端自行运行上面的 CLI 登录或配置命令；安装器使用官方 Windows 安装方式，
   不会代替你登录。安装器会把这些 CLI 所在目录（主机没有 Node 时还有包内 Node）
   加入用户 PATH，之后新开的终端可直接调用；菜单选项 t 会立即打开一个终端并列出各条命令。
6. 开启 Web 后，在浏览器打开后端地址，导入相同凭证；API 仍需要认证。

For local testing choose Direct and http://127.0.0.1:8787. Other devices need
the Windows host's reachable address and an open firewall port. Public access
needs HTTPS (a Cloudflare tunnel provides it). Quick Tunnel URLs can change on
restart; generate/import a credential for the new URL when that happens.
Named tunnel setup may open a browser for Cloudflare login. Replacing an
existing DNS record is an explicit yes, off by default.

本机测试可选择直连并填 http://127.0.0.1:8787。其他设备需要使用主机可达的地址并放行
防火墙端口。公网访问需要 HTTPS（Cloudflare 隧道自带）。Quick Tunnel 重启后地址
可能变化，变化后需重新生成并导入凭证。正式隧道可能打开浏览器进行 Cloudflare 登录。
覆盖已有 DNS 记录需要明确回答 y，默认不覆盖。

## Management / 管理

The setup.cmd menu offers install, reinstall (retains tokens/chats/settings),
uninstall, service status (address, Web, agents and tokens), optional
installation of any of the agent CLIs, token create/delete/list/re-show, and
t) a terminal with the agent CLIs on PATH. Re-show keeps the token and asks for
a new QR password. Deleting a token immediately removes that device's access.
start.cmd, stop.cmd and status.cmd control the service directly.

setup.cmd 菜单提供安装、保留数据的重装、卸载、服务信息、agent CLI 选装，新建、删除、
列出、重新显示设备令牌，以及 t）打开一个 CLI 已在 PATH 上的终端。重新显示沿用原令牌，
但需要设置新的二维码密码；删除令牌会立即撤销对应设备的访问权限。start.cmd、stop.cmd 和
status.cmd 直接控制服务。

Console commands from the extracted directory / 解压目录的命令：

~~~powershell
.\setup.cmd
.\status.cmd
.\start.cmd
.\stop.cmd
.\update.cmd
.\credential.cmd --url https://YOUR-BACKEND
.\uninstall.cmd
~~~

Setup registers a current-user login Scheduled Task, not a system service.
Only one managed Relay installation per Windows user is supported. Logs are in
logs\ inside the extracted directory: backend/tunnel .out/.err logs hold
service output. PID files are in %LOCALAPPDATA%\Relay\runtime.
Uninstall removes services and Web; the setup.cmd menu also offers deleting
the named Cloudflare tunnel and the bundle-owned cloudflared. Backend
configuration, tokens, encrypted credentials, chats, settings and logs remain.
Shared host runtimes and agent CLIs remain. Extract the bundle again to
restore Web after uninstall.

安装会创建当前用户登录计划任务，不是系统服务。每个 Windows 用户支持一个受管理的
Relay 实例。日志位于解压目录下的 logs\：backend/tunnel 的 .out/.err 日志保存服务输出。
PID 文件位于 %LOCALAPPDATA%\Relay\runtime。卸载移除服务并删除 Web；setup.cmd 菜单还可选择删除
正式 Cloudflare 隧道和本包下载的 cloudflared。后端配置、设备令牌、加密凭证、
聊天、设置和日志保留，共用的主机运行时和 CLI 也会保留；卸载后重新解压可恢复 Web。

## Update / 升级

From 0.1.13 on, run .\update.cmd, or use Update in the app's Machine details:
it downloads the latest release, checks it against SHA256SUMS, replaces the
code, runtime and Web client in this directory, keeps server/ configuration and
state, and restarts the backend while the tunnel keeps running. If another process
still runs from this directory or holds the backend port, it changes nothing;
if the new backend does not start, it puts the previous version back.
.\update.cmd -Archive <zip> installs a ZIP downloaded by hand. To move from an
older release, stop it and back up server/, extract the new ZIP separately,
copy your deployment configuration and generated state into its server/
(excluding node_modules), then run Reinstall in the new directory to update
the task path.
Read docs/SECURITY.md before public deployment. Node's license is at
runtime/node/LICENSE; package licenses remain in server/node_modules/.

从 0.1.13 起，运行 .\update.cmd，或在 App 的机器详情页点击更新：它会下载最新版本并按
SHA256SUMS 校验，原地替换本目录的代码、运行时和 Web 客户端，保留 server/ 下的配置与状态，
然后重启后端，隧道保持运行。若仍有其他进程从本目录运行或占用后端端口，它不做任何改动；
新版本后端起不来时会自动恢复旧版本。.\update.cmd -Archive <zip> 可安装手动下载的 ZIP。从更早的
版本升级时：先停止旧实例并备份 server/；把新 ZIP 解压到另一目录，将部署配置和生成的状态
复制到新目录的 server/（不复制 node_modules），然后在新目录选择重装以更新计划任务路径。
公网部署前阅读 docs/SECURITY.md。Node 许可证在
runtime/node/LICENSE，依赖许可证在 server/node_modules/ 各包目录中。
