import 'package:web/web.dart' as web;

String clientDeviceName() {
  final String ua = web.window.navigator.userAgent.trim();
  if (ua.isEmpty) return 'Web browser';
  final String browser = _browserName(ua);
  final String os = _osName(ua);
  return os.isEmpty ? browser : '$browser on $os';
}

String _browserName(String ua) {
  if (ua.contains('Edg/')) return 'Edge';
  if (ua.contains('Firefox/')) return 'Firefox';
  if (ua.contains('Chrome/')) return 'Chrome';
  if (ua.contains('Safari/')) return 'Safari';
  return 'Web browser';
}

String _osName(String ua) {
  if (ua.contains('Windows')) return 'Windows';
  if (ua.contains('Mac OS X')) return 'macOS';
  if (ua.contains('Android')) return 'Android';
  if (ua.contains('iPhone') || ua.contains('iPad')) return 'iOS';
  if (ua.contains('Linux')) return 'Linux';
  return '';
}
