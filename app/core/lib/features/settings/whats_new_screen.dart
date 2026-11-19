import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';

/// One line for the Home entry: the newest version and its highlights.
String whatsNewSummary(AppStrings strings) {
  final _Release latest = (strings.isZh ? _zhReleases : _enReleases).first;
  return '${latest.version} · '
      '${latest.highlights.map((_Highlight h) => h.title).join(strings.isZh ? '、' : ', ')}';
}

/// Plain-language release notes, newest first. A release adds an entry here
/// with one to three highlights; every other change is a short line.
class WhatsNewScreen extends StatelessWidget {
  const WhatsNewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    final List<_Release> releases = strings.isZh ? _zhReleases : _enReleases;
    assert(
      _zhReleases.map((_Release r) => r.version).join() ==
              _enReleases.map((_Release r) => r.version).join() &&
          releases.every(
            (_Release r) => r.highlights.isNotEmpty && r.highlights.length <= 3,
          ),
      'Each release needs 1-3 highlights in both languages.',
    );
    return Scaffold(
      appBar: AppBar(title: Text(strings.whatsNew)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final _Release release in releases) ...<Widget>[
                      Text(
                        release.version,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      for (final _Highlight highlight in release.highlights)
                        _HighlightCard(highlight: highlight),
                      const SizedBox(height: 8),
                      Text(
                        strings.otherChanges,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      for (final String change in release.changes)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '•  $change',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HighlightCard extends StatelessWidget {
  const _HighlightCard({required this.highlight});

  final _Highlight highlight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CircleAvatar(
              radius: 18,
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: Icon(highlight.icon, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    highlight.title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    highlight.body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Release {
  const _Release({
    required this.version,
    required this.highlights,
    required this.changes,
  });

  final String version;
  final List<_Highlight> highlights;
  final List<String> changes;
}

class _Highlight {
  const _Highlight({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

const List<_Release> _zhReleases = <_Release>[
  _Release(
    version: '0.2.1',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.folder_outlined,
        title: '中文路径可以当工作区了',
        body: '把带中文（或其他非英文字符）的文件夹设为工作区后，App 不会再连不上后端。',
      ),
      _Highlight(
        icon: Icons.sync_rounded,
        title: '抽屉里的转圈会自己停',
        body: '后台会话的回复已经完成时，左侧抽屉里的加载圈会自动消失，不用再点进会话才停。',
      ),
    ],
    changes: <String>[
      'iOS 版改为通过 TestFlight 安装和更新，不再提供未签名的 IPA。',
      'macOS 版经过 Apple 签名和公证，双击即可打开；因为换了应用标识，需要重新添加一次机器。',
    ],
  ),
  _Release(
    version: '0.2.0',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.menu_book_outlined,
        title: '全新的教程',
        body:
            '首页和设置里的“教程”改成了按模块分类的文章列表，从部署后端、聊天、各个智能体、蜂群、文件到终端和额度，每个功能都有一篇详细说明，顶部还可以搜索。',
      ),
      _Highlight(
        icon: Icons.system_update_alt_rounded,
        title: 'App 和后端都能自己更新',
        body:
            '有新版本时，App 启动会询问是否下载安装（Android、Windows、Linux、macOS），也可以在“设置 → 关于 → 检查更新”手动检查。机器详情显示后端版本，并可以一键更新到新版本并重启。',
      ),
      _Highlight(
        icon: Icons.storage_rounded,
        title: '文件浏览器切换磁盘',
        body:
            '后端有多个磁盘时，点路径栏第一段即可切换：Windows 上是 C:、D: 等盘符，macOS 和 Linux 上是 / 和每个挂载的磁盘。',
      ),
    ],
    changes: <String>[
      '演示模式：在初始欢迎页点击「试用演示」，即可不部署后端直接体验界面和模拟对话（禁用 SSH 与浏览器，导入真实机器时自动移除）。',
      '内置浏览器：新标签里的本机链接留在后端，外部链接确认后用你设备上的浏览器打开；右上角新增信息按钮，说明它的能力和限制。',
      '侧边栏更简洁：底部改成一行首页、浏览器、文件系统、设置；蜂群收成一项；不可用的智能体收进一行；机器凭证直接显示在设置最上方，通过「添加机器」导入。',
      '定时消息并入“额度查询”：在 Claude Code 和 Codex 卡片上设置，卡片会显示发送时间和内容预览。',
      'Antigravity 的额度只在“额度查询”里显示，输入框上方改为一行提示。',
      '下载时，relay-client 是客户端，relay-backend 是后端。后端解压后即可安装：Linux 和 macOS 运行 ./install.sh，Windows 运行 setup.cmd。',
      'Windows 安装会把智能体 CLI 加入用户 PATH，并新增打开终端登录 CLI 的入口；新增 update.cmd 原地升级。',
      '修复 Windows 安装反复重写 .env 导致文件越来越大的问题，后端也重新优先使用自带的 Node.js。',
      '修复同步历史时偶尔丢掉排队中的跟进消息的问题。',
      '修复 Windows 桌面端 SSH 终端无法输入字符的问题。',
    ],
  ),
  _Release(
    version: '0.1.12',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.public_rounded,
        title: '内置浏览器看本机网页',
        body:
            '左侧栏新增“浏览器”，不用配置端口转发，就能直接打开并操作后端机器 localhost 上的网页。手机端按竖屏触控布局，电脑端按桌面鼠标布局，支持文字输入条、后退刷新，离开后还会保留 10 分钟。',
      ),
      _Highlight(
        icon: Icons.preview_rounded,
        title: '聊天链接直达与图片/Markdown 预览',
        body:
            '在单聊回复里点文件路径链接可直接预览文件或打开目录，点网址会先弹窗确认完整地址再打开。文件浏览器现在支持渲染 Markdown（可切换源码）和缩放查看常见图片。',
      ),
      _Highlight(
        icon: Icons.notifications_active_outlined,
        title: 'Codex 与 Antigravity 后台回复显示',
        body:
            'Codex 子智能体完成工作或 Antigravity 在后台被定时任务、命令唤醒并写出回复时，单聊里会自动出现对应消息，同样支持“停止”按钮中断。',
      ),
    ],
    changes: <String>[
      '连接旧版本后端且缺少新接口（如新建文件夹）时，会直接提示后端版本过旧，不再显示原始 HTML 错误页。',
      'iOS 下载的文件会保存到应用“文稿”目录，可在“文件 → 我的 iPhone → Relay”中找到。',
      '智能体正在回复时也可以直接从侧边栏返回首页，任务会继续在后端运行。',
      'App 从后台切回前台时会自动重连事件流并同步一次历史记录，其他设备刚聊完的内容无需手动刷新即可看到。',
      'Linux 和 macOS 安装时也可以选择“隔离”文件访问：agent 和文件浏览器只能使用安装目录下的 workspace 文件夹。',
      'macOS 后端的安装与 Linux 完全一致：同一行 install.sh 命令安装和升级，同样的菜单和六个安装步骤，缺少的软件用 Homebrew 补齐。',
    ],
  ),
  _Release(
    version: '0.1.11',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.add_circle_outline_rounded,
        title: '加入 Antigravity',
        body:
            '在后端主机安装支持隔离会话的 agy，并运行 agy acp --login 登录后，就能在 Relay 中选择 Antigravity，继续对话、切换模型和思考强度，也能同时处理多个会话。',
      ),
      _Highlight(
        icon: Icons.data_usage_rounded,
        title: '查看 Antigravity 额度',
        body:
            '用量页和输入框上方会显示 Antigravity 的订阅额度，Gemini、Claude/GPT 和 Argon 各自显示。首次查看前需先开始一次对话，让主机上的额度服务运行起来。',
      ),
      _Highlight(
        icon: Icons.folder_open_rounded,
        title: '更方便地浏览项目文件',
        body:
            '点击首页当前工作区或聊天标题即可打开文件系统，点击其他最近工作区可直接切换项目。顶部路径栏始终可见，点击路径段或“..”可返回上级；浏览其他目录时，点击工作路径标签即可回到当前项目。',
      ),
    ],
    changes: <String>[
      'Antigravity 可选择谨慎或自动批准权限；不同会话的模型和设置互不影响。',
      'Antigravity 的登录文件不能通过文件浏览器读取，凭据和账号详情保留在后端主机。',
      '中英文部署和入门教程已更新；额度预约仍仅支持 Claude Code 和 Codex。',
      '切换机器后会清除旧目录列表，避免误选上一台机器的项目。',
      '修复 Windows 网络共享路径导航；首次加载文件系统失败后可直接刷新重试。',
      '刷新和隐藏文件开关移至顶部；蜂群工作树选择器新增“..”上级目录入口。',
      '新增 Relay MCP：个人 Agent 用凭证 JSON 加密码登录后，可以调用本机所有 Agent、切换工作区和模型、查看额度。',
    ],
  ),
  _Release(
    version: '0.1.10',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.drive_file_move_outline,
        title: '安装脚本换了位置',
        body:
            '后端的安装和管理脚本从 backends/ 移到了 scripts/install/。用仓库副本安装时，Linux 运行 ./scripts/install/linux/setup.sh，macOS 运行 ./scripts/install/macos/setup.sh，Windows 运行 .\\scripts\\install\\windows\\setup.ps1。Linux 一键安装命令不变，升级时会自动删掉旧目录。Windows 照常把新包解压到新文件夹，再在里面选择重装。',
      ),
    ],
    changes: <String>[
      '项目文件按用途重新整理：客户端在 app/，后端在 server/，所有脚本在 scripts/，所有文档在 docs/。',
      '后端现在需要 Node.js 22 或更新版本；Linux 安装脚本会在需要时提示升级。',
      '后端依赖已更新，修复了已知的安全问题。',
      '发布页新增 Ubuntu 安装包、macOS 版和未签名的 iOS 安装包（iOS 需要自己签名后安装）。',
    ],
  ),
  _Release(
    version: '0.1.9',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.add_circle_outline_rounded,
        title: '加入 Cursor',
        body:
            '左侧栏的智能体里多了 Cursor，排在 Codex 下面。只要主机上的 Cursor 已经登录（在主机终端运行 agent login），就能像 Claude Code、Codex 一样跟它聊天，选模型、思考深度、快速模式和权限，几个 Cursor 会话也能同时进行。额度页能看到它的用量。',
      ),
      _Highlight(
        icon: Icons.terminal_rounded,
        title: '一行命令装好后端',
        body:
            '在 Linux 主机终端粘贴一行命令，就会自动下载最新的 Relay 后端并开始安装，还能顺手装上你选的 Claude Code、Codex、Cursor、OpenCode、Hermes。命令在凭证页的“如何部署后端？”里可以直接复制；以后再运行一次就是升级，聊天和设置都会保留。',
      ),
    ],
    changes: <String>[
      '模型列表更简洁：Cursor 只列出套餐额度内的模型，需要预付费的放到底部的“需要支付方式的模型”里；Claude Code 和 Codex 的旧版模型放到底部的“旧版模型”里。Swarm 里只列主力模型。',
      'OpenCode 的模型列表直接读主机上的 OpenCode，免费模型变了会跟着更新；你在主机 OpenCode 里配好的 API 模型也会出现在列表里。Hermes 也有了模型入口，显示主机上配置好的模型。',
      'Claude Code 不再误报“今天之内需要重新登录”。',
      '智能体调用工具前后说的话会分成两条消息显示，不再连成一段。',
      'Relay 自动批准 Cursor 的操作时只允许这一次，不会再往主机上 Cursor 自己的白名单里添加命令。',
      '删除或清空 Cursor 的对话时，对应的会话记录也会一起删掉。',
      '在 Relay 里给 Cursor 选的模型不会改变你在主机终端里使用 Cursor 时的默认设置。',
      'Cursor 的登录文件和 Claude Code、Codex 的一样，不能通过文件浏览器读取。',
      '后端能找到装在 ~/.local/bin 里的 Claude Code、Codex 等命令行工具，不会再显示“未安装”。',
      '切换到另一台后端后，智能体的安装和登录状态会跟着刷新，不再沿用上一台的。',
      '每台后端各自记住自己的工作目录。以前切换到另一台后端发消息会报 permission denied，现在不会了。更新后每台后端会先回到默认目录，需要时重新选一次。',
      '机器详情在竖屏手机上不再把一个词拆成两行。',
    ],
  ),
  _Release(
    version: '0.1.8',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.wallpaper_outlined,
        title: '聊天壁纸',
        body:
            '在“设置 → 壁纸”里选一张喜欢的图片当聊天背景，拖动滑块调节浓淡，点“保存”就生效。手机和电脑上会保留原图的清晰度。设置壁纸后，聊天框、消息和首页卡片都会变成半透明的毛玻璃效果。',
      ),
      _Highlight(
        icon: Icons.data_usage_rounded,
        title: '上下文用量',
        body:
            '输入框上方的右侧会显示“已用 / 上限”，比如 42k / 200k，告诉你这段对话已经占用了智能体多少“记忆”。快满的时候，可以压缩对话，或者新开一个会话。',
      ),
      _Highlight(
        icon: Icons.attach_file_rounded,
        title: '上传文件',
        body:
            '点输入框旁边的“+”，选“附加文件”，就能把手机或电脑里的文件传到当前项目里。文件位置会自动填进输入框，你再补一句想让它做什么就行，不会自动发送。',
      ),
    ],
    changes: <String>[
      '除了 Main，其他会话都可以重命名。',
      '消息可以一键复制；点自己消息上的“编辑”，能把原文放回输入框，改一改再发。',
      '在文件浏览器里点文本文件，可以直接查看内容，代码带颜色高亮。',
      '“更新 CLI”挪到了输入框的“+”菜单里。',
      'Claude 自己开始的回复（比如后台任务做完时）不会再一直转圈，也能用“停止”按钮停下。',
      '压缩对话后，上下文用量会马上刷新。',
      '对敏感文件的访问保护更严格了。',
      '后端安装更稳：装完会检查终端组件能不能正常用。',
      '修复 Windows 上快速创建消息时，消息按钮或显示可能混乱的问题。',
    ],
  ),
];

