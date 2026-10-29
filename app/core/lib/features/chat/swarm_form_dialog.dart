import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_options.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/group.dart';
import '../../core/widgets/agent_icon.dart';
import '../cli_agents/agent_status_lights.dart';
import 'work_tree_picker_dialog.dart';

class SwarmForm {
  const SwarmForm({
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

class MemberPersona {
  const MemberPersona({required this.nickname, required this.prompt});

  final String nickname;
  final String prompt;
}

/// A swarm reduced to its reusable parts: name, roster, and per-member config
/// (incl. nickname/prompt). No id/workdir/transcript, so it travels between
/// workspaces and people.
class SwarmTemplate {
  const SwarmTemplate({
    required this.name,
    required this.members,
    required this.configs,
  });

  final String name;
  final List<String> members;
  final Map<String, Map<String, String>> configs;
}

const String _swarmTemplateMarker = 'relaySwarmTemplate';

Map<String, Object?> swarmTemplateToJson(ChatGroup group) {
  return <String, Object?>{
    _swarmTemplateMarker: 1,
    'name': group.name,
    'members': group.members,
    'memberConfigs': group.memberConfigs,
  };
}

/// Parse a downloaded template back into its parts. Throws [FormatException] on
/// malformed JSON or a roster with no members. Reuses [ChatGroup.fromJson] for
/// the per-member config sanitization so both directions share one parser.
SwarmTemplate parseSwarmTemplate(String raw) {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('not a template object');
  final List<String> members = (decoded['members'] as List?)
          ?.map((Object? m) => m?.toString() ?? '')
          .where((String m) => m.isNotEmpty)
          .toList(growable: false) ??
      const <String>[];
  if (members.isEmpty) throw const FormatException('template has no members');
  final ChatGroup parsed = ChatGroup.fromJson(<String, Object?>{
    'members': members,
    'memberConfigs': decoded['memberConfigs'],
  });
  final String? name = decoded['name'] as String?;
  return SwarmTemplate(
    name: (name != null && name.trim().isNotEmpty) ? name.trim() : 'Swarm',
    members: members,
    configs: parsed.memberConfigs,
  );
}

String swarmTemplateFileName(String name) {
  final String slug = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'swarm-${slug.isEmpty ? 'template' : slug}.json';
}

/// Edit one member's swarm-scoped nickname and work/prompt, reached by tapping its
/// avatar in the transcript. Returns the new values; the caller persists them.
class MemberPersonaDialog extends StatefulWidget {
  const MemberPersonaDialog({
    super.key,
    required this.agentKey,
    required this.initialNickname,
    required this.initialPrompt,
  });

  final String agentKey;
  final String initialNickname;
  final String initialPrompt;

  @override
  State<MemberPersonaDialog> createState() => _MemberPersonaDialogState();
}

class _MemberPersonaDialogState extends State<MemberPersonaDialog> {
  late final TextEditingController _nickname =
      TextEditingController(text: widget.initialNickname);
  late final TextEditingController _prompt =
      TextEditingController(text: widget.initialPrompt);

  @override
  void dispose() {
    _nickname.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    return AlertDialog(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AgentIcon(agentKey: widget.agentKey, size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              strings.editMemberTitle(cliAgentByKey(widget.agentKey).label),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _nickname,
              decoration: InputDecoration(
                labelText: strings.memberNickname,
                hintText: strings.memberNicknameHint,
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _prompt,
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: strings.memberPrompt,
                hintText: strings.memberPromptHint,
                border: const OutlineInputBorder(),
                isDense: true,
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
          onPressed: () => Navigator.of(context).pop(
            MemberPersona(
              nickname: _nickname.text,
              prompt: _prompt.text,
            ),
          ),
          child: Text(strings.ok),
        ),
      ],
    );
  }
}

/// Create / edit a swarm: name, work tree, members, and — per selected member —
/// model / effort / permission. Existing members load their catalogs when the
/// dialog opens; other catalogs are fetched lazily when an agent is selected.
class SwarmFormDialog extends StatefulWidget {
  const SwarmFormDialog({
    super.key,
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
  State<SwarmFormDialog> createState() => _SwarmFormDialogState();
}

class _SwarmFormDialogState extends State<SwarmFormDialog> {
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
  // Per-member swarm-scoped nickname / prompt fields, lazily created and seeded
  // from the swarm being edited. Kept as controllers (not inline initialValue) so
  // their text survives the setState rebuilds that toggling other members causes.
  final Map<String, TextEditingController> _nicknameControllers =
      <String, TextEditingController>{};
  final Map<String, TextEditingController> _promptControllers =
      <String, TextEditingController>{};
  String? _validationError;

  @override
  void initState() {
    super.initState();
    for (final String agentKey in widget.initialMembers) {
      unawaited(_ensureCatalog(agentKey));
    }
  }

  TextEditingController _personaController(
    Map<String, TextEditingController> map,
    String agentKey,
    String field,
  ) {
    return map.putIfAbsent(
      agentKey,
      () => TextEditingController(text: _configs[agentKey]?[field] ?? ''),
    );
  }

  void _onPersonaChanged(String agentKey, String field, String value) {
    final Map<String, String> config =
        _configs.putIfAbsent(agentKey, () => <String, String>{});
    if (value.trim().isEmpty) {
      config.remove(field);
    } else {
      config[field] = value;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final TextEditingController c in _nicknameControllers.values) {
      c.dispose();
    }
    for (final TextEditingController c in _promptControllers.values) {
      c.dispose();
    }
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

  // Fetch (once) the agent's option catalog and reconcile every selection. The
  // effort list can depend on the selected model, so model is resolved first.
  Future<void> _ensureCatalog(String agentKey) async {
    if (_catalogs.containsKey(agentKey) || _loading.contains(agentKey)) return;
    setState(() => _loading.add(agentKey));
    try {
      final AgentOptionsCatalog catalog =
          await widget.backend.fetchAgentOptions(agentKey);
      if (!mounted) return;
      setState(() {
        _catalogs[agentKey] = catalog;
        final Map<String, String> config = _configs.putIfAbsent(
          agentKey,
          () => <String, String>{},
        );
        _normalizeConfig(catalog, config);
      });
    } on BackendException {
      // A catalog that fails to load just leaves the agent on backend defaults;
      // the member is still added.
    } finally {
      if (mounted) setState(() => _loading.remove(agentKey));
    }
  }

  void _normalizeConfig(
    AgentOptionsCatalog catalog,
    Map<String, String> config,
  ) {
    final String? modelId = catalog.supportsGroup('model')
        ? catalog.resolveSelection('model', config['model'])
        : null;
    if (modelId == null) {
      config.remove('model');
    } else {
      config['model'] = modelId;
    }

    for (final String group in <String>['effort', 'permission']) {
      if (!catalog.supportsGroup(group)) {
        config.remove(group);
        continue;
      }
      final String? resolved = catalog.resolveSelection(
        group,
        config[group],
        modelId: modelId,
      );
      if (resolved == null) {
        config.remove(group);
      } else {
        config[group] = resolved;
      }
    }
  }

  List<AgentOption> _optionsForGroup(
    AgentOptionsCatalog catalog,
    Map<String, String> config,
    String group,
  ) {
    final String? modelId = catalog.resolveSelection(
      'model',
      config['model'],
    );
    return catalog.optionsFor(group, modelId: modelId);
  }

  void _onOptionChanged(
    String agentKey,
    String group,
    String id,
    AgentOptionsCatalog catalog,
  ) {
    setState(() {
      final Map<String, String> config = _configs.putIfAbsent(
        agentKey,
        () => <String, String>{},
      );
      config[group] = id;
      _normalizeConfig(catalog, config);
    });
  }

  Future<void> _pickWorkTree() async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          WorkTreePickerDialog(backend: widget.backend, start: _workdir),
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
    for (final String key in members) {
      final AgentOptionsCatalog? catalog = _catalogs[key];
      final Map<String, String>? config = _configs[key];
      if (catalog != null && config != null) {
        _normalizeConfig(catalog, config);
      }
    }
    final Map<String, Map<String, String>> configs =
        <String, Map<String, String>>{
      for (final String key in members)
        if (_configs[key] != null && _configs[key]!.isNotEmpty)
          key: <String, String>{..._configs[key]!},
    };
    Navigator.of(context).pop(
      SwarmForm(
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
    final Map<String, String> config =
        _configs[agent.key] ?? const <String, String>{};
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
          subtitle:
              usable ? null : Text(agentUnavailableMessage(strings, agent)),
          secondary: AgentStatusLights(agent: agent, compact: true),
          onChanged: (bool? value) => _toggleMember(agent.key, value == true),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (_loading.contains(agent.key))
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (catalog != null)
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final String group in _groupOrder)
                        if (catalog.supportsGroup(group) &&
                            _optionsForGroup(catalog, config, group).isNotEmpty)
                          _buildOptionDropdown(
                            strings,
                            agent.key,
                            group,
                            catalog,
                          ),
                    ],
                  ),
                _buildPersonaFields(strings, agent.key),
              ],
            ),
          ),
      ],
    );
  }

  // The swarm-scoped nickname + work/prompt for one member. Independent of the
  // option catalog, so they show even while it loads or fails.
  Widget _buildPersonaFields(AppStrings strings, String agentKey) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller:
                _personaController(_nicknameControllers, agentKey, 'nickname'),
            onChanged: (String value) =>
                _onPersonaChanged(agentKey, 'nickname', value),
            decoration: InputDecoration(
              labelText: strings.memberNickname,
              hintText: strings.memberNicknameHint,
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller:
                _personaController(_promptControllers, agentKey, 'prompt'),
            onChanged: (String value) =>
                _onPersonaChanged(agentKey, 'prompt', value),
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: strings.memberPrompt,
              hintText: strings.memberPromptHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionDropdown(
    AppStrings strings,
    String agentKey,
    String group,
    AgentOptionsCatalog catalog,
  ) {
    final Map<String, String> config =
        _configs[agentKey] ?? const <String, String>{};
    final String? modelId = catalog.resolveSelection(
      'model',
      config['model'],
    );
    final String? value = catalog.resolveSelection(
      group,
      config[group],
      modelId: modelId,
    );
    // Swarms offer only first-page models; a member already on a grouped one
    // keeps it listed so the dropdown still shows its choice.
    final List<AgentOption> options = catalog
        .optionsFor(group, modelId: modelId)
        .where((AgentOption o) => o.group == null || o.id == value)
        .toList();
    // Bound the width and let the button ellipsize: some catalogs (opencode)
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
          _onOptionChanged(agentKey, group, id, catalog);
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
