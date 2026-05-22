import 'package:flutter/material.dart';

import 'app.dart';
import 'core/settings/app_settings_controller.dart';
import 'features/chat/bot_chat_controller.dart';
import 'features/cli_agents/cli_agents_controller.dart';
import 'features/machines/machine_credentials_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppSettingsController settingsController = AppSettingsController();
  await settingsController.load();
  final CliAgentsController agentsController = CliAgentsController();
  final BotChatController chatController = BotChatController();
  final MachineCredentialsController machinesController =
      MachineCredentialsController();

  runApp(
    BotApp(
      agentsController: agentsController,
      chatController: chatController,
      machinesController: machinesController,
      settingsController: settingsController,
    ),
  );
}