const List<_Release> _enReleases = <_Release>[
  _Release(
    version: '0.2.1',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.folder_outlined,
        title: 'Folders with Chinese names work as workspaces',
        body:
            'Choosing a folder whose path has Chinese or other non-English characters as the workspace no longer disconnects the app from the backend.',
      ),
      _Highlight(
        icon: Icons.sync_rounded,
        title: 'Drawer spinners stop on their own',
        body:
            'When a background session\'s reply has finished, its spinner in the drawer goes away without opening the session.',
      ),
    ],
    changes: <String>[
      'The iOS app is now installed and updated through TestFlight; the unsigned IPA is gone.',
      'The macOS app is signed and notarized by Apple and opens with a double-click. Its app identifier changed, so add your machines again once.',
    ],
  ),
  _Release(
    version: '0.2.0',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.menu_book_outlined,
        title: 'A new tutorial',
        body:
            'Tutorial on Home and in Settings is now a list of articles grouped by area: deploying the backend, chat, each agent, Swarms, files, the terminal, quota and more, one detailed article per feature, with a search box at the top.',
      ),
      _Highlight(
        icon: Icons.system_update_alt_rounded,
        title: 'The app and backend update themselves',
        body:
            'When a newer release exists, the app offers to download and install it at start-up (Android, Windows, Linux, macOS), or from Settings → About → Check for updates. Machine details shows the backend version and can update and restart it in one step.',
      ),
      _Highlight(
        icon: Icons.storage_rounded,
        title: 'Switch disks in the file browser',
        body:
            'When the backend has more than one disk, the first segment of the path bar switches between them: drive letters such as C: and D: on Windows, / and each mounted disk on macOS and Linux.',
      ),
    ],
    changes: <String>[
      'Demo mode: tap "Try the demo" on the welcome screen to explore the app and simulated replies without a backend (SSH and Browser disabled; removed when importing a real machine).',
      'Browser: new localhost tabs open on the backend, and external links open on your device after confirmation; a new info button explains what it can and cannot do.',
      'A tidier drawer: one bottom row for Home, Browser, File system and Settings; Swarm as one entry; unavailable agents folded into one row; machine credentials sit at the top of Settings with Add machine.',
      'Scheduled messages moved into Quota usage: set them on the Claude Code and Codex cards, which show the send time and a preview.',
      'Antigravity quota shows only in Quota usage; the strip above the composer shows a short hint instead.',
      'Release downloads are labeled relay-client or relay-backend. Extract the backend and run ./install.sh on Linux and macOS, or setup.cmd on Windows.',
      'Windows setup puts the agent CLIs on the user PATH and can open a terminal to sign them in; update.cmd upgrades in place.',
      'Fixed Windows setup rewriting .env until it grew huge, and the backend prefers its bundled Node.js again.',
      'Fixed a history sync that could drop a queued follow-up message.',
      'Fixed typing in the SSH terminal on the Windows desktop app.',
    ],
  ),
  _Release(
    version: '0.1.12',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.public_rounded,
        title: 'Browser for localhost pages',
        body:
            'Open Browser from the drawer to view and use pages served on the backend host’s localhost without port forwarding. Phones get mobile layout and touch input, desktops get mouse and wheel input, and your page stays open for 10 minutes after leaving.',
      ),
      _Highlight(
        icon: Icons.preview_rounded,
        title: 'Tappable chat links and richer file previews',
        body:
            'Tap file links in solo-chat replies to preview files or open folders, and confirm web links before opening them in your browser. File System now renders Markdown (with a source toggle) and opens images in a zoomable viewer.',
      ),
      _Highlight(
        icon: Icons.notifications_active_outlined,
        title: 'Background replies for Codex and Antigravity',
        body:
            'Codex child-agent completion replies and Antigravity background turns (woken by timers, subagents, or commands) now appear in solo chat and can be stopped with Stop.',
      ),
    ],
    changes: <String>[
      'Connecting to an older backend that lacks a route (such as New Folder) now explains that the backend is too old instead of showing raw HTML.',
      'iOS downloads save to Documents and appear in Files → On My iPhone → Relay.',
      'Returning Home from the drawer no longer waits when an agent is busy; the turn keeps running on the backend.',
      'Resuming the app reconnects events and refreshes history once so turns finished on another client appear automatically.',
      'Linux and macOS setup can also isolate file access: agents and the file browser then stay inside the workspace folder of the installation.',
      'macOS backend setup now matches Linux: the same one-line install.sh to install and upgrade, the same menu and six steps, with Homebrew installing what is missing.',
    ],
  ),
  _Release(
    version: '0.1.11',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.add_circle_outline_rounded,
        title: 'Antigravity joins Relay',
        body:
            'Install agy with isolated-session support on the backend host and sign in there with agy acp --login. You can then select Antigravity in Relay, continue conversations, pick its model and reasoning effort, and work in several sessions at once.',
      ),
      _Highlight(
        icon: Icons.data_usage_rounded,
        title: 'Check Antigravity quota',
        body:
            'Usage and the strip above the message box show Antigravity subscription quota, with separate Gemini, Claude/GPT and Argon pools. Start a conversation before the first check so the host CLI quota service is running.',
      ),
      _Highlight(
        icon: Icons.folder_open_rounded,
        title: 'Browse project files more easily',
        body:
            'Tap the current workspace on Home or the chat title to open File System, or a different recent workspace to switch projects. The path bar stays visible: tap an ancestor or “..” to go up, and use the work-path chip to return to your active project from another directory.',
      ),
    ],
    changes: <String>[
      'Antigravity offers cautious and auto-approve permissions; each session keeps its own model and settings.',
      'Antigravity login files are protected from the file browser, and credentials and account details stay on the backend host.',
      'English and Chinese setup and getting-started guides are updated; quota schedules remain Claude Code and Codex only.',
      'Switching machines clears old directory lists so you cannot accidentally select the previous machine’s project.',
      'Windows network-share navigation is fixed; Refresh can retry a failed initial File System load.',
      'Refresh and hidden-file controls moved to the top; the Swarm work-tree picker now includes a “..” parent row.',
      'New Relay MCP: a personal agent signs in with a credential JSON and its password, then can use every agent on the machine, switch workdir and model, and check quota.',
    ],
  ),
  _Release(
    version: '0.1.10',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.drive_file_move_outline,
        title: 'Install scripts moved',
        body:
            'The backend install and management scripts moved from backends/ to scripts/install/. From a copy of the repository, run ./scripts/install/linux/setup.sh on Linux, ./scripts/install/macos/setup.sh on macOS, or .\\scripts\\install\\windows\\setup.ps1 on Windows. The one-line Linux install command is unchanged and removes the old folder when it upgrades. On Windows, extract the new bundle into its own folder and choose Reinstall there, as before.',
      ),
    ],
    changes: <String>[
      'The project files are grouped by purpose: the app in app/, the backend in server/, every script in scripts/ and every document in docs/.',
      'The backend now needs Node.js 22 or newer; Linux setup offers an upgrade when needed.',
      'Backend dependencies include available security fixes.',
      'Releases now include an Ubuntu package, a macOS app and an unsigned iOS app that you sign while installing.',
    ],
  ),
  _Release(
    version: '0.1.9',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.add_circle_outline_rounded,
        title: 'Cursor joins Relay',
        body:
            'Cursor now appears in the agent list, right below Codex. Once Cursor is signed in on the host (run agent login in a terminal there), you can chat with it and pick its model, reasoning effort, Fast mode and permission just like Claude Code and Codex, with several Cursor sessions running at once. The quota page shows its usage.',
      ),
      _Highlight(
        icon: Icons.terminal_rounded,
        title: 'Install the backend with one command',
        body:
            'Paste one command into a Linux terminal and it downloads the latest Relay backend and starts setup, which can also install the Claude Code, Codex, Cursor, OpenCode or Hermes CLIs you pick. Copy the command from “How to deploy the backend?” on the credentials page; running it again later upgrades, keeping your chats and settings.',
      ),
    ],
    changes: <String>[
      'A tidier model list: Cursor shows only the models its plan includes, with prepaid ones under “Models that need a payment method” at the bottom; older Claude Code and Codex models move under “Legacy models”. Swarms list main models only.',
      'OpenCode’s model list now comes straight from OpenCode on the host, so it follows changes to its free models and includes any API models you set up in OpenCode there. Hermes now has a Model entry showing the model configured on the host.',
      'Claude Code no longer shows a false “log in again within a day” warning.',
      'What an agent says before and after using a tool now shows as two messages instead of one run-together paragraph.',
      'When Relay approves a Cursor action, it allows it once only and no longer adds commands to Cursor’s own allowlist on the host.',
      'Deleting or clearing a Cursor conversation also deletes its record.',
      'Models you pick for Cursor in Relay no longer change Cursor’s own defaults when you use it in a terminal on the host.',
      'Cursor’s login file is protected from the file browser, like those of Claude Code and Codex.',
      'The backend finds Claude Code, Codex and other agent CLIs installed in ~/.local/bin instead of reporting them as not installed.',
      'Switching to another backend refreshes which agents are installed and signed in, instead of keeping the previous backend’s status.',
      'Each backend remembers its own work directory, so messages to another backend no longer fail with “permission denied”. After updating, each backend starts in its default folder; choose yours again if needed.',
      'Machine details no longer splits words across two lines on portrait phones.',
    ],
  ),
  _Release(
    version: '0.1.8',
    highlights: <_Highlight>[
      _Highlight(
        icon: Icons.wallpaper_outlined,
        title: 'Chat wallpaper',
        body:
            'Pick any picture in Settings → Wallpaper as your chat background, drag the slider to make it lighter or stronger, then tap Save. Phones and computers keep the picture at its full sharpness. With a wallpaper, the chat bar, messages and Home cards turn into soft frosted glass.',
      ),
      _Highlight(
        icon: Icons.data_usage_rounded,
        title: 'Context usage',
        body:
            'The right side of the line above the message box shows “used / limit”, for example 42k / 200k: how much of the agent’s memory this conversation already takes. When it gets close to full, compact the conversation or start a new session.',
      ),
      _Highlight(
        icon: Icons.attach_file_rounded,
        title: 'Upload files',
        body:
            'Tap + next to the message box and choose Attach file to send a file from your phone or computer into the current project. Its location is filled into the message box for you; add what you want done with it. Nothing is sent automatically.',
      ),
    ],
    changes: <String>[
      'Rename any session except Main.',
      'Copy any message with one tap. Tap Edit on your own message to put its text back in the message box, adjust it and send again.',
      'Tap a text file in the file browser to read it right there, with colored code.',
      'Update CLI moved into the + menu next to the message box.',
      'Replies Claude starts on its own (for example when a background task finishes) no longer spin forever, and Stop can end them.',
      'After compacting a conversation, context usage updates right away.',
      'Sensitive files are better protected from access.',
      'Backend setup is sturdier: it checks that the terminal component really works.',
      'Quickly created messages no longer mix up their actions or display on Windows.',
    ],
  ),
];
