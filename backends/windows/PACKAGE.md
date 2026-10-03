# Relay backend for Windows x64 / Windows x64 后端

This bundle runs the Relay **backend** on a Windows x64 machine. It includes
Node.js, npm, the locked production dependencies, and the Windows setup/service
scripts. Use the separate Relay mobile or desktop client to connect; a built
Flutter Web client is not included.

本包用于在 Windows x64 主机上运行 Relay **后端**，包含 Node.js、npm、按锁文件
安装的生产依赖，以及 Windows 安装和服务管理脚本。连接时使用单独发布的 Relay
手机或桌面客户端；本包不含编译后的 Flutter Web 客户端。

## First run / 首次使用

1. Extract the whole ZIP to a permanent, writable directory. Keep `server/`,
   `backends/`, and `runtime/` together. Do not run from inside the ZIP.
2. Install and authenticate/configure at least one agent CLI on this host:
   Claude Code, Codex, OpenCode, or Hermes. Restart the terminal after changing
   PATH. The bundle does not install or log in these CLIs.
3. Open PowerShell in the extracted directory and run `.\setup.cmd` (or
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backends\windows\setup.ps1`).
4. Choose the port, network mode, and credential passphrase. For a local trial,
   choose direct mode and enter `http://127.0.0.1:8787`. For another device on
   your LAN, enter this host's LAN address and permit the port in the firewall.
   Public access needs HTTPS. Tunnel modes require separately installed
   `cloudflared`; Quick Tunnel URLs can change after restart.
5. Import the generated `server/credentials/*.relay.json` or `*.relay.png` in
   the Relay client and enter the passphrase. Setup registers a Scheduled Task
   to start Relay when this Windows user logs in; it is not a system service.

1. 将整个 ZIP 解压到固定、可写的目录，保持 `server/`、`backends/`、`runtime/`
   相对位置不变，不要直接在压缩包中运行。
2. 在这台主机安装并登录或配置至少一个 CLI：Claude Code、Codex、OpenCode 或
   Hermes。修改 PATH 后重新打开终端；本包不会安装或登录这些 CLI。
3. 在解压目录打开 PowerShell，运行 `.\setup.cmd`，也可以执行上面的 PowerShell
   安装命令；无需另外安装 Node.js 或手动运行 npm install。
4. 按提示选择端口、网络模式和凭证密码。本机试用可选直连并填
   `http://127.0.0.1:8787`；局域网设备使用这台主机的局域网地址，并在防火墙放行端口。
   公网访问需要 HTTPS。隧道模式需自行安装 `cloudflared`，Quick Tunnel 重启后地址
   可能变化。
5. 在 Relay 客户端导入 `server/credentials/` 内的 `.relay.json` 或 `.relay.png`，
   输入密码。安装会创建当前用户登录时启动的计划任务，并非系统服务。

## Commands / 管理命令

Run these from PowerShell in the extracted directory / 在解压目录的 PowerShell 中运行：

```powershell
.\status.cmd
.\start.cmd
.\stop.cmd
.\credential.cmd --url https://YOUR-BACKEND
.\uninstall.cmd
```

`uninstall.cmd` removes the login task and stops Relay. Configuration, device
tokens, credentials, and history remain in `server/`. Logs and PID files are in
`%LOCALAPPDATA%\Relay\logs` and `%LOCALAPPDATA%\Relay\runtime`.

`uninstall.cmd` 停止 Relay 并删除登录计划任务，保留 `server/` 内的配置、设备令牌、
凭证和历史。日志与 PID 文件分别位于 `%LOCALAPPDATA%\Relay\logs` 和
`%LOCALAPPDATA%\Relay\runtime`。

For an update, stop Relay first and keep a backup of `server/`. Extract the new
bundle separately, move your configuration and generated state into its
`server/`, then run setup again to update the task's path. Only one managed
Relay backend per Windows user is supported. Read the bundled `SECURITY.md`
before public deployment. The Node.js license is at `runtime/node/LICENSE`;
dependency licenses remain inside their respective `server/node_modules/` packages.

升级前停止 Relay 并备份 `server/`，将新版本解压到另一目录，迁移配置和生成的状态到
新目录的 `server/`，再次运行安装以更新计划任务路径。每个 Windows 用户支持一个受
管理的 Relay 后端。公网部署前请阅读包内 `SECURITY.md`。Node.js 许可证位于
`runtime/node/LICENSE`，各依赖的许可证保留在 `server/node_modules/` 对应包中。
