import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_options.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/group.dart';
import '../../core/models/machine_credential.dart';
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
    required this.label,
    required this.initialNickname,
    required this.initialPrompt,
  });

  final String agentKey;
  final String label;
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
          AgentIcon(agentKey: memberAgentKey(widget.agentKey), size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              strings.editMemberTitle(widget.label),
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
            _PersonaFields(nickname: _nickname, prompt: _prompt),
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

class _PersonaFields extends StatelessWidget {
  const _PersonaFields({required this.nickname, required this.prompt});

  final TextEditingController nickname;
  final TextEditingController prompt;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: nickname,
          decoration: InputDecoration(
            labelText: strings.memberNickname,
            hintText: strings.memberNicknameHint,
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: prompt,
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
    );
  }
}

// The effort list can depend on the selected model, so model is resolved
// first; ids the catalog no longer offers fall back to the backend default.
void _normalizeConfig(AgentOptionsCatalog catalog, Map<String, String> config) {
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

/// Another machine from Manage Credentials, as the form offers it: its usable
/// agents and the work directory this device remembers for it.
class _Machine {
  _Machine(this.credential, this.client)
      : peerId = peerIdForBaseUrl(credential.baseUrl);

  final MachineCredential credential;
  final BackendClient client;
  final String peerId;
  List<CliAgent>? agents;
  String workdir = '';
  String? error;

  String memberKey(String agentKey) => '$peerId:$agentKey';
}

/// Create / edit a swarm: pick agents, grouped by machine (this machine first,
/// then every other machine in Manage Credentials). Tapping a selected agent
/// opens its settings: model / effort / permission and the swarm's work tree on
/// this machine; on another machine, the work directory there, since that
/// machine's own settings apply. Nickname and prompt are offered for both.
class SwarmFormDialog extends StatefulWidget {
  const SwarmFormDialog({
    super.key,
    required this.title,
    required this.agents,
    required this.backend,
    required this.localMachineName,
    required this.machines,
    required this.initialName,
    required this.initialMembers,
    required this.initialWorkdir,
    required this.initialConfigs,
    required this.initialPeers,
    required this.nameEditable,
    required this.workTreeEditable,
    this.machineBackend,
    this.onSubmit,
  });

  final String title;
  final List<CliAgent> agents;
  final BackendClient backend;
  final String localMachineName;

  /// Every other machine this device has a credential for.
  final List<MachineCredential> machines;
  final String initialName;
  final List<String> initialMembers;
  final String initialWorkdir;
  final Map<String, Map<String, String>> initialConfigs;
  final Map<String, SwarmPeer> initialPeers;
  final bool nameEditable;
  final bool workTreeEditable;

  /// The client for another machine; a test replaces it.
  final BackendClient Function(MachineCredential machine)? machineBackend;

  /// Optional async submit handler. When non-null, returning a non-null error
  /// string keeps the dialog open and displays the error in the form.
  final Future<String?> Function(SwarmForm form)? onSubmit;

  @override
  State<SwarmFormDialog> createState() => _SwarmFormDialogState();
}

class _SwarmFormDialogState extends State<SwarmFormDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late final Set<String> _selected = <String>{...widget.initialMembers};
  late String _workdir = widget.initialWorkdir;
  late final Map<String, Map<String, String>> _configs =
      <String, Map<String, String>>{
    for (final MapEntry<String, Map<String, String>> e
        in widget.initialConfigs.entries)
      e.key: <String, String>{...e.value},
  };
  final Map<String, AgentOptionsCatalog> _catalogs =
      <String, AgentOptionsCatalog>{};
  late final List<_Machine> _machines = <_Machine>[
    for (final MachineCredential machine in widget.machines)
      _Machine(
        machine,
        (widget.machineBackend ??
            (MachineCredential m) => BackendClient(machine: m))(machine),
      ),
  ];
  String? _validationError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.workTreeEditable && _workdir.isEmpty) {
      unawaited(_loadLocalDefaultWorkdir());
    }
    for (final _Machine machine in _machines) {
      unawaited(_loadMachine(machine));
    }
  }

  Future<void> _loadLocalDefaultWorkdir() async {
    try {
      final WorkdirInfo info = await widget.backend.workdir();
      if (mounted && _workdir.isEmpty && info.defaultDir.isNotEmpty) {
        setState(() => _workdir = info.defaultDir);
      }
    } on BackendException {
      // Old backend or unreachable: leave empty so backend uses its default.
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final _Machine machine in _machines) {
      machine.client.close();
    }
    super.dispose();
  }

  Future<void> _loadMachine(_Machine machine) async {
    try {
      final List<CliAgent> agents = await machine.client.fetchAgents();
      machine.agents = agents.where(isCliAgentSelectable).toList();
    } on BackendException catch (err) {
      machine.error = err.message;
    }
    if (machine.agents != null) {
      try {
        // Default to the peer's own defaultDir, not the last-used solo dir.
        // Older peers omit defaultDir -> empty -> peer uses its default.
        machine.workdir = (await machine.client.workdir()).defaultDir;
      } on BackendException {
        // The member then starts in that machine's default work directory.
      }
    }
    if (mounted) setState(() {});
  }

  // Fetch (once) a local agent's option catalog. A catalog that fails to load
  // leaves the member on backend defaults; it can still be added.
  Future<void> _ensureCatalog(String agentKey) async {
    if (_catalogs.containsKey(agentKey)) return;
    try {
      final AgentOptionsCatalog catalog =
          await widget.backend.fetchAgentOptions(agentKey);
      if (!mounted) return;
      setState(() {
        _catalogs[agentKey] = catalog;
        _normalizeConfig(
          catalog,
          _configs.putIfAbsent(agentKey, () => <String, String>{}),
        );
      });
    } on BackendException {
      // Kept on backend defaults.
    }
  }

  void _addLocal(CliAgent agent) {
    if (!isCliAgentSelectable(agent)) {
      setState(() {
        _validationError = agentUnavailableMessage(context.l10n, agent);
      });
      return;
    }
    setState(() {
      _validationError = null;
      _selected.add(agent.key);
    });
    unawaited(_ensureCatalog(agent.key));
  }

  void _addRemote(_Machine machine, CliAgent agent) {
    final String key = machine.memberKey(agent.key);
    setState(() {
      _validationError = null;
      _selected.add(key);
      if (machine.workdir.isNotEmpty) {
        _configs
            .putIfAbsent(key, () => <String, String>{})
            .putIfAbsent('workdir', () => machine.workdir);
      }
    });
  }

  _Machine? _machineOf(String member) {
    final String? peerId = memberPeerId(member);
    for (final _Machine machine in _machines) {
      if (machine.peerId == peerId) return machine;
    }
    return null;
  }

  String _memberLabel(String member) {
    final String agentLabel = cliAgentByKey(memberAgentKey(member)).label;
    final String? peerId = memberPeerId(member);
    if (peerId == null) return agentLabel;
    final String machineName = _machineOf(member)?.credential.displayName ??
        widget.initialPeers[peerId]?.name ??
        peerId;
    return '$agentLabel ($machineName)';
  }

  Future<void> _editMember(String member) async {
    final bool remote = memberPeerId(member) != null;
    if (!remote) await _ensureCatalog(member);
    if (!mounted) return;
    final _Machine? machine = _machineOf(member);
    final _MemberEdit? result = await showDialog<_MemberEdit>(
      context: context,
      builder: (BuildContext context) => _MemberEditDialog(
        member: member,
        label: _memberLabel(member),
        catalog: remote ? null : _catalogs[member],
        initialConfig: _configs[member] ?? const <String, String>{},
        workdir: remote ? (_configs[member]?['workdir'] ?? '') : _workdir,
        // A remote member's session lives in one work directory on its
        // machine, and the swarm's work tree is fixed once created.
        workdirEditable: remote
            ? machine != null && !widget.initialMembers.contains(member)
            : widget.workTreeEditable,
        pickerBackend: remote ? machine?.client : widget.backend,
      ),
    );
    if (result == null) return;
    setState(() {
      final Map<String, String> config = result.config;
      if (remote) {
        if (result.workdir.isEmpty) {
          config.remove('workdir');
        } else {
          config['workdir'] = result.workdir;
        }
      } else {
        _workdir = result.workdir;
      }
      _configs[member] = config;
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final AppStrings strings = context.l10n;
    if (_selected.isEmpty) {
      setState(() => _validationError = strings.selectMembers);
      return;
    }
    // This machine's agents first, then each other machine's, in the order
    // they are listed; members of machines this device cannot see stay last.
    final List<String> order = <String>[
      for (final CliAgent agent in widget.agents) agent.key,
      for (final _Machine machine in _machines)
        for (final CliAgent agent in machine.agents ?? const <CliAgent>[])
          machine.memberKey(agent.key),
      ...widget.initialMembers,
    ];
    final List<String> members = <String>[];
    for (final String key in order) {
      if (_selected.contains(key) && !members.contains(key)) members.add(key);
    }
    final Map<String, Map<String, String>> configs =
        <String, Map<String, String>>{};
    for (final String key in members) {
      final Map<String, String>? config = _configs[key];
      if (config == null) continue;
      final AgentOptionsCatalog? catalog = _catalogs[key];
      if (catalog != null) _normalizeConfig(catalog, config);
      if (config.isNotEmpty) configs[key] = <String, String>{...config};
    }
    final SwarmForm form = SwarmForm(
      name: _nameController.text.trim(),
      members: members,
      workdir: _workdir.trim(),
      configs: configs,
    );
    if (widget.onSubmit != null) {
      setState(() {
        _submitting = true;
        _validationError = null;
      });
      final String? error = await widget.onSubmit!(form);
      if (!mounted) return;
      if (error != null) {
        setState(() {
          _submitting = false;
          _validationError = error;
        });
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(form);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    final Set<String> visiblePeers =
        _machines.map((_Machine m) => m.peerId).toSet();
    final List<String> unlinked = widget.initialMembers
        .where(
          (String m) =>
              memberPeerId(m) != null &&
              !visiblePeers.contains(memberPeerId(m)),
        )
        .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.nameEditable) ...<Widget>[
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: strings.groupName,
                    hintText: strings.swarmNameOptional,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                strings.swarmPickMembersHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              _MachineSection(
                title: strings.swarmThisMachine(widget.localMachineName),
                icon: Icons.computer_outlined,
                children: <Widget>[
                  for (final CliAgent agent in widget.agents)
                    _memberChip(
                      strings,
                      member: agent.key,
                      agentKey: agent.key,
                      usable: isCliAgentSelectable(agent),
                      onAdd: () => _addLocal(agent),
                    ),
                ],
              ),
              for (final _Machine machine in _machines)
                _MachineSection(
                  title: machine.credential.displayName,
                  icon: Icons.dns_outlined,
                  status: machine.error != null
                      ? strings.swarmMachineUnavailable(machine.error!)
                      : machine.agents == null
                          ? null
                          : machine.agents!.isEmpty
                              ? strings.swarmMachineNoAgents
                              : null,
                  loading: machine.agents == null && machine.error == null,
                  children: <Widget>[
                    for (final CliAgent agent
                        in machine.agents ?? const <CliAgent>[])
                      _memberChip(
                        strings,
                        member: machine.memberKey(agent.key),
                        agentKey: agent.key,
                        usable: true,
                        onAdd: () => _addRemote(machine, agent),
                      ),
                  ],
                ),
              if (unlinked.isNotEmpty)
                _MachineSection(
                  title: strings.swarmMemberNotLinked,
                  icon: Icons.link_off,
                  children: <Widget>[
                    for (final String member in unlinked)
                      _memberChip(
                        strings,
                        member: member,
                        agentKey: memberAgentKey(member),
                        usable: true,
                        onAdd: () => setState(() => _selected.add(member)),
                      ),
                  ],
                ),
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
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(widget.nameEditable ? strings.create : strings.ok),
        ),
      ],
    );
  }

  // An agent tag: tapping an unselected one adds it, tapping a member opens
  // its settings, and its delete icon removes it.
  Widget _memberChip(
    AppStrings strings, {
    required String member,
    required String agentKey,
    required bool usable,
    required VoidCallback onAdd,
  }) {
    final bool on = _selected.contains(member);
    final String? nickname = _configs[member]?['nickname'];
    final String label = nickname != null && nickname.trim().isNotEmpty
        ? nickname.trim()
        : cliAgentByKey(agentKey).label;
    return InputChip(
      key: ValueKey<String>('swarm-member-$member'),
      avatar: AgentIcon(agentKey: agentKey, size: 18),
      label: Text(label),
      selected: on,
      showCheckmark: false,
      onPressed: on ? () => _editMember(member) : onAdd,
      onDeleted: on ? () => setState(() => _selected.remove(member)) : null,
      deleteButtonTooltipMessage: strings.delete,
      labelStyle: usable
          ? null
          : TextStyle(color: Theme.of(context).colorScheme.outline),
    );
  }
}

