import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_options.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/group.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/time_format.dart';
import '../cli_agents/agent_status_lights.dart';
import '../cli_agents/cli_agents_controller.dart';
import 'chat_content.dart';
import 'group_chat_controller.dart';

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
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        final ChatGroup? group = _controller.selected;
        return Scaffold(
          appBar: AppBar(
            title: InkWell(
              onTap: _controller.groups.isEmpty ? null : _showGroupSwitcher,
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
              if (group != null) _buildComposer(strings, group),
            ],
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
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: messages.length,
      itemBuilder: (BuildContext context, int index) =>
          _MessageBubble(message: messages[index]),
    );
  }

  Widget _buildComposer(AppStrings strings, ChatGroup group) {
    final bool sending = _controller.sending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
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
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
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
            ],
          ),
        );
      },
    );
  }

  Future<void> _createGroup() async {
    final _SwarmForm? result = await _showSwarmForm(context.l10n.newGroup);
    if (result == null) return;
    await _controller.createGroup(
      result.name,
      result.members,
      workdir: result.workdir,
      configs: result.configs,
    );
  }

  Future<void> _manageMembers(ChatGroup group) async {
    final _SwarmForm? result = await _showSwarmForm(
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

  Future<_SwarmForm?> _showSwarmForm(
    String title, {
    String initialName = '',
    List<String> initialMembers = const <String>[],
    String initialWorkdir = '',
    Map<String, Map<String, String>> initialConfigs =
        const <String, Map<String, String>>{},
    bool nameEditable = true,
    bool workTreeEditable = true,
  }) {
    return showDialog<_SwarmForm>(
      context: context,
      builder: (BuildContext context) => _SwarmFormDialog(
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
      textInputAction: onSubmitted == null
          ? TextInputAction.newline
          : TextInputAction.send,
      decoration: InputDecoration(
        hintText: hintText,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class _SwarmForm {
  const _SwarmForm({
    required this.name,
    required this.members,
    required this.workdir,
    required this.configs,
  });

  final String name;
  final List<String> members;
  final String workdir;
  final Map<String, Map<String, String>> configs;
}

/// Create / edit a swarm: name, work tree, members, and — per selected member —
/// model / effort / permission. Option catalogs are fetched lazily the first
/// time an agent is selected, so opening the dialog costs no network round-trips.
class _SwarmFormDialog extends StatefulWidget {
  const _SwarmFormDialog({
    required this.title,
    required this.agents,
    required this.backend,
    required this.initialName,
    required this.initialMembers,
    required this.initialWorkdir,
    required this.initialConfigs,
    required this.nameEditable,
    required this.workTreeEditable,
  });

  final String title;
  final List<CliAgent> agents;
  final BackendClient backend;
  final String initialName;
  final List<String> initialMembers;
  final String initialWorkdir;
  final Map<String, Map<String, String>> initialConfigs;
  final bool nameEditable;
  final bool workTreeEditable;

  @override
  State<_SwarmFormDialog> createState() => _SwarmFormDialogState();
}

class _SwarmFormDialogState extends State<_SwarmFormDialog> {
  static const List<String> _groupOrder = <String>[
    'model',
    'effort',
    'permission',
  ];

  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late final Set<String> _selected = <String>{...widget.initialMembers};
  late String _workdir = widget.initialWorkdir;
  // Selected option ids per agent, seeded from the swarm being edited.
  late final Map<String, Map<String, String>> _configs =
      <String, Map<String, String>>{
        for (final MapEntry<String, Map<String, String>> e
            in widget.initialConfigs.entries)
          e.key: <String, String>{...e.value},
      };
  final Map<String, AgentOptionsCatalog> _catalogs =
      <String, AgentOptionsCatalog>{};
  final Set<String> _loading = <String>{};
  String? _validationError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _toggleMember(String agentKey, bool on) async {
    final CliAgent agent = widget.agents.firstWhere(
      (CliAgent item) => item.key == agentKey,
      orElse: () => cliAgentByKey(agentKey),
    );
    if (on && !isCliAgentSelectable(agent)) {
      setState(() {
        _validationError = agentUnavailableMessage(context.l10n, agent);
      });
      return;
    }
    setState(() {
      if (on) {
        _selected.add(agentKey);
      } else {
        _selected.remove(agentKey);
      }
    });
    if (on) await _ensureCatalog(agentKey);
  }

  // Fetch (once) the agent's option catalog and seed any unset selection from
  // its defaults, so a freshly checked member already has valid settings.
  Future<void> _ensureCatalog(String agentKey) async {
    if (_catalogs.containsKey(agentKey) || _loading.contains(agentKey)) return;
    setState(() => _loading.add(agentKey));
    try {
      final AgentOptionsCatalog catalog = await widget.backend
          .fetchAgentOptions(agentKey);
      if (!mounted) return;
      setState(() {
        _catalogs[agentKey] = catalog;
        final Map<String, String> config = _configs.putIfAbsent(
          agentKey,
          () => <String, String>{},
        );
        for (final String group in _groupOrder) {
          if (!catalog.supportsGroup(group)) continue;
          config[group] ??=
              catalog.defaults[group] ??
              (catalog.optionsFor(group).isNotEmpty
                  ? catalog.optionsFor(group).first.id
                  : '');
        }
      });
    } on BackendException {
      // A catalog that fails to load just leaves the agent on backend defaults;
      // the member is still added.
    } finally {
      if (mounted) setState(() => _loading.remove(agentKey));
    }
  }

  Future<void> _pickWorkTree() async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _WorkTreePickerDialog(backend: widget.backend, start: _workdir),
    );
    if (picked != null) setState(() => _workdir = picked);
  }

  void _submit() {
    final AppStrings strings = context.l10n;
    if (_selected.isEmpty) {
      setState(() => _validationError = strings.selectMembers);
      return;
    }
    // Preserve the agent display order for the roster, and keep configs only for
    // members that are actually selected.
    final List<String> members = widget.agents
        .map((CliAgent a) => a.key)
        .where(_selected.contains)
        .toList(growable: false);
    final Map<String, Map<String, String>> configs =
        <String, Map<String, String>>{
          for (final String key in members)
            if (_configs[key] != null && _configs[key]!.isNotEmpty)
              key: _configs[key]!,
        };
    Navigator.of(context).pop(
      _SwarmForm(
        name: _nameController.text.trim(),
        members: members,
        workdir: _workdir.trim(),
        configs: configs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.nameEditable)
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(labelText: strings.groupName),
                ),
              if (widget.workTreeEditable) ...<Widget>[
                const SizedBox(height: 12),
                Text(strings.swarmWorkTree, style: theme.textTheme.labelLarge),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(
                    _workdir.isEmpty ? strings.swarmWorkTreeDefault : _workdir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _workdir.isEmpty
                      ? TextButton(
                          onPressed: _pickWorkTree,
                          child: Text(strings.browse),
                        )
                      : IconButton(
                          tooltip: strings.swarmWorkTreeDefault,
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _workdir = ''),
                        ),
                  onTap: _pickWorkTree,
                ),
              ],
              const SizedBox(height: 12),
              Text(strings.groupMembers, style: theme.textTheme.labelLarge),
              Text(
                strings.swarmConfigureMembersHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              for (final CliAgent agent in widget.agents)
                _buildMemberTile(strings, theme, agent),
              if (_validationError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _validationError!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.nameEditable ? strings.create : strings.ok),
        ),
      ],
    );
  }

  Widget _buildMemberTile(AppStrings strings, ThemeData theme, CliAgent agent) {
    final bool on = _selected.contains(agent.key);
    final AgentOptionsCatalog? catalog = _catalogs[agent.key];
    final bool usable = isCliAgentSelectable(agent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: on,
          title: Text(
            agent.label,
            style: usable
                ? null
                : TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          subtitle: usable
              ? null
              : Text(agentUnavailableMessage(strings, agent)),
          secondary: AgentStatusLights(agent: agent, compact: true),
          onChanged: (bool? value) => _toggleMember(agent.key, value == true),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: _loading.contains(agent.key)
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : catalog == null
                ? const SizedBox.shrink()
                : Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final String group in _groupOrder)
                        if (catalog.supportsGroup(group))
                          _buildOptionDropdown(
                            strings,
                            agent.key,
                            group,
                            catalog,
                          ),
                    ],
                  ),
          ),
      ],
    );
  }

  Widget _buildOptionDropdown(
    AppStrings strings,
    String agentKey,
    String group,
    AgentOptionsCatalog catalog,
  ) {
    final List<AgentOption> options = catalog.optionsFor(group);
    final String? value =
        _configs[agentKey]?[group] ??
        catalog.defaults[group] ??
        (options.isNotEmpty ? options.first.id : null);
    // Bound the width and let the button ellipsize: some catalogs (agy, opencode)
    // have long labels that would otherwise overflow the row.
    return SizedBox(
      width: 188,
      child: DropdownButton<String>(
        value: options.any((AgentOption o) => o.id == value) ? value : null,
        hint: Text(_groupLabel(strings, group)),
        isDense: true,
        isExpanded: true,
        onChanged: (String? id) {
          if (id == null) return;
          setState(() {
            _configs.putIfAbsent(agentKey, () => <String, String>{})[group] =
                id;
          });
        },
        items: <DropdownMenuItem<String>>[
          for (final AgentOption option in options)
            DropdownMenuItem<String>(
              value: option.id,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }

  String _groupLabel(AppStrings strings, String group) {
    switch (group) {
      case 'model':
        return strings.agentModel;
      case 'effort':
        return strings.agentEffort;
      case 'permission':
        return strings.agentPermission;
      default:
        return group;
    }
  }
}

/// A minimal directory navigator over `/api/workdir/browse` for choosing a
/// swarm's work tree. Returns the selected directory's absolute path, or null on
/// cancel. Lists directories only (files can't be a work tree).
class _WorkTreePickerDialog extends StatefulWidget {
  const _WorkTreePickerDialog({required this.backend, required this.start});

  final BackendClient backend;
  final String start;

  @override
  State<_WorkTreePickerDialog> createState() => _WorkTreePickerDialogState();
}

class _WorkTreePickerDialogState extends State<_WorkTreePickerDialog> {
  FsListing? _listing;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(widget.start);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final FsListing listing = await widget.backend.browseWorkdir(path);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on BackendException catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final FsListing? listing = _listing;
    final List<FsEntry> dirs = listing == null
        ? const <FsEntry>[]
        : listing.entries.where((FsEntry e) => e.isDirectory).toList();
    return AlertDialog(
      title: Text(strings.swarmChooseWorkTree),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: <Widget>[
            if (listing != null)
              Row(
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: listing.parentPath == null
                        ? null
                        : () => _load(listing.parentPath!),
                  ),
                  Expanded(
                    child: Text(
                      listing.absolutePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text(_error!))
                  : ListView(
                      children: <Widget>[
                        for (final FsEntry dir in dirs)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(dir.name),
                            onTap: () => _load(dir.absolutePath),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: listing == null
              ? null
              : () => Navigator.of(context).pop(listing.absolutePath),
          child: Text(strings.ok),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isHuman = message.role == ChatRole.user;
    final String? author = message.metadata['author'] as String?;
    final String label = isHuman
        ? groupAuthorLabel('human')
        : (message.metadata['agentLabel'] as String?)?.trim().isNotEmpty == true
        ? message.metadata['agentLabel'] as String
        : groupAuthorLabel(author);
    final bool streaming = message.metadata['streaming'] == true;
    final bool awaitingFirstToken =
        message.metadata['awaitingFirstToken'] == true;
    final bool cancelled = message.metadata['cancelled'] == true;
    final Color bubbleColor = isHuman
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: isHuman
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (awaiting)
                  TypingDots(color: textColor)
                else if (isHuman)
                  SelectableText(
                    message.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: textColor,
                    ),
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
            ),
          ),
          // Every message shows when it was sent/received. Segmented bubbles
          // carry an inline time per follow-up, so the trailing stamp is hidden
          // for them to avoid duplicating the last segment's time.
          if (!segmented && !awaiting)
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6, top: 2),
              child: Text(
                formatShortTime(context, stampTime.toIso8601String()),
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
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        message,
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }
}
