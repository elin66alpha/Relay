# Codex worker spec — frontend integrity fixes

You are codex1 on team relay-frontend, in an isolated git worktree branched from
feat/frontend-integrity-pass. Work ONLY under lib/ and test/ — never touch server/,
docs/, android/, web/. Read docs/code_integrity_frontend.md first (exact file:line
locations and rationale for every item below).

Work the clawteam task board in order: Phase 1 task first (mark in_progress, then
completed), then Phase 2. Commit once per phase. After EACH phase run
`flutter analyze --no-pub && flutter test --no-pub` — both must be clean before
marking the task completed.

## PHASE 1 (core plumbing)

### F-1 PBKDF2 off the UI isolate
`lib/core/credentials/credential_file_codec.dart` + callers.
- Top-level function (single arg object/Map with bytes+passphrase) running
  `CredentialFileCodec().decrypt`, invoked via Flutter `compute()`. Follow the QR
  decode pattern at `machine_credentials_screen.dart:164`.
- On kIsWeb call decrypt directly (browser WebCrypto is async/off-thread already);
  native uses compute().
- Wire through `MachineCredentialsController.decryptEncryptedBytes` so all callers
  benefit. Keep MachineCredentialException semantics (the screen matches on
  err.message containing 'decryption failed'). `test/credential_file_codec_test.dart`
  must still pass.

### F-2 SSE idle timeout
`lib/core/backend/backend_client.dart` `streamEvents()` ONLY (not _sendMessageStreamed).
- Server heartbeats every 30s. Apply `.timeout(const Duration(seconds: 90))` to the
  byte stream consumed by `_parseSse`. A TimeoutException must surface as a stream
  error so BotChatController's onError fires and schedules reconnect.

### F-3 streaming delta O(n^2) fix
`lib/features/chat/bot_chat_controller.dart`.
- Per-active-request StringBuffer: `_appendDelta` appends to the buffer; materialize
  `buffer.toString()` into message content only on the (already throttled) notify.
  Seed the buffer from existing content when adopting a message; clear it in
  finalize/cancel/discard paths.
- `_assistantIndexForRequest`: scan from the END of `_messages` (reverse loop).
- Be surgical: do not change reattach/mirror behavior, metadata flags, notify timing.

### F-4 history snapshot decode cost
`backend_client.dart fetchHistory` + `bot_chat_controller.dart _refreshHistorySnapshot`.
- fetchHistory: when `response.body.length > 256*1024` and !kIsWeb, run jsonDecode +
  ChatMessage.fromJson mapping inside compute() (top-level fn String -> List<ChatMessage>).
  Small bodies keep the current path.
- _refreshHistorySnapshot: cheap-compare fetched snapshot vs current `_messages`
  (same length AND last message id + content length + metadata['streaming'] equal) —
  if unchanged skip apply + notifyListeners. The reattach-finalize check must still
  run when the snapshot DID change.

### P-1 in-memory caches for per-request storage reads
`machine_credentials_store.dart`, `device_id_store.dart`, `workdir_store.dart`.
- These stores are instantiated multiple times (BackendClient, CardsService,
  controllers). Use STATIC class-level caches shared across instances, invalidated
  on every write path in the class:
  - DeviceIdStore: cache id after first readOrCreate (immutable afterwards).
  - WorkdirStore: cache read(); update in write()/clear().
  - MachineCredentialsStore: cache decoded List + activeId; invalidate in
    upsert/delete/setActive/_writeAll; readAll/readActive/readActiveId serve from cache.
- Keep constructor injection working; add static resetCacheForTest() if tests need it.

### P-4 progressLinesFor allocation
- `_appendProgress` stores an unmodifiable List<String> in metadata;
  `progressLinesFor` returns it directly (no copy). Public return type unchanged.

### R-2 dedupe loadFor / _reloadConversation
- Extract one private helper with the shared sequence (state reset block,
  ensureActiveSessionId, _fetchHistoryIfCurrent, _applyHistorySnapshot, polling
  start, seq-guarded finally). loadFor keeps its same-context early-return and the
  '_messages.isNotEmpty -> return' rule (that rule exists ONLY in loadFor);
  _reloadConversation keeps _prefetchInactiveSessions afterwards. Behavior identical.

