import 'dart:convert';

import 'package:http/http.dart' as http;

/// GitHub's public API for the newest published release; drafts and
/// pre-releases are excluded by GitHub itself.
final Uri latestReleaseUri = Uri.parse(
  'https://api.github.com/repos/elin66alpha/Relay/releases/latest',
);

final RegExp _version = RegExp(r'^v?(\d+(?:\.\d+)*)$');

/// The latest release's version without its leading `v`, such as `0.1.9`.
/// Throws when the request fails or the tag is not a dotted version.
Future<String> fetchLatestVersion({http.Client? client}) async {
  final http.Client httpClient = client ?? http.Client();
  try {
    final http.Response response = await httpClient.get(
      latestReleaseUri,
      headers: const <String, String>{'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'HTTP ${response.statusCode}',
        latestReleaseUri,
      );
    }
    final Object? body = jsonDecode(response.body);
    final Object? tag = body is Map<String, Object?> ? body['tag_name'] : null;
    final RegExpMatch? match = tag is String ? _version.firstMatch(tag) : null;
    if (match == null) throw const FormatException('release tag');
    return match.group(1)!;
  } finally {
    if (client == null) httpClient.close();
  }
}

/// Whether dotted version [latest] is higher than [current]; missing parts
/// count as 0, so `0.2` equals `0.2.0`.
bool isNewerVersion(String latest, String current) {
  final List<int> a = latest.split('.').map(int.parse).toList();
  final List<int> b = current.split('.').map(int.parse).toList();
  for (int i = 0; i < a.length || i < b.length; i++) {
    final int x = i < a.length ? a[i] : 0;
    final int y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
