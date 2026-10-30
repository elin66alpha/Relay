import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_core/features/settings/update_check.dart';

void main() {
  test('a release is newer only when a dotted part is higher', () {
    expect(isNewerVersion('0.1.9', '0.1.8'), isTrue);
    expect(isNewerVersion('0.1.10', '0.1.9'), isTrue);
    expect(isNewerVersion('0.2', '0.1.8'), isTrue);
    expect(isNewerVersion('0.1.8', '0.1.8'), isFalse);
    expect(isNewerVersion('0.2', '0.2.0'), isFalse);
    expect(isNewerVersion('0.1.7', '0.1.8'), isFalse);
  });

  MockClient github(int status, Object body) => MockClient(
        (http.Request request) async {
          expect(request.url, latestReleaseUri);
          return http.Response(jsonEncode(body), status);
        },
      );

  test('the latest version is the release tag without its v', () async {
    expect(
      await fetchLatestVersion(
        client: github(200, <String, Object>{'tag_name': 'v0.1.9'}),
      ),
      '0.1.9',
    );
  });

  test('a failed request or an odd tag is an error', () async {
    await expectLater(
      fetchLatestVersion(client: github(403, <String, Object>{})),
      throwsA(isA<http.ClientException>()),
    );
    await expectLater(
      fetchLatestVersion(
        client: github(200, <String, Object>{'tag_name': 'nightly'}),
      ),
      throwsFormatException,
    );
  });
}