class _MachineSection extends StatelessWidget {
  const _MachineSection({
    required this.title,
    required this.icon,
    required this.children,
    this.status,
    this.loading = false,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final String? status;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18, color: theme.colorScheme.outline),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (loading)
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (status != null)
            Text(
              status!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (children.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 4, children: children),
        ],
      ),
    );
  }
}

class _MemberEdit {
  const _MemberEdit({required this.config, required this.workdir});

  final Map<String, String> config;
  final String workdir;
}

/// One member's settings. A member on this machine has model / effort /
/// permission ([catalog]) and the swarm's work tree, which all of this
/// machine's members share; a remote member has the work directory on its
/// machine. Both have nickname and prompt.
class _MemberEditDialog extends StatefulWidget {
  const _MemberEditDialog({
    required this.member,
    required this.label,
    required this.catalog,
    required this.initialConfig,
    required this.workdir,
    required this.workdirEditable,
    required this.pickerBackend,
  });

  final String member;
  final String label;
  final AgentOptionsCatalog? catalog;
  final Map<String, String> initialConfig;
  final String workdir;
  final bool workdirEditable;
  final BackendClient? pickerBackend;

  @override
  State<_MemberEditDialog> createState() => _MemberEditDialogState();
}

class _MemberEditDialogState extends State<_MemberEditDialog> {
  static const List<String> _groupOrder = <String>[
    'model',
    'effort',
    'permission',
  ];

