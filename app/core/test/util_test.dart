import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/api_transport.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/platform/platform_capabilities.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/util/error_text.dart';
import 'package:relay_core/core/util/format_bytes.dart';
import 'package:relay_core/core/util/time_format.dart';

void main() {
  group('formatBytes', () {
    test('handles zero and negatives', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-5), '0 B');
    });

    test('formats bytes, KB, MB, GB at boundaries', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });
  });

  group('formatLongTime', () {
    test('returns empty for null or blank', () {
      expect(formatLongTime(null), '');
      expect(formatLongTime(''), '');
    });

    test('formats a parseable local timestamp', () {
      // No timezone suffix parses as local time, so toLocal() is a no-op and the
      // output is stable regardless of the test machine's zone.
      expect(formatLongTime('2026-01-02T03:04:05'), '2026-01-02 03:04:05');
    });

    test('falls back to a cleaned-up string when unparseable', () {
      expect(formatLongTime('garbage'), 'garbage');
      expect(formatLongTime('2026-01-02Tbroken.999'), '2026-01-02 broken');
    });
  });

  group('friendlyErrorText', () {
    const AppStrings strings = AppStrings(AppLanguage.en);

    test('returns a credential exception message verbatim', () {
      expect(
        friendlyErrorText(
          strings,
          const MachineCredentialException('bad passphrase'),
        ),
        'bad passphrase',
      );
    });

    test('maps NETWORK_* backend codes to the localized network message', () {
      final BackendException err =
          BackendException('raw', code: 'NETWORK_TIMEOUT');
      expect(
        friendlyErrorText(strings, err),
        strings.networkError('NETWORK_TIMEOUT'),
      );
      expect(friendlyErrorText(strings, err), isNot('raw'));
    });

    test('returns the message for non-network backend exceptions', () {
      expect(
        friendlyErrorText(
          strings,
          BackendException('token missing', code: 'TOKEN_NOT_CONFIGURED'),
        ),
        'token missing',
      );
      expect(friendlyErrorText(strings, BackendException('plain')), 'plain');
    });

    test('maps an Express 404 page to the backend-too-old message', () {
      final BackendException err = ApiTransport().exceptionFor(
        404,
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<title>Error</title>\n</head>\n<body>\n'
        '<pre>Cannot POST /api/fs/mkdir</pre>\n</body>\n</html>\n',
      );
      expect(err.code, 'BACKEND_ROUTE_MISSING');
      expect(friendlyErrorText(strings, err), strings.backendTooOld);
      expect(
        ApiTransport().exceptionFor(404, '{"error":"path not found"}').code,
        isNull,
      );
    });

    test('falls back to toString for arbitrary errors', () {
      expect(
        friendlyErrorText(strings, StateError('boom')),
        'Bad state: boom',
      );
    });

    test('classifies Linux, macOS and Windows socket errors alike', () {
      final Uri uri = Uri.parse('http://10.0.0.5:8787/api/health');
      for (final (String message, String code) in <(String, String)>[
        ('Connection refused (OS Error: errno = 111)', 'CONNECTION_REFUSED'),
        (
          'No connection could be made because the target machine actively '
              'refused it. (OS Error: errno = 10061)',
          'CONNECTION_REFUSED',
        ),
        (
          'The remote computer refused the network connection. '
              '(OS Error: errno = 1225)',
          'CONNECTION_REFUSED',
        ),
        ('Network is unreachable (OS Error: errno = 101)', 'UNREACHABLE'),
        ('No route to host (OS Error: errno = 65)', 'UNREACHABLE'),
        (
          'A socket operation was attempted to an unreachable host. '
              '(OS Error: errno = 10065)',
          'UNREACHABLE',
        ),
        (
          'The network location cannot be reached. (OS Error: errno = 1231)',
          'UNREACHABLE',
        ),
      ]) {
        expect(
          ApiTransport().networkExceptionFor(Exception(message), uri).code,
          'NETWORK_$code',
          reason: message,
        );
      }
    });
  });

  test('phones and tablets, native or Web, use the soft keyboard', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final TargetPlatform platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final bool phone =
          platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      expect(isPhoneOrTablet, phone, reason: '$platform');
      expect(usesHardwareKeyboard, !phone, reason: '$platform');
    }
  });
}