Commit: `fix(frontend): phase 1 - freeze and perf fixes (F-1..F-4, P-1, P-4, R-2)`

## PHASE 2 (UI + reuse)

### F-5 lazy file list
`lib/features/filesystem/file_system_screen.dart`.
- Restructure body to CustomScrollView: header widgets in SliverToBoxAdapter, file
  entries in SliverList.builder (one ListTile per index). Keep the maxWidth-1040
  centered look (Align+ConstrainedBox inside header adapter and per-item builder is
  fine). Visual result must closely match current layout.

### F-6 streaming upload
`file_system_screen.dart` + `backend_client.dart`.
- Native (!kIsWeb): `FilePicker.pickFiles(withReadStream: true, withData: false)`;
  enforce the 100MB cap via PlatformFile.size BEFORE reading; new
  `BackendClient.uploadFileStream({path, name, Stream<List<int>> bytes, int length})`
  using http.StreamedRequest with Content-Length and same headers/timeout/error
  mapping as uploadFile.
- Web stays withData+bytes. Drag-drop (DroppedFile) keeps the bytes API.
  Keep uploadFile(bytes) for those callers.

### P-2 scope streaming rebuilds
`lib/features/chat/bot_chat_screen.dart`.
- Split the single AnimatedBuilder so the 80ms streaming notify rebuilds only the
  conversation area; header/banner/_InputBar get their own narrow
  ListenableBuilders. Do not change widget semantics, keys, or _scroll wiring.

### P-3 card drag without setState
`lib/features/cards/card_deck_screen.dart`.
- Drag offset in ValueNotifier<Offset>; _onPanUpdate only sets value. Top card
  listens via the existing AnimatedBuilder (Listenable.merge(anim, notifier)).
  _onPanEnd reads notifier.value; logic unchanged. Background cards/buttons must
  not rebuild during drag.

### S-1 http:// credential warning
`machine_credentials_screen.dart` + `lib/core/i18n/app_strings.dart`.
- In _finishImport, after decrypt succeeds and BEFORE the health check: if
  credential.baseUrl scheme is http (not https), show a confirm dialog (plaintext
  risk; Continue/Cancel; Cancel aborts). Add strings to AppStrings in BOTH en and zh.

### S-2 shared friendly error util
New `lib/core/util/error_text.dart`.
- Top-level `String friendlyErrorText(AppStrings strings, Object err)` with the
  logic of BotChatController._friendlyError (+ MachineCredentialException -> message).
  Controller delegates to it. Use it for user-visible errors in
  file_system_screen.dart (_loadInitial/_browse/_setAsWorkPath catches) and
  card_deck_screen.dart _load.

### R-1 dedupe CardsService transport
- New `lib/core/backend/api_transport.dart` owning httpClient+stores:
  requestJson(method, path, {body, timeout}), uri(), headers(), exception mapping
  INCLUDING the network-error classifier (CardsService currently lacks it — gaining
  it is a desired behavior change). BackendClient delegates its private transport
  methods to it (public API unchanged, streamed paths read headers/uri from the
  transport); CardsService uses the same class.

### R-3 shared formatters
- New `lib/core/util/format_bytes.dart` with one formatBytes(int) (file_system_screen
  precision style: B/KB/MB/GB one decimal). Replace BackendDiagnostics._formatBytes
  and file_system_screen _formatBytes. Add formatLongTime ('YYYY-MM-DD HH:mm:ss',
  local, current fallback behavior) next to formatShortTime in core/util/time_format.dart
  and use it for _formatModifiedAt.

Commit: `fix(frontend): phase 2 - UI perf, security, reuse (F-5, F-6, P-2, P-3, S-1, S-2, R-1, R-3)`

## RULES
- No new dependencies. No server/ or docs/ changes. Match existing code style.
- flutter analyze --no-pub && flutter test --no-pub clean after each phase.
- When both tasks are done:
  `clawteam inbox send relay-frontend lead "<summary: what changed, analyze/test results>"`
  then `clawteam lifecycle idle relay-frontend`.
