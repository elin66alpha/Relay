import 'package:flutter/material.dart';

import '../../core/models/agent.dart';
import '../../core/models/llm_provider.dart';
import 'agents_controller.dart';

class AgentEditorScreen extends StatefulWidget {
  const AgentEditorScreen({
    required this.agentsController,
    this.agent,
    super.key,
  });

  final AgentsController agentsController;
  final Agent? agent;

  @override
  State<AgentEditorScreen> createState() => _AgentEditorScreenState();
}

class _AgentEditorScreenState extends State<AgentEditorScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _systemPrompt = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _temperature = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();

  LlmProvider _provider = LlmProvider.claude;
  bool _isSaving = false;

  bool get _isEdit => widget.agent != null;
  bool get _isCustom => _provider == LlmProvider.custom;

  @override
  void initState() {
    super.initState();
    final Agent? agent = widget.agent;
    if (agent != null) {
      _name.text = agent.name;
      _systemPrompt.text = agent.systemPrompt;
      _model.text = agent.model;
      _temperature.text = agent.temperature?.toString() ?? '';
      _baseUrl.text = agent.baseUrlOverride ?? '';
      _provider = agent.provider;
    } else {
      _model.text = _provider.defaultModel;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _systemPrompt.dispose();
    _model.dispose();
    _temperature.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final double? temperature = _temperature.text.trim().isEmpty
        ? null
        : double.tryParse(_temperature.text.trim());
    final String? baseUrl =
        _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim();

    if (_isEdit) {
      final Agent updated = widget.agent!.copyWith(
        name: _name.text.trim(),
        systemPrompt: _systemPrompt.text,
        provider: _provider,
        model: _model.text.trim().isEmpty
            ? _provider.defaultModel
            : _model.text.trim(),
        temperature: temperature,
        baseUrlOverride: baseUrl,
        clearBaseUrlOverride: baseUrl == null,
      );
      await widget.agentsController.update(updated);
    } else {
      final Agent created = Agent.create(
        name: _name.text.trim(),
        systemPrompt: _systemPrompt.text,
        provider: _provider,
        model: _model.text.trim(),
        temperature: temperature,
        baseUrlOverride: baseUrl,
      );
      await widget.agentsController.add(created);
      await widget.agentsController.setActive(created.id);
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final Agent? agent = widget.agent;
    if (agent == null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('删除「${agent.name}」？'),
        content: const Text('该 agent 的全部历史消息也会一起被清除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.agentsController.remove(agent.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _importMarkdown() async {
    final String? raw = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _MarkdownImportDialog(),
    );
    if (raw == null || raw.trim().isEmpty) return;
    final ParsedAgentMarkdown parsed = parseAgentMarkdown(raw);
    setState(() {
      _name.text = parsed.name;
      _systemPrompt.text = parsed.systemPrompt;
      if (parsed.provider != null) _provider = parsed.provider!;
      if (parsed.model != null && parsed.model!.isNotEmpty) {
        _model.text = parsed.model!;
      } else if (_model.text.trim().isEmpty) {
        _model.text = _provider.defaultModel;
      }
      if (parsed.temperature != null) {
        _temperature.text = parsed.temperature.toString();
      }
      if (parsed.baseUrlOverride != null) {
        _baseUrl.text = parsed.baseUrlOverride!;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '编辑 agent' : '新建 agent'),
        actions: <Widget>[
          if (!_isEdit)
            IconButton(
              icon: const Icon(Icons.file_download_outlined),
              tooltip: '从 .md 导入',
              onPressed: _isSaving ? null : _importMarkdown,
            ),
          if (_isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              color: Theme.of(context).colorScheme.error,
              onPressed: _isSaving ? null : _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              if (!_isEdit)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '你可以直接填写下面的字段，也可以从一段 markdown 导入 agent 定义。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                enabled: !_isSaving,
                decoration: const InputDecoration(
                  labelText: '名字',
                  hintText: '例如：编程助手',
                ),
                validator: (String? v) {
                  if (v == null || v.trim().isEmpty) return '请填写名字';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _systemPrompt,
                enabled: !_isSaving,
                minLines: 6,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: 'System prompt',
                  hintText: 'You are…',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<LlmProvider>(
                initialValue: _provider,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '模型提供方'),
                items: _buildProviderItems(),
                onChanged: _isSaving
                    ? null
                    : (LlmProvider? p) {
                        if (p == null) return;
                        setState(() {
                          final bool wasDefault =
                              _model.text == _provider.defaultModel ||
                                  _model.text.trim().isEmpty;
                          _provider = p;
                          if (wasDefault) _model.text = p.defaultModel;
                        });
                      },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _model,
                enabled: !_isSaving,
                decoration: InputDecoration(
                  labelText: '模型名',
                  hintText: _provider.defaultModel.isNotEmpty
                      ? _provider.defaultModel
                      : '例如 gpt-4o',
                ),
                validator: (String? v) {
                  if (_isCustom && (v == null || v.trim().isEmpty)) {
                    return '自定义 provider 必须填模型名';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _baseUrl,
                enabled: !_isSaving,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _isCustom ? 'Base URL (必填)' : 'Base URL (可选，覆盖默认)',
                  hintText: _provider.baseUrl ?? 'https://...',
                ),
                validator: (String? v) {
                  if (_isCustom && (v == null || v.trim().isEmpty)) {
                    return '自定义 provider 必须填 base URL';
                  }
                  if (v != null && v.trim().isNotEmpty) {
                    final Uri? uri = Uri.tryParse(v.trim());
                    if (uri == null ||
                        !(uri.isScheme('http') || uri.isScheme('https'))) {
                      return 'base URL 需要以 http:// 或 https:// 开头';
                    }
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _temperature,
                enabled: !_isSaving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Temperature (可选)',
                  hintText: '留空使用模型默认',
                ),
                validator: (String? v) {
                  if (v == null || v.trim().isEmpty) return null;
                  final double? parsed = double.tryParse(v.trim());
                  if (parsed == null) return '需要数字';
                  if (parsed < 0 || parsed > 2) return '范围 0–2';
                  return null;
                },
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _isSaving ? null : _save,
                child: Text(_isEdit ? '保存' : '创建'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<DropdownMenuItem<LlmProvider>> _buildProviderItems() {
    final List<DropdownMenuItem<LlmProvider>> items =
        <DropdownMenuItem<LlmProvider>>[];
    void addGroup(String label, ProviderRegion region) {
      final List<LlmProvider> group = LlmProvider.values
          .where((LlmProvider p) => p.region == region)
          .toList();
      if (group.isEmpty) return;
      for (final LlmProvider p in group) {
        items.add(
          DropdownMenuItem<LlmProvider>(
            value: p,
            child: Text(p.label, overflow: TextOverflow.ellipsis),
          ),
        );
      }
    }

    addGroup('国际', ProviderRegion.international);
    addGroup('国内', ProviderRegion.china);
    addGroup('其他', ProviderRegion.other);
    return items;
  }
}

class _MarkdownImportDialog extends StatefulWidget {
  const _MarkdownImportDialog();

  @override
  State<_MarkdownImportDialog> createState() => _MarkdownImportDialogState();
}

class _MarkdownImportDialogState extends State<_MarkdownImportDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('粘贴 agent.md'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '支持两种格式：\n'
              '• 带 --- 三横线 frontmatter (name / provider / model / temperature / baseUrl) + 正文\n'
              '• 不带 frontmatter：首行作为名字，其余作为 system prompt',
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              minLines: 10,
              maxLines: 16,
              decoration: const InputDecoration(
                hintText: '---\nname: My Agent\nprovider: kimi\n'
                    'model: kimi-latest\n---\n'
                    'You are…',
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}
