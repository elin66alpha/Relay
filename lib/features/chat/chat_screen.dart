import 'package:flutter/material.dart';

import '../../core/models/chat_message.dart';
import '../agents/agent_editor_screen.dart';
import '../agents/agents_controller.dart';
import '../agents/agents_screen.dart';
import 'chat_controller.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.agentsController,
    required this.chatController,
    super.key,
  });

  final AgentsController agentsController;
  final ChatController chatController;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.chatController.addListener(_scrollToBottomSoon);
    widget.agentsController.addListener(_onAgentChanged);
    _syncAgent();
  }

  @override
  void dispose() {
    widget.chatController.removeListener(_scrollToBottomSoon);
    widget.agentsController.removeListener(_onAgentChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onAgentChanged() {
    _syncAgent();
  }

  void _syncAgent() {
    final active = widget.agentsController.activeAgent;
    if (widget.chatController.agent?.id != active?.id) {
      widget.chatController.loadFor(active);
    }
  }

  Future<void> _send() async {
    final String text = _input.text;
    _input.clear();
    await widget.chatController.sendUserText(text);
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawerScrimColor: Colors.black54,
      drawer: Drawer(
        child: SafeArea(
          child: AgentDrawer(
            agentsController: widget.agentsController,
          ),
        ),
      ),
      appBar: AppBar(
        leading: Builder(
          builder: (BuildContext context) {
            return IconButton(
              icon: const Icon(Icons.menu),
              tooltip: '菜单',
              onPressed: () => Scaffold.of(context).openDrawer(),
            );
          },
        ),
        title: AnimatedBuilder(
          animation: widget.agentsController,
          builder: (BuildContext context, Widget? _) {
            final agent = widget.agentsController.activeAgent;
            return Text(
              agent?.name ?? 'api-agent',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            );
          },
        ),
        actions: <Widget>[
          AnimatedBuilder(
            animation: widget.chatController,
            builder: (BuildContext context, Widget? _) {
              if (widget.chatController.agent == null) {
                return const SizedBox.shrink();
              }
              return IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '清空当前对话',
                onPressed: widget.chatController.isThinking
                    ? null
                    : _confirmClearHistory,
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            widget.agentsController,
            widget.chatController,
          ]),
          builder: (BuildContext context, Widget? _) {
            final agent = widget.agentsController.activeAgent;
            if (agent == null) {
              return _EmptyAgentsPlaceholder(
                agentsController: widget.agentsController,
              );
            }
            return Column(
              children: <Widget>[
                Expanded(
                  child: widget.chatController.messages.isEmpty
                      ? _EmptyChatPlaceholder(agentName: agent.name)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                          itemCount: widget.chatController.messages.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ChatMessage message =
                                widget.chatController.messages[index];
                            return _MessageBubble(
                              message: message,
                              retryable:
                                  widget.chatController.isRetryable(message),
                              awaitingFirstToken: widget.chatController
                                  .isAwaitingFirstToken(message),
                              errorDetail:
                                  widget.chatController.errorDetailFor(message),
                              onRetry: () =>
                                  widget.chatController.retry(message),
                            );
                          },
                        ),
                ),
                _InputBar(
                  controller: _input,
                  enabled: !widget.chatController.isThinking,
                  onSend: _send,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmClearHistory() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('清空当前对话？'),
        content: const Text('此操作会删除该 agent 的全部历史消息，无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.chatController.clearHistory();
    }
  }
}

class _EmptyAgentsPlaceholder extends StatelessWidget {
  const _EmptyAgentsPlaceholder({required this.agentsController});

  final AgentsController agentsController;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '还没有 agent',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              '先创建一个 agent —— 给它取名字、写 system prompt、选模型，\n'
              '或者粘贴一段 .md 直接导入。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('新建 agent'),
              onPressed: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => AgentEditorScreen(
                      agentsController: agentsController,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChatPlaceholder extends StatelessWidget {
  const _EmptyChatPlaceholder({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          '与 $agentName 开始对话',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFFF8F7F3),
        border: Border(top: BorderSide(color: Color(0xFFE8E4DC))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: '说点什么…',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.arrow_upward_rounded),
              tooltip: '发送',
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.retryable,
    required this.awaitingFirstToken,
    required this.errorDetail,
    required this.onRetry,
  });

  final ChatMessage message;
  final bool retryable;
  final bool awaitingFirstToken;
  final String? errorDetail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.isUser;
    final Color bubbleColor = isUser ? const Color(0xFF29483B) : Colors.white;
    final Color textColor = isUser ? Colors.white : const Color(0xFF22251F);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(14),
              border:
                  isUser ? null : Border.all(color: const Color(0xFFE2DED5)),
            ),
            child: awaitingFirstToken && message.content.isEmpty
                ? _TypingDots(color: textColor)
                : SelectableText(
                    message.content,
                    style: TextStyle(
                      color: textColor,
                      height: 1.45,
                      fontSize: 15,
                    ),
                  ),
          ),
          if (retryable) ...<Widget>[
            if (errorDetail != null && errorDetail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  errorDetail!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 1, bottom: 4),
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重试'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});
  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _opacity(double t, int i) {
    final double offset = i * 0.18;
    final double phase = (t - offset) % 1.0;
    final double wrapped = phase < 0 ? phase + 1.0 : phase;
    if (wrapped < 0.5) return 0.35 + 0.65 * (wrapped * 2);
    return 0.35 + 0.65 * ((1.0 - wrapped) * 2);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (BuildContext context, Widget? _) {
          final double t = _ctrl.value;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List<Widget>.generate(3, (int i) {
              return Padding(
                padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                child: Opacity(
                  opacity: _opacity(t, i),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