  late final Map<String, String> _config = <String, String>{
    ...widget.initialConfig,
  };
  late final TextEditingController _nickname =
      TextEditingController(text: _config['nickname'] ?? '');
  late final TextEditingController _prompt =
      TextEditingController(text: _config['prompt'] ?? '');
  late String _workdir = widget.workdir;

  bool get _remote => memberPeerId(widget.member) != null;

  @override
  void dispose() {
    _nickname.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _pickWorkdir() async {
    final BackendClient? backend = widget.pickerBackend;
    if (backend == null || !widget.workdirEditable) return;
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          WorkTreePickerDialog(backend: backend, start: _workdir),
    );
    if (picked != null) setState(() => _workdir = picked);
  }

  void _save() {
    for (final MapEntry<String, TextEditingController> field
        in <String, TextEditingController>{
      'nickname': _nickname,
      'prompt': _prompt,
    }.entries) {
      final String value = field.value.text.trim();
      if (value.isEmpty) {
        _config.remove(field.key);
      } else {
        _config[field.key] = value;
      }
    }
    Navigator.of(context).pop(
      _MemberEdit(config: _config, workdir: _workdir.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AgentOptionsCatalog? catalog = widget.catalog;
    return AlertDialog(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AgentIcon(agentKey: memberAgentKey(widget.member), size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              strings.editMemberTitle(widget.label),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (catalog != null)
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final String group in _groupOrder)
                      if (catalog.supportsGroup(group) &&
                          catalog
                              .optionsFor(
                                group,
                                modelId: catalog.resolveSelection(
                                  'model',
                                  _config['model'],
                                ),
                              )
                              .isNotEmpty)
                        _buildOptionDropdown(strings, group, catalog),
                  ],
                ),
              if (_remote)
                Text(
                  strings.swarmRemoteSettingsHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              const SizedBox(height: 8),
              _PersonaFields(nickname: _nickname, prompt: _prompt),
              const SizedBox(height: 12),
              Text(
                _remote ? strings.swarmMemberWorkdir : strings.swarmWorkTree,
                style: theme.textTheme.labelLarge,
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  _workdir.isEmpty
                      ? (_remote
                          ? strings.swarmMemberWorkdirDefault
                          : strings.swarmWorkTreeDefault)
                      : _workdir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: _remote ? null : Text(strings.swarmWorkTreeShared),
                trailing: widget.workdirEditable && widget.pickerBackend != null
                    ? TextButton(
                        onPressed: _pickWorkdir,
                        child: Text(strings.browse),
                      )
                    : null,
                onTap: _pickWorkdir,
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
        FilledButton(onPressed: _save, child: Text(strings.ok)),
      ],
    );
  }

  Widget _buildOptionDropdown(
    AppStrings strings,
    String group,
    AgentOptionsCatalog catalog,
  ) {
    final String? modelId = catalog.resolveSelection('model', _config['model']);
    final String? value = catalog.resolveSelection(
      group,
      _config[group],
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
          setState(() {
            _config[group] = id;
            _normalizeConfig(catalog, _config);
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

/// Change a swarm's pinned local work tree and/or its remote members' peer work
/// directories. Calls [onSubmit] and stays open with the error message on failure.
class SwarmWorkdirDialog extends StatefulWidget {
  const SwarmWorkdirDialog({
    super.key,
    required this.group,
    required this.backend,
    required this.localMachineName,
    required this.machines,
    required this.onSubmit,
    this.machineBackend,
  });

  final ChatGroup group;
  final BackendClient backend;
  final String localMachineName;
  final List<MachineCredential> machines;
  final Future<String?> Function(
    String workdir,
    Map<String, String> memberWorkdirs,
  ) onSubmit;
  final BackendClient Function(MachineCredential machine)? machineBackend;

  @override
  State<SwarmWorkdirDialog> createState() => _SwarmWorkdirDialogState();
}

class _SwarmWorkdirDialogState extends State<SwarmWorkdirDialog> {
  late String _localWorkdir = widget.group.workdir;
  late final Map<String, String> _remoteWorkdirs = <String, String>{
    for (final String member in widget.group.members)
      if (memberPeerId(member) != null)
        member: widget.group.memberConfigs[member]?['workdir'] ?? '',
  };
  late final Map<String, BackendClient> _peerClients = <String, BackendClient>{
    for (final MachineCredential machine in widget.machines)
      peerIdForBaseUrl(machine.baseUrl): (widget.machineBackend ??
          (MachineCredential m) => BackendClient(machine: m))(machine),
  };
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    for (final BackendClient client in _peerClients.values) {
      client.close();
    }
    super.dispose();
  }

  Future<void> _pickLocal() async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          WorkTreePickerDialog(backend: widget.backend, start: _localWorkdir),
    );
    if (picked != null && mounted) {
      setState(() {
        _localWorkdir = picked;
        _error = null;
      });
    }
  }

  Future<void> _pickRemote(String member, BackendClient client) async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => WorkTreePickerDialog(
        backend: client,
        start: _remoteWorkdirs[member] ?? '',
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _remoteWorkdirs[member] = picked;
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    if (_submitting) return;
    final String nextLocal = _localWorkdir.trim() != widget.group.workdir
        ? _localWorkdir.trim()
        : '';
    final Map<String, String> changedRemotes = <String, String>{};
    for (final MapEntry<String, String> entry in _remoteWorkdirs.entries) {
      final String prev =
          widget.group.memberConfigs[entry.key]?['workdir'] ?? '';
      final String next = entry.value.trim();
      if (next.isNotEmpty && next != prev) {
        changedRemotes[entry.key] = next;
      }
    }
    if (nextLocal.isEmpty && changedRemotes.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final String? error = await widget.onSubmit(nextLocal, changedRemotes);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _submitting = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    final List<String> remoteMembers = widget.group.members
        .where((String m) => memberPeerId(m) != null)
        .toList();
    return AlertDialog(
      title: Text(strings.changeWorkDirectory),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                strings.changeWorkDirectoryHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                strings.swarmThisMachine(widget.localMachineName),
                style: theme.textTheme.labelLarge,
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  _localWorkdir.isEmpty
                      ? strings.swarmWorkTreeDefault
                      : _localWorkdir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: _submitting ? null : _pickLocal,
                  child: Text(strings.browse),
                ),
                onTap: _submitting ? null : _pickLocal,
              ),
              for (final String member in remoteMembers) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  widget.group.memberLabel(member),
                  style: theme.textTheme.labelLarge,
                ),
                Builder(
                  builder: (BuildContext context) {
                    final String peerId = memberPeerId(member)!;
                    final BackendClient? client = _peerClients[peerId];
                    final String dir = _remoteWorkdirs[member] ?? '';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        client == null ? Icons.link_off : Icons.folder_outlined,
                      ),
                      title: Text(
                        dir.isEmpty ? strings.swarmMemberWorkdirDefault : dir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: client == null
                          ? Text(strings.swarmMemberNotLinked)
                          : null,
                      trailing: client == null
                          ? null
                          : TextButton(
                              onPressed: _submitting
                                  ? null
                                  : () => _pickRemote(member, client),
                              child: Text(strings.browse),
                            ),
                      onTap: client == null || _submitting
                          ? null
                          : () => _pickRemote(member, client),
                    );
                  },
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: _submitting ? null : _save,
          child: Text(strings.ok),
        ),
      ],
    );
  }
}
