import 'package:flutter/material.dart';

import '../../core/models/agent.dart';
import '../../core/models/llm_provider.dart';
import '../settings/settings_screen.dart';
import 'agent_editor_screen.dart';
import 'agents_controller.dart';

class AgentDrawer extends StatelessWidget {
  const AgentDrawer({required this.agentsController, super.key});

  final AgentsController agentsController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: agentsController,
      builder: (BuildContext context, Widget? _) {
        final List<Agent> agents = agentsController.agents;
        final String? activeId = agentsController.activeAgentId;
        return Column(
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'api-agent',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'serif',
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '你的 agents',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 12,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),
            Expanded(
              child: agents.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '还没有 agent。\n点下方按钮新建一个。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                            height: 1.5,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: agents.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Agent agent = agents[index];
                        final bool isActive = agent.id == activeId;
                        return ListTile(
                          leading: Icon(
                            isActive
                                ? Icons.chat_bubble_rounded
                                : Icons.chat_bubble_outline,
                            color: isActive ? const Color(0xFF557A68) : null,
                          ),
                          title: Text(
                            agent.name,
                            style: TextStyle(
                              fontWeight:
                                  isActive ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          subtitle: Text(
                            '${agent.provider.label} · ${agent.model}',
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            tooltip: '编辑',
                            onPressed: () => _editAgent(context, agent),
                          ),
                          selected: isActive,
                          onTap: () async {
                            await agentsController.setActive(agent.id);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建 agent'),
              onTap: () => _editAgent(context, null),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('API keys'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              onTap: () {
                Navigator.of(context).pop();
                showAboutDialog(
                  context: context,
                  applicationName: 'api-agent',
                  applicationVersion: '0.1.0',
                  children: const <Widget>[
                    SizedBox(height: 8),
                    Text(
                      'A lightweight local BYO-key, BYO-agent chat client. '
                      '从 nian 演化而来；这里没有后端、没有默认人设，'
                      '一切交由用户自由定义。',
                      style: TextStyle(height: 1.5),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Future<void> _editAgent(BuildContext context, Agent? agent) async {
    Navigator.of(context).pop();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AgentEditorScreen(
          agentsController: agentsController,
          agent: agent,
        ),
      ),
    );
  }
}
