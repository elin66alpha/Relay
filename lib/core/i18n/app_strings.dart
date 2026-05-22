import 'package:flutter/widgets.dart';

import '../settings/app_settings_controller.dart';

class AppScope extends InheritedNotifier<AppSettingsController> {
  const AppScope({
    required AppSettingsController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppSettingsController settingsOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  }

  static AppStrings stringsOf(BuildContext context) {
    return AppStrings(settingsOf(context).language);
  }
}

extension AppStringsContext on BuildContext {
  AppStrings get l10n => AppScope.stringsOf(this);
  AppSettingsController get appSettings => AppScope.settingsOf(this);
}

class AppStrings {
  const AppStrings(this.appLanguage);

  final AppLanguage appLanguage;
  bool get isZh => appLanguage == AppLanguage.zh;

  String get appName => isZh ? '智能体工作台' : 'AgentDeck';
  String get notConnected => isZh ? '未连接机器' : 'No machine connected';
  String get machines => isZh ? '机器' : 'Machines';
  String get manageCredentials => isZh ? '管理凭证' : 'Manage credentials';
  String get cliAgents => isZh ? 'CLI 智能体' : 'CLI agents';
  String get usage => isZh ? '额度' : 'Usage';
  String get usageTitle => isZh ? '额度剩余' : 'Quota remaining';
  String get loadingUsage => isZh ? '正在查询额度...' : 'Loading quota...';
  String get fiveHourQuota => isZh ? '5 小时' : '5 hours';
  String get weeklyQuota => isZh ? '本周' : 'This week';
  String get remaining => isZh ? '剩余' : 'remaining';
  String get refreshAt => isZh ? '刷新' : 'Refresh';
  String get unavailable => isZh ? '暂未开放' : 'Not available yet';
  String get unknown => isZh ? '未知' : 'Unknown';
  String get status => isZh ? '状态' : 'Status';
  String get backendOnline => isZh ? '后端在线' : 'Backend online';
  String workDirectoryLine(String path) =>
      isZh ? '工作目录：$path' : 'Work directory: $path';
  String systemUptimeLine(String value) =>
      isZh ? '系统运行：$value' : 'System uptime: $value';
  String processUptimeLine(String value) =>
      isZh ? '进程运行：$value' : 'Process uptime: $value';
  String publicBaseUrlLine(String value) =>
      isZh ? '公网地址：$value' : 'Public URL: $value';
  String taskTimeoutLine(int minutes) =>
      isZh ? '任务超时：$minutes 分钟' : 'Task timeout: $minutes minutes';
  String quotaWatchLine(bool enabled) => isZh
      ? '额度监听：${enabled ? '开启' : '关闭'}'
      : 'Quota watch: ${enabled ? 'enabled' : 'disabled'}';
  String get resetWorkdir => isZh ? '清空工作目录' : 'Reset workdir';
  String get workDirectory => isZh ? '工作路径' : 'Work directory';
  String get loadingWorkDirectory =>
      isZh ? '正在读取工作路径...' : 'Loading work directory...';
  String get workDirectoryHint =>
      isZh ? '输入后端机器上的绝对路径' : 'Enter an absolute path on the backend machine';
  String get save => isZh ? '保存' : 'Save';
  String get create => isZh ? '创建' : 'Create';
  String get pathMissingTitle => isZh ? '创建工作路径？' : 'Create work directory?';
  String pathMissingBody(String path) => isZh
      ? '后端机器上不存在：\n$path\n\n要创建这个目录并切换过去吗？'
      : 'This directory does not exist on the backend machine:\n$path\n\nCreate it and switch to it?';
  String get workdirUpdated => isZh ? '工作路径已更新。' : 'Work directory updated.';
  String get workdirMustBeAbsolute =>
      isZh ? '请输入绝对路径。' : 'Enter an absolute path.';
  String get workdirBusy => isZh
      ? '当前有 agent 正在运行，请结束后再修改工作路径。'
      : 'An agent task is running. Change the work directory after it finishes.';
  String localChatSessionResetFailed(Object err) => isZh
      ? '已清空本地对话，但重置机器会话失败：$err'
      : 'Local chat was cleared, but resetting the machine session failed: $err';
  String workdirResetSuccess(int count, String dir) => isZh
      ? '已清空工作目录（删除 $count 项）：$dir'
      : 'Work directory cleared ($count item(s) removed): $dir';
  String workdirResetFailed(Object err) =>
      isZh ? '清空工作目录失败：$err' : 'Failed to reset work directory: $err';
  String get agentBusyRetryLater => isZh
      ? '该 agent 正在处理上一条消息，请稍后重试。'
      : 'This agent is still handling the previous message. Try again later.';
  String agentErrorLine(String error) => isZh ? '出错：$error' : 'Error: $error';
  String get importCredential => isZh ? '导入凭证' : 'Import credential';
  String get scanQr => isZh ? '扫描二维码' : 'Scan QR code';
  String get menu => isZh ? '菜单' : 'Menu';
  String get clearChat => isZh ? '清空当前对话' : 'Clear chat';
  String get close => isZh ? '关闭' : 'Close';
  String get cancel => isZh ? '取消' : 'Cancel';
  String get clear => isZh ? '清空' : 'Clear';
  String get delete => isZh ? '删除' : 'Delete';
  String get stop => isZh ? '停止' : 'Stop';
  String get send => isZh ? '发送' : 'Send';
  String get retry => isZh ? '重试' : 'Retry';
  String get cancelled => isZh ? '已取消' : 'Cancelled';
  String get inputHint => isZh ? '输入消息' : 'Message';
  String startChat(String agent) =>
      isZh ? '与 $agent 开始对话' : 'Start chatting with $agent';
  String get credentialTitle => isZh ? '机器凭证' : 'Machine credentials';
  String get currentMachine => isZh ? '当前机器' : 'Current machine';
  String get testMachine => isZh ? '测试当前机器' : 'Test current machine';
  String get importOrChooseMachine =>
      isZh ? '请导入或选择一台机器' : 'Import or choose a machine';
  String get loadingStatus => isZh ? '正在获取状态...' : 'Loading status...';
  String statusLoadFailed(Object err) =>
      isZh ? '连接失败：$err' : 'Connection failed: $err';
  String get noStatus => isZh ? '未获取到状态' : 'No status received';
  String get refresh => isZh ? '刷新' : 'Refresh';
  String get chooseCredential => isZh ? '选择凭证' : 'Choose credential';
  String get importMachineCredential =>
      isZh ? '导入机器凭证' : 'Import machine credential';
  String get emptyCredentialText => isZh
      ? '扫描机器上脚本生成的凭证二维码，然后输入凭证密码。'
      : 'Scan the credential QR code generated by the script on the machine, then enter the credential password.';
  String get credentialPassword => isZh ? '凭证密码' : 'Credential password';
  String get password => isZh ? '密码' : 'Password';
  String get passwordHint =>
      isZh ? '生成凭证时设置的密码' : 'Password set when generating the credential';
  String get decrypt => isZh ? '解密' : 'Decrypt';
  String get settings => isZh ? '设置' : 'Settings';
  String get about => isZh ? '关于' : 'About';
  String get aboutApp => isZh ? '关于应用' : 'About this app';
  String get version => isZh ? '版本' : 'Version';
  String get license => isZh ? '许可' : 'License';
  String get licenseText => isZh ? '私有本地工具。' : 'Private local tool.';
  String get copyright => isZh ? '© 2026 AgentDeck' : '© 2026 AgentDeck';
  String get aboutDescription => isZh
      ? '用于连接本机 Claude Code、Codex 与 Antigravity CLI 智能体的私有控制台。'
      : 'Private control surface for local Claude Code, Codex, and Antigravity CLI agents.';
  String get language => isZh ? '语言' : 'Language';
  String get appearance => isZh ? '外观' : 'Appearance';
  String get speechInput => isZh ? '语音输入' : 'Voice input';
  String get speechLanguage => isZh ? '语音语言' : 'Speech language';
  String get autoDetect => isZh ? '自动' : 'Auto';
  String get chineseSpeech => isZh ? '中文' : 'Chinese';
  String get englishSpeech => isZh ? '英文' : 'English';
  String get startRecording => isZh ? '开始录音' : 'Start recording';
  String get stopRecording => isZh ? '停止录音' : 'Stop recording';
  String get transcribing => isZh ? '正在转文字' : 'Transcribing';
  String transcriptionFailed(Object err) =>
      isZh ? '语音识别失败：$err' : 'Speech transcription failed: $err';
  String get microphonePermissionDenied =>
      isZh ? '没有麦克风权限。' : 'Microphone permission was denied.';
  String get online => isZh ? '在线' : 'Online';
  String get offline => isZh ? '未在线' : 'Not online';
  String get compress => isZh ? '压缩对话' : 'Compress';
  String get english => 'English';
  String get chinese => '中文';
  String get systemTheme => isZh ? '跟随系统' : 'System';
  String get lightTheme => isZh ? '白天' : 'Light';
  String get darkTheme => isZh ? '黑夜' : 'Dark';
  String get selectBotcred =>
      isZh ? '请选择有效的 AgentDeck 凭证。' : 'Choose a valid AgentDeck credential.';
  String get fileUnreadable =>
      isZh ? '无法读取凭证。' : 'Unable to read the credential.';
  String imported(String name) => isZh ? '已导入：$name' : 'Imported: $name';
  String importFailed(Object err) => isZh ? '导入失败：$err' : 'Import failed: $err';
  String get connectionOk => isZh ? '连接正常。' : 'Connection OK.';
  String get backendNotOk => isZh ? '后端没有返回 ok。' : 'Backend did not return ok.';
  String connectionFailed(Object err) =>
      isZh ? '连接失败：$err' : 'Connection failed: $err';
  String deleteMachine(String name) => isZh ? '删除 $name？' : 'Delete $name?';
  String get deleteMachineBody => isZh
      ? '删除后需要重新扫描这台机器的凭证二维码。'
      : 'You will need to scan this machine credential QR again.';
  String get scanQrTitle => isZh ? '扫描凭证二维码' : 'Scan credential QR';
  String get scanQrHint =>
      isZh ? '对准终端或图片里的凭证二维码。' : 'Point the camera at the credential QR code.';
  String get invalidQr => isZh
      ? '二维码不是有效的 AgentDeck 凭证。'
      : 'The QR code is not a valid AgentDeck credential.';
  String get clearChatTitle => isZh ? '清空当前对话？' : 'Clear this chat?';
  String get clearChatBody => isZh
      ? '删除本地历史消息，并在机器上为当前 agent 开启新会话（不影响工作目录里的文件）。'
      : 'Delete local history and start a new machine-side session for this agent. Files in the workdir are not changed.';
  String get resetWorkdirTitle => isZh ? '清空工作目录？' : 'Reset workdir?';
  String get resetWorkdirBody => isZh
      ? '机器端配置的工作目录内文件会被删除。'
      : 'Files under the configured machine workdir will be deleted.';
}
