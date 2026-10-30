// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/models/cli_agent.dart';
import '../../core/i18n/app_strings.dart';
import 'bot_chat_controller.dart';

class HistorySearchDialog extends StatefulWidget {
  const HistorySearchDialog({super.key, required this.chatController});

  final BotChatController chatController;

  @override
  State<HistorySearchDialog> createState() => _HistorySearchDialogState();
}

class _HistorySearchDialogState extends State<HistorySearchDialog> {
  final TextEditingController _query = TextEditingController();
  Future<List<ChatHistorySearchResult>>? _future;
  bool _currentAgentOnly = false;
  // The term the shown results actually came from, which is not necessarily
  // what the field holds now. The caller highlights this one.
  String _searchedFor = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final String query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searchedFor = query;
      _future = widget.chatController.searchHistory(
        query,
        currentAgentOnly: _currentAgentOnly,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.searchChats),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _query,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: context.l10n.searchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _currentAgentOnly,
                title: Text(context.l10n.currentAgentOnly),
                onChanged: (bool value) {
                  setState(() {
                    _currentAgentOnly = value;
                  });
                  if (_future != null) _search();
                },
              ),
              SizedBox(
                height: 320,
                child: _HistorySearchResults(
                  future: _future,
                  onSelected: (ChatHistorySearchResult result) =>
                      Navigator.of(context).pop(
                    (hit: result, query: _searchedFor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _search, child: Text(context.l10n.searchChats)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }
}

class _HistorySearchResults extends StatelessWidget {
  const _HistorySearchResults({required this.future, required this.onSelected});

  final Future<List<ChatHistorySearchResult>>? future;
  final ValueChanged<ChatHistorySearchResult> onSelected;

  @override
  Widget build(BuildContext context) {
    if (future == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<ChatHistorySearchResult>>(
      future: future,
      builder: (
        BuildContext context,
        AsyncSnapshot<List<ChatHistorySearchResult>> snapshot,
      ) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Text(
            context.l10n.searchFailed(snapshot.error!),
            style: TextStyle(color: colors.error),
          );
        }
        final List<ChatHistorySearchResult> results =
            snapshot.data ?? const <ChatHistorySearchResult>[];
        if (results.isEmpty) {
          return Align(
            alignment: Alignment.topLeft,
            child: Text(
              context.l10n.noSearchResults,
              style: TextStyle(color: colors.outline),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          itemCount: results.length,
          separatorBuilder: (BuildContext context, int index) =>
              const Divider(height: 1),
          itemBuilder: (BuildContext context, int index) {
            final ChatHistorySearchResult result = results[index];
            final CliAgent agent = cliAgentByKey(result.agentKey);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${agent.label} - ${result.sessionName}'),
              subtitle: Text(
                result.snippet,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelected(result),
            );
          },
        );
      },
    );
  }
}
