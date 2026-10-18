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
