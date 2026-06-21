import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/api_transport.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/util/error_text.dart';
import 'package:relay/core/util/format_bytes.dart';
import 'package:relay/core/util/time_format.dart';

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
            strings, const MachineCredentialException('bad passphrase'),),
        'bad passphrase',
      );
    });

    test('maps NETWORK_* backend codes to the localized network message', () {
      final BackendException err =
          BackendException('raw', code: 'NETWORK_TIMEOUT');
      expect(friendlyErrorText(strings, err), strings.networkError('NETWORK_TIMEOUT'));
      expect(friendlyErrorText(strings, err), isNot('raw'));
    });

    test('returns the message for non-network backend exceptions', () {
      expect(
        friendlyErrorText(strings,
            BackendException('token missing', code: 'TOKEN_NOT_CONFIGURED'),),
        'token missing',
      );
      expect(friendlyErrorText(strings, BackendException('plain')), 'plain');
    });

    test('falls back to toString for arbitrary errors', () {
      expect(friendlyErrorText(strings, StateError('boom')),
          'Bad state: boom',);
    });
  });
}
