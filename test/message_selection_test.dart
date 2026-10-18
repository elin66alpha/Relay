import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/agent_session.dart';
import 'package:relay/core/models/chat_message.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/core/models/group.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/settings/wallpaper.dart';
import 'package:relay/core/storage/machine_credentials_store.dart';
import 'package:relay/core/theme/app_theme.dart';
import 'package:relay/core/widgets/chat_wallpaper.dart';
import 'package:relay/features/chat/agent_controls.dart';
import 'package:relay/features/chat/bot_chat_controller.dart';
import 'package:relay/features/chat/bot_chat_screen.dart';
import 'package:relay/features/chat/cli_agents_drawer.dart';
import 'package:relay/features/cli_agents/cli_agents_controller.dart';
import 'package:relay/features/machines/machine_credentials_controller.dart';
import 'package:relay/features/quota/quota_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _userText = 'Please check the build';
const String _replyText = '**Build passed.**\n\nSee `build.log` for details.';

void main() {
  testWidgets(
      'shared wallpaper and two acrylic layers survive agent and layout changes',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final BotChatController chat = await _openChat(
      tester,
      AppTheme.dark(),
      withWallpaper: true,
      backend: _ChatBackendClient(
        reply: ChatMessage(
          id: 'reply',
          role: ChatRole.assistant,
          content: 'A readable reply',
          createdAt: DateTime.utc(2026),
        ),
      ),
    );
    final BotChatScreen screen =
        tester.widget<BotChatScreen>(find.byType(BotChatScreen));
    final Finder wallpaperImage = find.byWidgetPredicate(
      (Widget widget) => widget is Image && widget.image is MemoryImage,
    );
    expect(tester.widget<Image>(wallpaperImage).opacity!.value, 0.2);
    Iterable<ChatChromeSurface> surfaces() =>
        tester.widgetList<ChatChromeSurface>(find.byType(ChatChromeSurface));
    // Header, sidebar and its machine tile, composer and both bubbles.
    expect(
      surfaces().where((ChatChromeSurface surface) => surface.acrylic),
      hasLength(6),
    );
    await screen.agentsController.setActive('codex');
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChatWallpaper>(find.byType(ChatWallpaper)).wallpaper.bytes,
      isNotNull,
    );
    expect(
      surfaces().where((ChatChromeSurface surface) => surface.acrylic),
      hasLength(6),
    );
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(
      surfaces().every((ChatChromeSurface surface) => surface.acrylic),
      isTrue,
    );
    expect(find.byType(AcrylicAppBarBackground), findsOneWidget);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(
      surfaces().every((ChatChromeSurface surface) => surface.acrylic),
      isTrue,
    );
    Navigator.of(tester.element(find.byType(CliAgentsDrawer))).pop();
    await tester.pumpAndSettle();
    chat.goHome();
    await tester.pumpAndSettle();
    expect(find.text('Current machine'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text("What's new")).dy,
      lessThan(tester.getTopLeft(find.text('Tutorial')).dy),
    );
    expect(find.byType(Card), findsNothing);
    expect(
      surfaces().every((ChatChromeSurface surface) => surface.acrylic),
      isTrue,
    );
    expect(
      tester.widget<ChatWallpaper>(find.byType(ChatWallpaper)).wallpaper.bytes,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('light', AppTheme.light()),
    ('dark', AppTheme.dark()),
  ]) {
    testWidgets('a selection in your own bubble is visible ($name)', (
      WidgetTester tester,
    ) async {
      await _openChat(tester, theme);

      final RichText text = tester.widget<RichText>(
        find.byWidgetPredicate(
          (Widget w) => w is RichText && w.text.toPlainText() == _userText,
        ),
      );
      final Color bubble = theme.colorScheme.primary;
      // The default selection colour is the primary colour, which is also the
      // bubble's fill; the bubble must override it with its text colour.
      expect(
        text.selectionColor,
        theme.colorScheme.onPrimary.withValues(alpha: 0.35),
      );
      expect(text.selectionColor!.withValues(alpha: 1), isNot(bubble));
    });
  }

  testWidgets('the composer surface reaches behind the gesture bar', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    await _openChat(tester, AppTheme.light(), withWallpaper: true);
    final Finder field = find.byType(TextField).last;
    final Finder composer = find
        .ancestor(of: field, matching: find.byType(ChatChromeSurface))
        .first;
    expect(tester.getRect(composer).bottom, 844);
    expect(tester.getRect(field).bottom, lessThanOrEqualTo(844 - 34));
  });

  testWidgets('an empty chat hides its placeholder only over a wallpaper', (
    WidgetTester tester,
  ) async {
    for (final bool withWallpaper in <bool>[false, true]) {
      await _openChat(
        tester,
        AppTheme.light(),
        withWallpaper: withWallpaper,
        backend: _ChatBackendClient(empty: true),
      );
      expect(
        find.textContaining('Start chatting'),
        withWallpaper ? findsNothing : findsOneWidget,
      );
    }
  });

  testWidgets('Edit replaces the draft and focuses it without sending', (
    WidgetTester tester,
  ) async {
    final _ChatBackendClient backend = _ChatBackendClient();
    final BotChatController chat = await _openChat(
      tester,
      AppTheme.light(),
      backend: backend,
    );
    await tester.enterText(find.byType(TextField), 'An unfinished draft');
    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    await tester.pump();

    await tester.tap(find.byTooltip('Edit'));
    await tester.pump();

    final TextField composer = tester.widget<TextField>(find.byType(TextField));
    expect(composer.controller!.text, _userText);
    expect(
      composer.controller!.selection,
      const TextSelection.collapsed(offset: _userText.length),
    );
    expect(composer.focusNode!.hasFocus, isTrue);
    expect(backend.prompts, isEmpty);
    expect(chat.messages, hasLength(1));
  });

  testWidgets('attachments upload during a turn without sending', (
    WidgetTester tester,
  ) async {
    const MethodChannel picker = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
      MethodCall call,
    ) async {
      expect(call.method, 'any');
      expect((call.arguments as Map)['allowMultipleSelection'], isTrue);
      expect((call.arguments as Map)['withData'], isFalse);
      return <Map<String, Object>>[
        for (final String name in <String>['notes.txt', 'photo.png'])
          <String, Object>{'name': name, 'path': '/picked/$name', 'size': 4},
      ];
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        null,
      ),
    );
    final _ChatBackendClient backend = _ChatBackendClient();
    final BotChatController chat = await _openChat(
      tester,
      AppTheme.light(),
      backend: backend,
    );
    unawaited(chat.sendUserText('Run task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(chat.isThinking, isTrue);
    await tester.enterText(find.byType(TextField), 'Review these');
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final DateTime before = DateTime.now();
    await tester.tap(find.text('Attach file'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<ComposerActionButton>(
            find.widgetWithText(ComposerActionButton, 'Attach file'),
          )
          .onPressed,
      isNull,
    );

    final TextEditingController draft =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(draft.text, 'Review these');
    for (int index = 0; index < 2; index += 1) {
      final String returnedPath = '.relay/uploads/returned-$index';
      backend.uploadResults[index].complete(
        FsEntry(
          name: 'returned-$index',
          path: returnedPath,
          absolutePath: '/repo/$returnedPath',
          type: 'file',
          size: 4,
          modifiedAt: '',
        ),
      );
      await tester.pump();
      expect(
        draft.text,
        'Review these\n.relay/uploads/returned-0${index == 1 ? '\n.relay/uploads/returned-1' : ''}',
      );
      expect(
        draft.selection,
        TextSelection.collapsed(offset: draft.text.length),
      );
    }
    final DateTime after = DateTime.now();
    expect(backend.uploads, hasLength(2));
    for (int index = 0; index < 2; index += 1) {
      final upload = backend.uploads[index];
      expect(upload.path, '.relay/uploads');
      expect(upload.createDirectory, isTrue);
      final String original = index == 0 ? 'notes.txt' : 'photo.png';
      expect(
        upload.name,
        matches(RegExp('^\\d{8}-\\d{6}-${RegExp.escape(original)}\$')),
      );
      final DateTime timestamp =
          DateTime.parse(upload.name.substring(0, 15).replaceFirst('-', 'T'));
      expect(
        timestamp.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(timestamp.isAfter(after), isFalse);
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(backend.prompts, <String>['Run task']);
    expect(chat.messages, hasLength(3));
  });

  for (final String kind in <String>['plain', 'thinking', 'segmented']) {
    testWidgets('Copy keeps $kind reply markdown and excludes progress', (
      WidgetTester tester,
    ) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      final _ChatBackendClient backend = _ChatBackendClient(
        reply: ChatMessage(
          id: 'reply-1',
          role: ChatRole.assistant,
          content: kind == 'plain'
              ? _replyText
              : 'I will check the build.\n\n$_replyText',
          createdAt: DateTime.utc(2026),
          metadata: <String, Object?>{
            'progressLines': <String>['Running build'],
            if (kind == 'segmented')
              'segments': <Map<String, Object?>>[
                <String, Object?>{
                  'text': 'I will check the build.',
                  'ts': DateTime.utc(2026).toIso8601String(),
                },
                <String, Object?>{
                  'text': _replyText,
                  'ts': DateTime.utc(2026).toIso8601String(),
                },
              ],
          },
        ),
      );
      await _openChat(tester, AppTheme.light(), backend: backend);

      final Finder reply = find.byKey(const ValueKey<String>('reply-1'));
      expect(
        find.descendant(of: reply, matching: find.byTooltip('Edit')),
        findsNothing,
      );
      expect(find.byTooltip('Edit'), findsOneWidget);
      await tester.tap(
        find.descendant(of: reply, matching: find.byTooltip('Copy')),
      );
      await tester.pump();
      expect(clipboardText, _replyText);
      expect(find.text('Copied.'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('user-1')),
          matching: find.byTooltip('Copy'),
        ),
      );
      await tester.pump();
      expect(clipboardText, _userText);
    });
  }

  testWidgets('Edit works during a turn and pending messages hide actions', (
    WidgetTester tester,
  ) async {
    final _ChatBackendClient backend = _ChatBackendClient();
    final BotChatController chat = await _openChat(
      tester,
      AppTheme.light(),
      backend: backend,
    );
    unawaited(chat.sendUserText('Run task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(chat.isThinking, isTrue);
    final ChatMessage pending = chat.messages.last;
    expect(chat.isStreaming(pending), isTrue);
    expect(
      find.descendant(
        of: find.byKey(ValueKey<String>(pending.id)),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('user-1')),
        matching: find.byTooltip('Edit'),
      ),
    );
    await tester.pump();
    final TextField composer = tester.widget<TextField>(find.byType(TextField));
    expect(composer.controller!.text, _userText);
    expect(composer.focusNode!.hasFocus, isTrue);
    expect(backend.prompts, <String>['Run task']);
    expect(chat.messages, hasLength(3));

    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final ChatMessage queued = chat.messages.last;
    expect(queued.content, _userText);
    expect(chat.isQueued(queued), isTrue);
    expect(composer.controller!.text, isEmpty);
    expect(backend.prompts, <String>['Run task']);
    expect(
      find.descendant(
        of: find.byKey(ValueKey<String>(queued.id)),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
  });
}

Future<BotChatController> _openChat(
  WidgetTester tester,
  ThemeData theme, {
  _ChatBackendClient? backend,
  bool withWallpaper = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  MachineCredentialsStore.resetCacheForTest();
  final Directory support =
      Directory.systemTemp.createTempSync('relay-wallpaper-');
  addTearDown(() => support.deleteSync(recursive: true));
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => support.path,
  );
  final MachineCredential machine = MachineCredential(
    id: 'machine-1',
    name: 'Local test',
    baseUrl: 'http://127.0.0.1:8787',
    token: 'token',
    createdAt: DateTime.utc(2026).toIso8601String(),
  );
  final CliAgentsController agentsController = CliAgentsController();
  final MachineCredentialsController machinesController =
      MachineCredentialsController(store: _MemoryStore(machine));
  final AppSettingsController settingsController = AppSettingsController();
  if (withWallpaper) {
    await settingsController.saveWallpaper(
      Wallpaper(bytes: img.encodePng(img.Image(width: 8, height: 6))),
    );
  }
  final BackendClient backendClient = backend ?? _ChatBackendClient();
  final BotChatController chatController = BotChatController(
    backendClient: backendClient,
    quotaController: QuotaController(backendClient: backendClient),
  );
  addTearDown(chatController.disposeController);

  await agentsController.load();
  await machinesController.load();
  await chatController.loadFor(defaultCliAgents.first, machine);

  await tester.pumpWidget(
    AppScope(
      controller: settingsController,
      child: MaterialApp(
        theme: theme,
        home: BotChatScreen(
          agentsController: agentsController,
          chatController: chatController,
          machinesController: machinesController,
          settingsController: settingsController,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return chatController;
}

class _MemoryStore extends MachineCredentialsStore {
  _MemoryStore(this.machine);

  final MachineCredential machine;

  @override
  Future<List<MachineCredential>> readAll() async =>
      <MachineCredential>[machine];

  @override
  Future<String?> readActiveId() async => machine.id;

  @override
  Future<void> setActive(String id) async {}

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {}

  @override
  Future<void> delete(String id) async {}
}

class _ChatBackendClient extends BackendClient {
  _ChatBackendClient({this.reply, this.empty = false});

  final ChatMessage? reply;
  final bool empty;
  final List<String> prompts = <String>[];
  final List<({String path, String name, bool createDirectory})> uploads =
      <({String path, String name, bool createDirectory})>[];
  final List<Completer<FsEntry>> uploadResults = <Completer<FsEntry>>[
    Completer<FsEntry>(),
    Completer<FsEntry>(),
  ];

  @override
  Future<FsEntry> uploadFileStream({
    required String path,
    required String name,
    required Stream<List<int>> bytes,
    required int length,
    bool createDirectory = false,
  }) {
    expect(length, 4);
    uploads.add((path: path, name: name, createDirectory: createDirectory));
    return uploadResults[uploads.length - 1].future;
  }

  // Stays open: an empty stream would complete and schedule a reconnect timer
  // that outlives the test.
  final StreamController<BackendEvent> _events =
      StreamController<BackendEvent>.broadcast();

  @override
  Stream<BackendEvent> streamEvents() => _events.stream;

  @override
  Future<void> close() async => _events.close();

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async =>
      const <String, bool?>{};

  @override
  Future<List<CliAgent>> fetchAgents({bool verifyCredentials = false}) async =>
      defaultCliAgents;

  @override
  Future<UsageReport> usageReport({String? source}) async =>
      UsageReport.fromJson(const <String, Object?>{});

  @override
  Future<List<String>> recentWorkdirs() async => <String>[];

  @override
  Future<List<ChatGroup>> fetchGroups() async => <ChatGroup>[];

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/repo');

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async =>
      AgentSessionList(
        agentKey: agentKey,
        workdir: '/repo',
        activeSessionId: AgentSession.defaultId,
        sessions: <AgentSession>[AgentSession.fallback()],
      );

  @override
  Future<ChatHistory> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async =>
      ChatHistory(
        messages: <ChatMessage>[
          if (!empty)
            ChatMessage(
              id: 'user-1',
              role: ChatRole.user,
              content: _userText,
              createdAt: DateTime.utc(2026),
            ),
          if (reply != null) reply!,
        ],
      );

  @override
  Future<ChatReply> sendMessage({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    void Function(BackendEvent event)? onEvent,
    ChatStreamHandle? streamHandle,
    void Function()? onStreamStarted,
  }) {
    prompts.add(prompt);
    onStreamStarted?.call();
    return Completer<ChatReply>().future;
  }
}
