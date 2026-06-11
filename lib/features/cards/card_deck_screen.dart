import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/models/card_model.dart';
import '../../core/models/cli_agent.dart';
import '../../core/util/error_text.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../chat/bot_chat_controller.dart';
import '../machines/machine_credentials_controller.dart';
import 'card_widget.dart';
import 'cards_service.dart';

/// Card Mode: a secondary interaction surface that shows AI-suggested actions
/// derived from chat history. Cards are acted on with four-directional swipes.
/// Chat remains the primary mode; executing a card reuses the existing chat
/// send path.
class CardDeckScreen extends StatefulWidget {
  const CardDeckScreen({
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
    this.cardsService,
    super.key,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;
  final CardsService? cardsService;

  @override
  State<CardDeckScreen> createState() => _CardDeckScreenState();
}

class _CardDeckScreenState extends State<CardDeckScreen>
    with SingleTickerProviderStateMixin {
  static const double _threshold = 60;

  late final CardsService _service;
  late final AnimationController _anim;
  Animation<Offset>? _slide;
  bool _pendingRemove = false;

  final List<CardModel> _cards = <CardModel>[];
  final ValueNotifier<Offset> _drag = ValueNotifier<Offset>(Offset.zero);
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.cardsService ?? CardsService();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addStatusListener((AnimationStatus status) {
        if (status != AnimationStatus.completed) return;
        setState(() {
          if (_pendingRemove && _cards.isNotEmpty) _cards.removeAt(0);
          _pendingRemove = false;
          _slide = null;
          _drag.value = Offset.zero;
        });
        _anim.reset();
      });
    _load();
  }

  @override
  void dispose() {
    _drag.dispose();
    _anim.dispose();
    if (widget.cardsService == null) _service.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<CardModel> cards = await _service.getCards();
      if (!mounted) return;
      setState(() {
        _cards
          ..clear()
          ..addAll(cards);
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(context.l10n, err);
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await _service.refresh();
    } catch (_) {
      // Reloading below will surface a connection error if there is one.
    }
    await _load();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_anim.isAnimating) return;
    _drag.value += details.delta;
  }

  void _onPanEnd(DragEndDetails details) {
    if (_anim.isAnimating || _cards.isEmpty) return;
    final Offset drag = _drag.value;
    final bool horizontal = drag.dx.abs() >= drag.dy.abs();
    final double distance = horizontal ? drag.dx.abs() : drag.dy.abs();
    if (distance < _threshold) {
      _flyTo(Offset.zero, removeTopCard: false);
      return;
    }
    final CardModel card = _cards.first;
    if (horizontal && drag.dx > 0) {
      unawaited(_execute(card));
    } else if (horizontal && drag.dx < 0) {
      _dismiss(card, 'reject', const Offset(-700, 0));
    } else if (!horizontal && drag.dy < 0) {
      unawaited(_defer(card));
    } else {
      _dismiss(card, 'irrelevant', const Offset(0, 700));
    }
  }

  void _executeTopCard() {
    if (_anim.isAnimating || _cards.isEmpty) return;
    unawaited(_execute(_cards.first));
  }

  void _rejectTopCard() {
    if (_anim.isAnimating || _cards.isEmpty) return;
    _dismiss(_cards.first, 'reject', const Offset(-700, 0));
  }

  void _deferTopCard() {
    if (_anim.isAnimating || _cards.isEmpty) return;
    unawaited(_defer(_cards.first));
  }

  void _markTopCardIrrelevant() {
    if (_anim.isAnimating || _cards.isEmpty) return;
    _dismiss(_cards.first, 'irrelevant', const Offset(0, 700));
  }

  void _flyTo(Offset target, {required bool removeTopCard}) {
    _pendingRemove = removeTopCard;
    _slide = Tween<Offset>(begin: _drag.value, end: target).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOut),
    );
    _anim.forward(from: 0);
  }

  // Reject / Irrelevant: record feedback (best-effort) and fly the card off.
  void _dismiss(CardModel card, String gesture, Offset target) {
    unawaited(_service.sendFeedback(card.id, gesture).catchError((_) {}));
    final Offset drag = _drag.value;
    _flyTo(target.translate(drag.dx, drag.dy), removeTopCard: true);
  }

  // Execute (right): reuse the existing chat send path on the card's agent.
  Future<void> _execute(CardModel card) async {
    unawaited(_service.sendFeedback(card.id, 'execute').catchError((_) {}));
    final machine = widget.machinesController.activeMachine;
    if (machine == null) {
      _flyTo(Offset.zero, removeTopCard: false);
      _showSnack('Connect a machine first.');
      return;
    }
    if (widget.agentsController.activeAgentKey != card.agentKey) {
      await widget.agentsController.setActive(card.agentKey);
    }
    final CliAgent agent = cliAgentByKey(card.agentKey);
    await widget.chatController.loadFor(agent, machine);
    if (card.sessionId.isNotEmpty) {
      await widget.chatController.selectSession(agent, card.sessionId);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    unawaited(widget.chatController.sendUserText(card.prompt));
  }

  // Defer (up): settle the card, ask for a delay, then fly off upward.
  Future<void> _defer(CardModel card) async {
    _flyTo(Offset.zero, removeTopCard: false);
    final DateTime? deferUntil = await _pickDeferTime();
    if (deferUntil == null || !mounted) return;
    unawaited(
      _service
          .sendFeedback(card.id, 'defer', deferUntil: deferUntil)
          .catchError((_) {}),
    );
    if (_cards.isNotEmpty && _cards.first.id == card.id && !_anim.isAnimating) {
      _flyTo(const Offset(0, -700), removeTopCard: true);
    }
  }

  Future<DateTime?> _pickDeferTime() {
    final DateTime now = DateTime.now();
    return showModalBottomSheet<DateTime>(
      context: context,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('In 30 minutes'),
                onTap: () => Navigator.of(sheetContext)
                    .pop(now.add(const Duration(minutes: 30))),
              ),
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('In 2 hours'),
                onTap: () => Navigator.of(sheetContext)
                    .pop(now.add(const Duration(hours: 2))),
              ),
              ListTile(
                leading: const Icon(Icons.wb_sunny_outlined),
                title: const Text('Tomorrow morning (9 AM)'),
                onTap: () => Navigator.of(sheetContext).pop(
                  DateTime(now.year, now.month, now.day, 9)
                      .add(const Duration(days: 1)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Card Mode'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _load);
    }
    if (_cards.isEmpty) {
      return _EmptyState(onRefresh: _refresh);
    }

    final Size size = MediaQuery.sizeOf(context);
    final double cardW = math.min(360, size.width - 48);
    final double cardH = math.min(480, size.height * 0.62);
    final List<CardModel> visible = _cards.take(3).toList();

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: cardW,
            height: cardH + 32,
            child: Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                for (int i = visible.length - 1; i >= 0; i--)
                  _buildStackedCard(i, visible[i], cardW, cardH),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _executeTopCard,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Execute'),
                ),
                OutlinedButton.icon(
                  onPressed: _rejectTopCard,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Reject'),
                ),
                OutlinedButton.icon(
                  onPressed: _deferTopCard,
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('Defer'),
                ),
                OutlinedButton.icon(
                  onPressed: _markTopCardIrrelevant,
                  icon: const Icon(Icons.remove_rounded),
                  label: const Text('Irrelevant'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStackedCard(int index, CardModel card, double w, double h) {
    // Background cards (index 1, 2) sit lower and slightly scaled to create a
    // deck perspective; the top card (0) is the interactive one.
    if (index > 0) {
      final double scale = index == 1 ? 0.97 : 0.94;
      return Positioned(
        top: index * 8.0,
        child: Transform.scale(
          scale: scale,
          child: SizedBox(width: w, height: h, child: CardWidget(card: card)),
        ),
      );
    }

    return Positioned(
      top: 0,
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_anim, _drag]),
        child: CardWidget(card: card),
        builder: (BuildContext context, Widget? child) {
          final Offset drag = _slide?.value ?? _drag.value;
          final bool horizontal = drag.dx.abs() >= drag.dy.abs();
          final double distance = horizontal ? drag.dx.abs() : drag.dy.abs();
          final double overlayOpacity = (distance / _threshold).clamp(0.0, 1.0);
          final (Color color, IconData icon, String label) = horizontal
              ? (drag.dx > 0
                  ? (const Color(0xFF10B981), Icons.check_rounded, 'Execute')
                  : (const Color(0xFFEF4444), Icons.close_rounded, 'Reject'))
              : (drag.dy < 0
                  ? (const Color(0xFFF59E0B), Icons.pause_rounded, 'Defer')
                  : (Colors.grey, Icons.remove_rounded, 'Irrelevant'));

          return Transform.translate(
            offset: drag,
            child: Transform.rotate(
              angle: (drag.dx / 900).clamp(-0.35, 0.35),
              child: GestureDetector(
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Stack(
                    children: <Widget>[
                      child!,
                      if (overlayOpacity > 0)
                        Positioned.fill(
                          child: Opacity(
                            opacity: overlayOpacity,
                            child: Container(
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: <Widget>[
                                  Icon(icon, color: Colors.white, size: 64),
                                  const SizedBox(height: 8),
                                  Text(
                                    label,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.style_outlined, size: 64, color: colors.outline),
          const SizedBox(height: 16),
          const Text(
            'No suggestions yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Keep chatting and cards will appear here',
            style: TextStyle(color: colors.outline),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: () => onRefresh(),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Generate new cards'),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 48, color: colors.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
