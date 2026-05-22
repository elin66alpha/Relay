import 'package:flutter/material.dart';

import '../../core/models/llm_provider.dart';
import '../../core/storage/api_keys_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ApiKeysStore _store = ApiKeysStore();
  Map<LlmProvider, bool>? _presence;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final Map<LlmProvider, bool> presence = await _store.presence();
    if (!mounted) return;
    setState(() => _presence = presence);
  }

  @override
  Widget build(BuildContext context) {
    final Map<LlmProvider, bool>? presence = _presence;
    return Scaffold(
      appBar: AppBar(title: const Text('API keys')),
      body: SafeArea(
        child: presence == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Text(
                      'API key 仅存在本机的安全存储中。'
                      '请求会从设备直接发到对应服务商，不经任何中转。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        height: 1.5,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  ..._buildSection(
                    context,
                    title: '国际',
                    region: ProviderRegion.international,
                    presence: presence,
                  ),
                  ..._buildSection(
                    context,
                    title: '国内',
                    region: ProviderRegion.china,
                    presence: presence,
                  ),
                  ..._buildSection(
                    context,
                    title: '其他',
                    region: ProviderRegion.other,
                    presence: presence,
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _buildSection(
    BuildContext context, {
    required String title,
    required ProviderRegion region,
    required Map<LlmProvider, bool> presence,
  }) {
    final List<LlmProvider> providers = LlmProvider.values
        .where((LlmProvider p) => p.region == region)
        .toList();
    if (providers.isEmpty) return <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      for (final LlmProvider provider in providers)
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: Text(provider.label),
          subtitle: Text(
            presence[provider] == true ? '已配置' : '未配置',
            style: TextStyle(
              color: presence[provider] == true
                  ? const Color(0xFF557A68)
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await _editKey(provider);
            await _refresh();
          },
        ),
    ];
  }

  Future<void> _editKey(LlmProvider provider) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _ApiKeyDialog(
        provider: provider,
        store: _store,
      ),
    );
  }
}

class _ApiKeyDialog extends StatefulWidget {
  const _ApiKeyDialog({required this.provider, required this.store});

  final LlmProvider provider;
  final ApiKeysStore store;

  @override
  State<_ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends State<_ApiKeyDialog> {
  final TextEditingController _ctrl = TextEditingController();
  bool _isSaving = false;
  bool _hasExisting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final String? existing = await widget.store.read(widget.provider);
    if (!mounted) return;
    setState(() => _hasExisting = existing != null);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String docsUrl = widget.provider.docsUrl;
    return AlertDialog(
      title: Text('${widget.provider.label} API key'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (docsUrl.isNotEmpty)
              Text(
                '从 $docsUrl 申请。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  fontSize: 12,
                ),
              )
            else
              Text(
                '用于任何 OpenAI-compatible 的自定义 endpoint。'
                'base URL 在 agent 编辑里逐个填。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: _hasExisting
                    ? '输入新 key 以覆盖（留空则保留）'
                    : widget.provider.apiKeyHint,
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
        if (_hasExisting)
          TextButton(
            onPressed: _isSaving
                ? null
                : () async {
                    final NavigatorState nav = Navigator.of(context);
                    setState(() => _isSaving = true);
                    await widget.store.clear(widget.provider);
                    if (!mounted) return;
                    nav.pop();
                  },
            child: Text(
              '清除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _isSaving
              ? null
              : () async {
                  final NavigatorState nav = Navigator.of(context);
                  final String value = _ctrl.text.trim();
                  if (value.isEmpty) {
                    nav.pop();
                    return;
                  }
                  setState(() => _isSaving = true);
                  await widget.store.write(widget.provider, value);
                  if (!mounted) return;
                  nav.pop();
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
