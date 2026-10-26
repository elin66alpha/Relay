import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/group.dart';
import '../../core/platform/file_saver.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/chat_wallpaper.dart';
import '../cli_agents/agent_status_lights.dart';
import '../cli_agents/cli_agents_controller.dart';
import 'chat_content.dart';
import 'group_chat_controller.dart';
import 'swarm_form_dialog.dart';

/// Multi-agent group chat. Owns its own [GroupChatController] for the lifetime of
/// the screen (one extra SSE subscription while open). Summon agents by mentioning
/// them in the composer (`@claude`); one human message can fan out to several
/// agents, each replying in turn.
class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({
    required this.agentsController,
    required this.settingsController,
    this.initialGroupId,
    super.key,
  });

  /// A first-level page: it paints its own wallpaper, not the pushed-page one.
  static const String routeName = 'swarm';

  final CliAgentsController agentsController;
  final AppSettingsController settingsController;

  /// When set, open directly into this swarm instead of the most-recent one.
  final String? initialGroupId;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  late final GroupChatController _controller;
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = GroupChatController()
      ..language = widget.settingsController.language;
    _controller.addListener(_onChange);
    _controller.start(initialGroupId: widget.initialGroupId);
  }

  void _onChange() {
    if (!mounted) return;
    // Keep the newest message in view as the transcript grows / streams.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    _controller.dispose();
    _inputFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<CliAgent> get _agents => widget.agentsController.agents;

  CliAgent _agentForKey(String key) {
    return _agents.firstWhere(
      (CliAgent agent) => agent.key == key,
      orElse: () => cliAgentByKey(key),
    );
  }

  Future<void> _send() async {
    if (_controller.sending) return;
    final String text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    final bool sent = await _controller.send(text);
    if (!sent && mounted && _input.text.isEmpty) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    }
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (!usesHardwareKeyboard || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    _send();
    return KeyEventResult.handled;
  }

  void _insertMention(String agentKey) {
    final TextEditingValue value = _input.value;
    final int offset = value.selection.isValid
        ? value.selection.baseOffset
        : value.text.length;
    final String prefix = value.text.substring(0, offset);
    final String suffix = value.text.substring(offset);
    final String spacer = prefix.isEmpty || prefix.endsWith(' ') ? '' : ' ';
    final String insert = '$spacer@$agentKey ';
    final String next = '$prefix$insert$suffix';
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: offset + insert.length),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    return AnimatedBuilder(
      animation: Listenable.merge(
        <Listenable>[_controller, widget.settingsController],
      ),
      builder: (BuildContext context, Widget? _) {
        final ChatGroup? group = _controller.selected;
        final bool acrylic = widget.settingsController.wallpaper.bytes != null;
        return ChatWallpaper(
          wallpaper: widget.settingsController.wallpaper,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: acrylic ? Colors.transparent : null,
              surfaceTintColor: acrylic ? Colors.transparent : null,
              flexibleSpace: acrylic ? const AcrylicAppBarBackground() : null,
              title: InkWell(
                onTap: _showGroupSwitcher,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        group?.name ?? strings.groupChat,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_controller.groups.isNotEmpty)
                      const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
              actions: <Widget>[
                IconButton(
                  tooltip: strings.newGroup,
                  icon: const Icon(Icons.group_add_outlined),
                  onPressed: _createGroup,
                ),
                if (group != null)
                  PopupMenuButton<String>(
                    onSelected: (String action) => _onMenu(action, group),
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'members',
                        child: Text(strings.manageMembers),
                      ),
                      PopupMenuItem<String>(
                        value: 'clear',
                        child: Text(strings.clearTranscript),
                      ),
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: Text(strings.deleteGroup),
                      ),
                    ],
                  ),
              ],
            ),
            body: Column(
              children: <Widget>[
                if (_controller.error != null)
                  _ErrorBanner(message: _controller.error!),
                Expanded(child: _buildBody(strings, group)),
                if (group != null)
                  ChatChromeSurface(
                    acrylic: acrylic,
                    color: acrylic
                        ? Theme.of(context).colorScheme.surfaceContainer
                        : Theme.of(context).scaffoldBackgroundColor,
                    border: Border(
                      top: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: _buildComposer(strings, group),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(AppStrings strings, ChatGroup? group) {
    if (_controller.loadingGroups && _controller.groups.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (group == null) {
      return _EmptyState(
        icon: Icons.groups_outlined,
        title: strings.noGroups,
        action: FilledButton.icon(
          onPressed: _createGroup,
          icon: const Icon(Icons.add),
          label: Text(strings.newGroup),
        ),
      );
    }
    final List<ChatMessage> messages = _controller.messages;
    if (messages.isEmpty) {
      return _EmptyState(
        icon: Icons.forum_outlined,
        title: group.memberLabels.join(' · '),
        subtitle: strings.groupEmptyHint,
      );
    }
    // SelectionArea keeps bubble text selectable without each bubble building
    // its own overlay-based SelectableText (see MessageText), which crashed on
    // conversation teardown (InheritedElement '_dependents.isEmpty').
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: messages.length,
        itemBuilder: (BuildContext context, int index) => _MessageBubble(
          message: messages[index],
          group: group,
          onEditMember: _editMember,
        ),
      ),
    );
  }

  Widget _buildComposer(AppStrings strings, ChatGroup group) {
    final bool sending = _controller.sending;
    // The gesture bar's own inset is the bottom gap; 8 only where it has none.
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: <Widget>[
                  for (final String member in group.members)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Builder(
                        builder: (BuildContext context) {
                          final CliAgent agent = _agentForKey(member);
                          return ActionChip(
                            label: Text('@${agent.label}'),
                            onPressed: isCliAgentSelectable(agent)
                                ? () => _insertMention(member)
                                : () =>
                                    showAgentUnavailableSnack(context, agent),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: usesHardwareKeyboard
                      ? Focus(
                          onKeyEvent: _handleComposerKey,
                          child: _GroupComposerField(
                            focusNode: _inputFocus,
                            controller: _input,
                            hintText: strings.groupComposerHint,
                            onSubmitted: _send,
                          ),
                        )
                      : _GroupComposerField(
                          focusNode: _inputFocus,
                          controller: _input,
                          hintText: strings.groupComposerHint,
                          onSubmitted: null,
                        ),
                ),
                const SizedBox(width: 8),
                sending
                    ? IconButton.filledTonal(
                        tooltip: strings.cancel,
                        onPressed: _controller.cancel,
                        icon: const Icon(Icons.stop),
                      )
                    : IconButton.filled(
                        tooltip: strings.send,
                        onPressed: _send,
                        icon: const Icon(Icons.send),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _onMenu(String action, ChatGroup group) {
    switch (action) {
      case 'members':
        _manageMembers(group);
        break;
      case 'clear':
        _controller.clearTranscript();
        break;
      case 'delete':
        _confirmDelete(group);
        break;
    }
  }

  void _showGroupSwitcher() {
    final AppStrings strings = context.l10n;
    final ChatGroup? selected = _controller.selected;
    final bool acrylic = widget.settingsController.wallpaper.bytes != null;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: acrylic ? Colors.transparent : null,
      builder: (BuildContext context) {
        return ChatChromeSurface(
          acrylic: acrylic,
          color: Theme.of(context).colorScheme.surfaceContainer,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final ChatGroup group in _controller.groups)
                  ListTile(
                    leading: const Icon(Icons.groups_2_outlined),
                    title: Text(group.name),
                    subtitle: Text(group.memberLabels.join(' · ')),
                    selected: group.id == _controller.selected?.id,
                    onTap: () {
                      Navigator.of(context).pop();
                      _controller.selectGroup(group);
                    },
                  ),
                if (_controller.groups.isNotEmpty) const Divider(height: 1),
                if (selected != null)
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text(strings.saveSwarmTemplate),
                    onTap: () {
                      Navigator.of(context).pop();
                      _saveTemplate(selected);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.upload_file_outlined),
                  title: Text(strings.importSwarmTemplate),
                  onTap: () {
                    Navigator.of(context).pop();
                    _importTemplate();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _createGroup() async {
    final SwarmForm? result = await _showSwarmForm(context.l10n.newGroup);
    if (result == null) return;
    await _controller.createGroup(
      result.name,
      result.members,
      workdir: result.workdir,
      configs: result.configs,
    );
  }

  Future<void> _manageMembers(ChatGroup group) async {
    final SwarmForm? result = await _showSwarmForm(
      context.l10n.manageMembers,
      initialName: group.name,
      initialMembers: group.members,
      initialWorkdir: group.workdir,
      initialConfigs: group.memberConfigs,
      nameEditable: false,
      workTreeEditable: false,
    );
    if (result == null) return;
    await _controller.updateMembers(
      group,
      result.members,
      configs: result.configs,
    );
  }

  // Tapping a member's avatar in the transcript opens its swarm-scoped nickname
  // and prompt for editing. Saving persists only that member's config (members
  // stay the same), so a renamed/instructed member takes effect from the next
  // round on. Only members still in the swarm are editable.
  Future<void> _editMember(ChatGroup group, String agentKey) async {
    if (!group.members.contains(agentKey)) return;
    final Map<String, String> current =
        group.memberConfigs[agentKey] ?? const <String, String>{};
    final MemberPersona? result = await showDialog<MemberPersona>(
      context: context,
      builder: (BuildContext context) => MemberPersonaDialog(
        agentKey: agentKey,
        initialNickname: current['nickname'] ?? '',
        initialPrompt: current['prompt'] ?? '',
      ),
    );
    if (result == null) return;
    final Map<String, Map<String, String>> configs =
        <String, Map<String, String>>{
      for (final MapEntry<String, Map<String, String>> e
          in group.memberConfigs.entries)
        e.key: <String, String>{...e.value},
    };
    final Map<String, String> config =
        configs.putIfAbsent(agentKey, () => <String, String>{});
    if (result.nickname.trim().isEmpty) {
      config.remove('nickname');
    } else {
      config['nickname'] = result.nickname.trim();
    }
    if (result.prompt.trim().isEmpty) {
      config.remove('prompt');
    } else {
      config['prompt'] = result.prompt.trim();
    }
    await _controller.updateMembers(group, group.members, configs: configs);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // Save the swarm as a reusable template by downloading it as a JSON file (same
  // path the file browser uses), so it can be shared or re-imported later. Drops
  // the id/workdir/transcript — only name, members and per-member configs travel.
  Future<void> _saveTemplate(ChatGroup group) async {
    final AppStrings strings = context.l10n;
    try {
      final String json = const JsonEncoder.withIndent('  ')
          .convert(swarmTemplateToJson(group));
      final List<int> data = utf8.encode(json);
      await saveDownloadStream(
        fileName: swarmTemplateFileName(group.name),
        total: data.length,
        bytes: Stream<List<int>>.value(data),
        onProgress: (_, __) {},
      );
      _showSnack(strings.swarmTemplateSaved);
    } catch (err) {
      _showSnack(strings.swarmTemplateFailed(err));
    }
  }

  // Import a template file and create a swarm from it in the current workspace.
  // Unknown agents are dropped backend-side; the new swarm uses the default work
  // tree, since a template carries no machine-specific path.
  Future<void> _importTemplate() async {
    final AppStrings strings = context.l10n;
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final Uint8List? bytes = result.files.single.bytes;
      if (bytes == null) {
        _showSnack(strings.swarmTemplateInvalid);
        return;
      }
      final SwarmTemplate template = parseSwarmTemplate(utf8.decode(bytes));
      final ChatGroup? created = await _controller.createGroup(
        template.name,
        template.members,
        configs: template.configs,
      );
      if (created != null) {
        _showSnack(strings.swarmTemplateImported(created.name));
      }
    } on FormatException {
      _showSnack(strings.swarmTemplateInvalid);
    } catch (err) {
      _showSnack(strings.swarmTemplateFailed(err));
    }
  }

  Future<SwarmForm?> _showSwarmForm(
    String title, {
    String initialName = '',
    List<String> initialMembers = const <String>[],
    String initialWorkdir = '',
    Map<String, Map<String, String>> initialConfigs =
        const <String, Map<String, String>>{},
    bool nameEditable = true,
    bool workTreeEditable = true,
  }) {
    return showDialog<SwarmForm>(
      context: context,
      builder: (BuildContext context) => SwarmFormDialog(
        title: title,
        agents: _agents,
        backend: _controller.backend,
        initialName: initialName,
        initialMembers: initialMembers,
        initialWorkdir: initialWorkdir,
        initialConfigs: initialConfigs,
        nameEditable: nameEditable,
        workTreeEditable: workTreeEditable,
      ),
    );
  }

  Future<void> _confirmDelete(ChatGroup group) async {
    final AppStrings strings = context.l10n;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(strings.deleteGroup),
        content: Text(strings.deleteGroupConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) await _controller.deleteGroup(group);
  }
}

class _GroupComposerField extends StatelessWidget {
  const _GroupComposerField({
    required this.focusNode,
    required this.controller,
    required this.hintText,
    required this.onSubmitted,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final String hintText;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      focusNode: focusNode,
      controller: controller,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      minLines: 1,
      maxLines: 5,
      textInputAction:
          onSubmitted == null ? TextInputAction.newline : TextInputAction.send,
      decoration: InputDecoration(
        hintText: hintText,
        fillColor: WallpaperScope.enabledOf(context)
            ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.18)
            : null,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.group,
    this.onEditMember,
  });

  final ChatMessage message;

  /// The swarm this transcript belongs to, used to resolve a member's current
  /// nickname (so renames apply to past messages too) and to gate avatar editing.
  final ChatGroup? group;

  /// Opens the member editor when its avatar is tapped. Null disables editing.
  final void Function(ChatGroup group, String agentKey)? onEditMember;

  // A member's display name: its current swarm nickname wins (so a rename
  // re-labels earlier messages too), then the label recorded with the message,
  // then the agent's default label.
  String _memberLabel(String? author) {
    final Map<String, String>? config =
        author == null ? null : group?.memberConfigs[author];
    final String? nickname = config == null ? null : config['nickname'];
    if (nickname != null && nickname.trim().isNotEmpty) return nickname.trim();
    final Object? recorded = message.metadata['agentLabel'];
    if (recorded is String && recorded.trim().isNotEmpty) return recorded;
    return groupAuthorLabel(author);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isHuman = message.role == ChatRole.user;
    final String? author = message.metadata['author'] as String?;
    final String label =
        isHuman ? groupAuthorLabel('human') : _memberLabel(author);
    final bool canEdit = !isHuman &&
        author != null &&
        group != null &&
        onEditMember != null &&
        group!.members.contains(author);
    final bool streaming = message.metadata['streaming'] == true;
    final bool awaitingFirstToken =
        message.metadata['awaitingFirstToken'] == true;
    final bool cancelled = message.metadata['cancelled'] == true;
    final Color textColor = isHuman
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    // Per-segment timestamps + collapse, shared with the single-agent chat: a
    // multi-message reply shows each follow-up with its own time, the earlier
    // ones folded behind a toggle. The leading spinner becomes typing dots.
    final List<MessageSegment> segments = message.segments;
    final bool segmented = !isHuman && segments.length > 1;
    final bool awaiting = awaitingFirstToken && message.content.isEmpty;
    final DateTime stampTime =
        (!isHuman && segments.isNotEmpty && segments.first.createdAt != null)
            ? segments.first.createdAt!
            : message.createdAt;

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (awaiting)
          TypingDots(color: textColor)
        else if (isHuman)
          Text(
            message.content,
            style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
          )
        else if (segmented)
          SegmentedContent(
            segments: segments,
            color: textColor,
            formatInlineEmphasis: !streaming,
          )
        else if (message.content.isNotEmpty)
          MessageText(
            text: message.content,
            color: textColor,
            formatInlineEmphasis: !streaming,
          )
        else if (cancelled)
          MessageText(
            text: '_cancelled_',
            color: textColor,
            formatInlineEmphasis: true,
          ),
        if (cancelled && message.content.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          MessageStatus(
            icon: Icons.stop_circle_outlined,
            text: context.l10n.cancelled,
            color: textColor,
          ),
        ],
      ],
    );
    // Every message shows when it was sent/received. Segmented replies carry
    // an inline time per follow-up, so theirs is omitted to avoid duplicating
    // the last segment's time.
    final String? time = segmented || awaiting
        ? null
        : formatShortTime(context, stampTime.toIso8601String());

    // A member's reply spans the full width, headed by its avatar and name;
    // only the human's message is a right-aligned bubble.
    if (!isHuman) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: ReplyPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ReplyHeader(
                agentKey: author,
                label: label,
                time: time,
                onIconTap: canEdit ? () => onEditMember!(group!, author) : null,
              ),
              content,
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: ChatChromeSurface(
              acrylic: WallpaperScope.enabledOf(context),
              color: theme.colorScheme.primaryContainer,
              border: WallpaperScope.enabledOf(context)
                  ? Border.all(color: theme.colorScheme.outlineVariant)
                  : const Border(),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: DefaultSelectionStyle.merge(
                  selectionColor: textColor.withValues(alpha: 0.35),
                  child: content,
                ),
              ),
            ),
          ),
          if (time != null)
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6, top: 2),
              child: Text(
                time,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ChatChromeSurface(
      acrylic: WallpaperScope.enabledOf(context),
      color: theme.colorScheme.errorContainer,
      border: const Border(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SizedBox(
          width: double.infinity,
          child: Text(
            message,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
        ),
      ),
    );
  }
}
