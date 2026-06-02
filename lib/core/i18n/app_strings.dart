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

  String get appName => 'AgentDeck';
  String get notConnected => isZh ? '未连接机器' : 'No machine connected';
  String get manageCredentials => isZh ? '管理凭证' : 'Manage credentials';
  String get cliAgents => isZh ? 'CLI 智能体' : 'CLI agents';
  String get cardMode => isZh ? '卡片模式' : 'Card Mode';
  String get cardModeSubtitle =>
      isZh ? '基于对话历史的行动建议' : 'Suggested actions from your chats';
  String get usage => isZh ? '额度' : 'Usage';
  String get usageTitle => isZh ? '额度剩余' : 'Quota remaining';
  String get loadingUsage => isZh ? '正在查询额度...' : 'Loading quota...';
  String get fiveHourQuota => isZh ? '5 小时' : '5 hours';
  String get weeklyQuota => isZh ? '本周' : 'This week';
  String get remaining => isZh ? '剩余' : 'remaining';
  String get refreshAt => isZh ? '刷新' : 'Refresh';
  String usageAsOf(String value) => isZh ? '截至 $value' : 'As of $value';
  String get usageStale => isZh ? '上次成功结果' : 'Stale';
  String get quotaScheduler => isZh ? '定时消息' : 'Scheduled messages';
  String get prompt => isZh ? '消息内容' : 'Message';
  String scheduleUpdated(String agent) =>
      isZh ? '已更新 $agent 的预设消息。' : 'Updated scheduled message for $agent.';
  String scheduleFailed(Object err) =>
      isZh ? '预设消息失败：$err' : 'Scheduled message failed: $err';
  String get messageRequired => isZh ? '请输入消息内容。' : 'Enter a message.';
  String get clearSchedule => isZh ? '清除已排程' : 'Clear scheduled';
  String scheduleCleared(String agent) =>
      isZh ? '已清除 $agent 的预设消息。' : 'Cleared scheduled message for $agent.';

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
  String diagnosticsGeneratedLine(String value) =>
      isZh ? '诊断时间：$value' : 'Diagnostics time: $value';
  String diagnosticsRuntimeLine(String platform, String arch, String node) =>
      isZh ? '运行环境：$platform/$arch，$node' : 'Runtime: $platform/$arch, $node';
  String diagnosticsListenLine(String host, int port) =>
      isZh ? '监听地址：$host:$port' : 'Listening on: $host:$port';
  String diagnosticsWorkdirLine({
    required bool exists,
    required bool writable,
  }) =>
      isZh
          ? '工作目录状态：${exists ? '存在' : '不存在'}，${writable ? '可写' : '不可写'}'
          : 'Workdir state: ${exists ? 'exists' : 'missing'}, ${writable ? 'writable' : 'not writable'}';
  String diagnosticsDefaultWorkdirLine(String value) =>
      isZh ? '默认工作目录：$value' : 'Default workdir: $value';
  String diagnosticsTransferLimitLine(String upload, String download) => isZh
      ? '传输上限：上传 $upload，下载 $download'
      : 'Transfer limits: upload $upload, download $download';
  String diagnosticsTokenLine({
    required bool configured,
    required int active,
    required int total,
  }) =>
      isZh
          ? 'Token：${configured ? '已配置' : '未配置'}，活跃 $active / 总计 $total'
          : 'Tokens: ${configured ? 'configured' : 'not configured'}, active $active / total $total';
  String diagnosticsRequestLine({
    required int active,
    required int running,
    required int queued,
    required int sse,
  }) =>
      isZh
          ? '运行中：请求 $active，scope $running，队列 $queued，SSE $sse'
          : 'Runtime: requests $active, scopes $running, queued $queued, SSE $sse';
  String diagnosticsWebBuildLine(bool exists) => isZh
      ? 'Web 构建：${exists ? '存在' : '缺失'}'
      : 'Web build: ${exists ? 'present' : 'missing'}';
  String get diagnosticsAgentsHeader => isZh ? 'CLI 检查：' : 'CLI checks:';
  String diagnosticsAgentLine(
    String label, {
    required bool available,
    required bool? loggedIn,
    required String path,
  }) {
    final String login = loggedIn == null
        ? (isZh ? '登录未知' : 'login unknown')
        : (loggedIn
            ? (isZh ? '已登录' : 'logged in')
            : (isZh ? '未登录' : 'not logged in'));
    final String cli =
        available ? (isZh ? '可执行' : 'available') : (isZh ? '未找到' : 'not found');
    final String suffix = path.isEmpty ? '' : ' ($path)';
    return '- $label: $cli, $login$suffix';
  }

  String get diagnosticsStorageHeader => isZh ? '存储文件：' : 'Storage files:';
  String diagnosticsStorageLine(
    String name, {
    required bool exists,
    required bool writable,
    required String size,
  }) =>
      isZh
          ? '- $name：${exists ? '存在' : '不存在'}，${writable ? '可写' : '不可写'}，$size'
          : '- $name: ${exists ? 'exists' : 'missing'}, ${writable ? 'writable' : 'not writable'}, $size';
  String get deviceTokens => isZh ? '设备 Token' : 'Device tokens';
  String get noDeviceTokens => isZh ? '没有设备 Token。' : 'No device tokens.';
  String get currentDeviceToken => isZh ? '当前设备' : 'Current device';
  String get revokedDeviceToken => isZh ? '已吊销' : 'Revoked';
  String tokenCreatedAt(String value) => isZh ? '创建：$value' : 'Created: $value';
  String tokenRevokedAt(String value) => isZh ? '吊销：$value' : 'Revoked: $value';
  String get revokeToken => isZh ? '吊销' : 'Revoke';
  String get revokeCurrentTokenTitle =>
      isZh ? '吊销当前设备 Token？' : 'Revoke this device token?';
  String get revokeCurrentTokenBody => isZh
      ? '这会让本设备的下一次 API 请求返回 401。继续后需要重新导入有效凭证。'
      : 'The next API request from this device will return 401. You will need to import a valid credential again.';
  String tokenRevoked(String label) => isZh ? '已吊销 $label。' : 'Revoked $label.';
  String tokenRevokeFailed(Object err) =>
      isZh ? '吊销 Token 失败：$err' : 'Token revoke failed: $err';
  String get fileSystem => isZh ? '文件系统' : 'File system';
  String get currentFolder => isZh ? '当前文件夹' : 'Current folder';
  String get parentFolder => isZh ? '上一级' : 'Parent folder';
  String get showHiddenFiles => isZh ? '显示隐藏文件' : 'Show hidden files';
  String get hideHiddenFiles => isZh ? '不显示隐藏文件' : 'Hide hidden files';
  String get emptyFolder => isZh ? '这个文件夹是空的。' : 'This folder is empty.';
  String get loadingFiles => isZh ? '正在读取文件...' : 'Loading files...';
  String get uploadFile => isZh ? '上传文件' : 'Upload file';
  String get download => isZh ? '下载' : 'Download';
  String get dragDropUpload => isZh
      ? 'Web 端可以把文件拖到此页上传。'
      : 'On web, drag files onto this page to upload.';
  String uploadingFile(String name) => isZh ? '正在上传：$name' : 'Uploading: $name';
  String uploadComplete(int count) =>
      isZh ? '已上传 $count 个文件。' : '$count file(s) uploaded.';
  String uploadFailed(Object err) => isZh ? '上传失败：$err' : 'Upload failed: $err';
  String downloadFailed(Object err) =>
      isZh ? '下载失败：$err' : 'Download failed: $err';
  String downloadProgress(String name, int percent) =>
      isZh ? '正在下载 $name（$percent%）' : 'Downloading $name ($percent%)';
  String downloadIndeterminate(String name) =>
      isZh ? '正在下载 $name…' : 'Downloading $name…';
  String get downloadComplete => isZh ? '下载完成' : 'Download complete';
  String get downloadFailedTitle => isZh ? '下载失败' : 'Download failed';
  String savedTo(String location) =>
      isZh ? '已保存到：$location' : 'Saved to: $location';
  String get savedToBrowserDownloads =>
      isZh ? '已下载到浏览器的下载文件夹。' : 'Saved to your browser’s downloads folder.';
  String downloadTooLarge(String limit) => isZh
      ? '文件超过下载上限（$limit），无法下载。'
      : 'This download exceeds the size limit ($limit) and was blocked.';
  String uploadTooLarge(String name, String limit) => isZh
      ? '$name 超过上传上限（$limit），未上传。'
      : '$name exceeds the upload limit ($limit) and was not uploaded.';
  String get setAsWorkPath => isZh ? '设为工作路径' : 'Set as work path';
  String currentWorkPath(String path) =>
      isZh ? '当前工作路径：$path' : 'Work path: $path';
  String get workPathTag => isZh ? '工作路径' : 'Work path';
  String get transferLimitHint => isZh
      ? '单次下载（含打包文件夹）上限 300 MB，单个上传文件上限 100 MB。'
      : 'Downloads (incl. zipped folders) cap at 300 MB; each uploaded file at 100 MB.';
  String get fileTypeDirectory => isZh ? '文件夹' : 'Folder';
  String get fileTypeFile => isZh ? '文件' : 'File';
  String get fileTypeOther => isZh ? '其他' : 'Other';
  String get workdirUpdated => isZh ? '工作路径已更新。' : 'Work directory updated.';
  String get workdirBusy => isZh
      ? '当前有 agent 正在运行，请结束后再修改工作路径。'
      : 'An agent task is running. Change the work directory after it finishes.';
  String localChatSessionResetFailed(Object err) => isZh
      ? '已清空本地对话，但重置机器会话失败：$err'
      : 'Local chat was cleared, but resetting the machine session failed: $err';
  String get agentBusyRetryLater => isZh
      ? '该 agent 正在处理上一条消息，请稍后重试。'
      : 'This agent is still handling the previous message. Try again later.';
  String get agentQueued => isZh
      ? '排队中…（前一条消息还在处理）'
      : 'Queued — waiting for the current turn to finish…';
  String agentErrorLine(String error) => isZh ? '出错：$error' : 'Error: $error';
  String agentNotLoggedIn(String agent) => isZh
      ? '$agent 在后端主机上未登录，请在主机上登录后重试。'
      : '$agent is not logged in on the backend host. Log in there, then try again.';
  String agentNotLoggedInBanner(String agent) => isZh
      ? '$agent 未登录：请在后端主机上登录该 CLI。'
      : '$agent is not logged in. Log in to this CLI on the backend host.';
  String get recheck => isZh ? '重新检查' : 'Recheck';
  String get importCredential => isZh ? '导入凭证' : 'Import credential';
  String get scanQr => isZh ? '扫描二维码' : 'Scan QR code';
  String get pasteCredential => isZh ? '粘贴凭证' : 'Paste credential';
  String get uploadQrImage => isZh ? '上传二维码图片' : 'Upload QR image';
  String get credentialPayload => isZh ? '凭证内容' : 'Credential payload';
  String get credentialPayloadHint => isZh
      ? '粘贴终端生成的二维码内容或加密凭证 JSON'
      : 'Paste the QR payload or encrypted credential JSON generated on the machine';
  String get menu => isZh ? '菜单' : 'Menu';
  String get clearChat => isZh ? '清空当前对话' : 'Clear chat';
  String get searchChats => isZh ? '搜索对话' : 'Search chats';
  String get searchHint =>
      isZh ? '搜索当前工作目录的历史消息' : 'Search history in this workdir';
  String get currentAgentOnly => isZh ? '只搜索当前智能体' : 'Current agent only';
  String get noSearchResults => isZh ? '没有匹配结果。' : 'No matches.';
  String searchFailed(Object err) => isZh ? '搜索失败：$err' : 'Search failed: $err';
  String get exportMarkdown => isZh ? '导出 Markdown' : 'Export Markdown';
  String exportFailed(Object err) => isZh ? '导出失败：$err' : 'Export failed: $err';
  String get close => isZh ? '关闭' : 'Close';
  String get ok => isZh ? '确认' : 'OK';
  String get cancel => isZh ? '取消' : 'Cancel';
  String get clear => isZh ? '清空' : 'Clear';
  String get create => isZh ? '创建' : 'Create';
  String get delete => isZh ? '删除' : 'Delete';
  String get newSession => isZh ? '新建会话' : 'New session';
  String get sessionName => isZh ? '会话名称' : 'Session name';
  String defaultSessionName(int index) => isZh ? '会话 $index' : 'Session $index';
  String get deleteSession => isZh ? '删除会话' : 'Delete session';
  String deleteSessionTitle(String name) =>
      isZh ? '删除 $name？' : 'Delete $name?';
  String get deleteSessionBody => isZh
      ? '这个会话的聊天记录和机器侧上下文都会被删除，工作目录里的文件不会受影响。'
      : 'This deletes the chat history and machine-side context for this session. Files in the workdir are not changed.';
  String sessionActionFailed(Object err) =>
      isZh ? '会话操作失败：$err' : 'Session action failed: $err';
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
  String get importMachineCredential =>
      isZh ? '导入机器凭证' : 'Import machine credential';
  String get emptyCredentialText => isZh
      ? '导入机器上脚本生成的凭证二维码或二维码内容，然后输入凭证密码。'
      : 'Import the credential QR code or QR payload generated by the script on the machine, then enter the credential password.';
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
  String get online => isZh ? '在线' : 'Online';
  String get offline => isZh ? '未在线' : 'Not online';
  String get compress => isZh ? '压缩对话' : 'Compress';
  String get compressComplete => isZh ? '压缩完成' : 'Compression complete';
  String compressFailed(Object err) =>
      isZh ? '压缩失败：$err' : 'Compression failed: $err';
  String get english => 'English';
  String get chinese => '中文';
  String get systemTheme => isZh ? '跟随系统' : 'System';
  String get lightTheme => isZh ? '白天' : 'Light';
  String get darkTheme => isZh ? '黑夜' : 'Dark';
  String get fileUnreadable =>
      isZh ? '无法读取凭证。' : 'Unable to read the credential.';
  String imported(String name) => isZh ? '已导入：$name' : 'Imported: $name';
  String get importFailedTitle => isZh ? '导入失败' : 'Import failed';
  String get credentialDecryptFailed => isZh
      ? '凭证解密失败。请确认二维码和密码是否正确。'
      : 'Credential decryption failed. Check the QR code and password.';
  String credentialBackendNotOk(String host) => isZh
      ? '已解密凭证，但 $host 没有返回正常状态。'
      : 'The credential decrypted, but $host did not return a healthy status.';
  String credentialTokenRejected(String host) => isZh
      ? '已连接到 $host，但凭证 token 被拒绝。这个二维码可能已经过期，或对应 token 已被吊销。请在后端重新生成二维码，并导入最新二维码。'
      : 'Connected to $host, but the credential token was rejected. This QR may be stale, or its token was revoked. Regenerate the QR on the backend and import the latest QR.';
  String credentialHostLookupFailed(String host) => isZh
      ? '无法解析 $host。请确认二维码里的地址仍然有效；如果使用 Cloudflare quick tunnel，请在后端重新生成二维码。'
      : 'Cannot resolve $host. Make sure the QR URL is still valid. If you use Cloudflare quick tunnel, regenerate the QR on the backend.';
  String credentialConnectionRefused(String host) => isZh
      ? '能找到 $host，但后端端口拒绝连接。请确认 AgentDeck 后端正在运行，并监听二维码里的端口。'
      : '$host resolved, but the backend port refused the connection. Make sure the AgentDeck backend is running and listening on the QR port.';
  String credentialNetworkUnreachable(String host) => isZh
      ? '无法连接到 $host。请确认网络可用、后端在线，或 Cloudflare quick tunnel 仍在运行。'
      : 'Cannot reach $host. Make sure the network is available, the backend is online, or the Cloudflare quick tunnel is still running.';
  String credentialConnectionTimedOut(String host) => isZh
      ? '连接 $host 超时。请确认后端在线，并且二维码地址仍然有效。'
      : 'Timed out connecting to $host. Make sure the backend is online and the QR URL is still valid.';
  String credentialConnectionFailed(String host, Object err) =>
      isZh ? '无法连接到 $host：$err' : 'Could not connect to $host: $err';
  String get testingCredentialConnection =>
      isZh ? '正在验证后端连接...' : 'Testing backend connection...';
  String get credentialDecryptTimedOut => isZh
      ? '凭证解密耗时过长。请确认二维码图片有效，或在后端重新生成最新二维码后再试。'
      : 'Credential decryption took too long. Check the QR image, or regenerate the latest QR on the backend and try again.';
  String get credentialQrDecodeTimedOut => isZh
      ? '二维码图片解析耗时过长。请上传后端保存的二维码 PNG，或重新生成最新二维码后再试。'
      : 'QR image parsing took too long. Upload the backend-saved QR PNG, or regenerate the latest QR and try again.';
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
      ? '删除当前会话的历史消息，并在机器上为这个会话开启新的上下文（不影响工作目录里的文件）。'
      : 'Delete this session history and start a new machine-side context for it. Files in the workdir are not changed.';
}
