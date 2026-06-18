import 'package:flutter/foundation.dart';

String clientDeviceName() {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android app',
    TargetPlatform.iOS => 'iOS app',
    TargetPlatform.macOS => 'macOS app',
    TargetPlatform.windows => 'Windows app',
    TargetPlatform.linux => 'Linux app',
    TargetPlatform.fuchsia => 'Fuchsia app',
  };
}
