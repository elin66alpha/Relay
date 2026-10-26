import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/models/cli_agent.dart';

void main() {
  test('known agents list Cursor between Codex and OpenCode', () {
    expect(
      knownCliAgents.map((CliAgent agent) => agent.key).toList(),
      <String>['claude', 'codex', 'cursor', 'opencode', 'hermes'],
    );
    expect(defaultAuthKindForAgent('cursor'), 'oauth');
  });

  test('parses agent status fields from backend payload', () {
    final CliAgent agent = CliAgent.fromJson(<String, Object?>{
      'key': 'hermes',
      'label': 'Hermes',
      'description': 'Hermes CLI',
      'installed': true,
      'authed': false,
      'authKind': 'apiKey',
      'usable': false,
    });

    expect(agent.key, 'hermes');
    expect(agent.installed, true);
    expect(agent.authed, false);
    expect(agent.authKind, 'apiKey');
    expect(agent.usable, false);
  });

  test('old agent payloads remain selectable by default', () {
    final CliAgent agent = CliAgent.fromJson(<String, Object?>{
      'key': 'claude',
      'label': 'Claude Code',
      'description': 'Anthropic Claude Code CLI',
    });

    expect(agent.installed, true);
    expect(agent.authed, true);
    expect(agent.usable, true);
    expect(agent.authKind, 'oauth');
  });

  test(
    'derives opencode usability from install state when usable is omitted',
    () {
      final CliAgent installed = CliAgent.fromJson(<String, Object?>{
        'key': 'opencode',
        'label': 'OpenCode',
        'description': 'OpenCode CLI',
        'installed': true,
        'authed': false,
        'authKind': 'apiKeyOptional',
      });
      final CliAgent missing = CliAgent.fromJson(<String, Object?>{
        'key': 'opencode',
        'label': 'OpenCode',
        'description': 'OpenCode CLI',
        'installed': false,
        'authed': false,
        'authKind': 'apiKeyOptional',
      });

      expect(installed.usable, true);
      expect(missing.usable, false);
    },
  );

  test('selection predicate blocks agents that are not usable', () {
    const CliAgent needsLogin = CliAgent(
      key: 'codex',
      label: 'Codex',
      description: 'OpenAI Codex CLI',
      installed: true,
      authed: false,
      usable: false,
      authKind: 'oauth',
    );
    const CliAgent ready = CliAgent(
      key: 'opencode',
      label: 'OpenCode',
      description: 'OpenCode CLI',
      installed: true,
      authed: true,
      usable: true,
      authKind: 'apiKeyOptional',
    );

    expect(isCliAgentSelectable(needsLogin), false);
    expect(isCliAgentSelectable(ready), true);
  });

  test('ignores a legacy credentialExpiresAt from older backends', () {
    final Map<String, Object?> payload = <String, Object?>{
      'key': 'claude',
      'label': 'Claude Code',
      'description': 'Anthropic Claude Code CLI',
    };
    final CliAgent agent = CliAgent.fromJson(<String, Object?>{
      ...payload,
      'credentialExpiresAt': 1893456000000,
    });

    expect(agent, CliAgent.fromJson(payload));
    expect(agent.toJson().containsKey('credentialExpiresAt'), isFalse);
    expect(agent.authed, isTrue);
  });
}
