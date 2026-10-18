import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/backend/backend_client.dart';
import 'core/notifications/notification_service.dart';
import 'core/settings/app_settings_controller.dart';
import 'features/chat/bot_chat_controller.dart';
import 'features/cli_agents/cli_agents_controller.dart';
import 'features/machines/machine_credentials_controller.dart';
import 'features/quota/quota_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // System notifications carry quota alerts to the OS tray instead of the chat.
  await NotificationService.instance.init();
  unawaited(NotificationService.instance.requestPermission());

  final AppSettingsController settingsController = AppSettingsController();
  await settingsController.load();
  final CliAgentsController agentsController = CliAgentsController();
  final BackendClient backendClient = BackendClient();
  final QuotaController quotaController = QuotaController(
    backendClient: backendClient,
  );
  final BotChatController chatController = BotChatController(
    backendClient: backendClient,
    quotaController: quotaController,
  );
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
