import 'package:flutter/foundation.dart';

import 'app_update_stub.dart' if (dart.library.io) 'app_update_io.dart'
    as platform;

/// The release asset this build installs over itself, or null where the app
/// cannot update itself: iOS (installed and updated through TestFlight) and
/// Web (served by the backend, so it updates with the backend).
String? updateAssetName(
  String version, {
  TargetPlatform? target,
  bool web = kIsWeb,
}) {
  if (web) return null;
  return switch (target ?? defaultTargetPlatform) {
    TargetPlatform.android => 'relay-client-android-v$version.apk',
    TargetPlatform.windows => 'relay-client-windows-x64-v$version.zip',
    TargetPlatform.linux => 'relay-client-linux_${version}_amd64.deb',
    TargetPlatform.macOS => 'relay-client-macos-v$version.zip',
    _ => null,
  };
}

Uri updateAssetUri(String version, String asset) => Uri.parse(
      'https://github.com/elin66alpha/Relay/releases/download/v$version/$asset',
    );

/// Downloads [asset] of release [version] and hands it to the system: Android
/// opens the package installer (which checks the signing certificate), Windows
/// replaces the app's files and restarts it, Linux opens the .deb in the
/// software installer, macOS unpacks the new app in Downloads.
/// [onProgress] reports 0..1, or null while the size is unknown.
Future<void> downloadAndInstallUpdate(
  String version,
  String asset, {
  required void Function(double? progress) onProgress,
}) =>
    platform.downloadAndInstall(
      updateAssetUri(version, asset),
      asset,
      onProgress,
    );
