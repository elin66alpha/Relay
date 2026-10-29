import 'package:flutter/foundation.dart';

bool get isDesktopTarget =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

bool get usesHardwareKeyboard => kIsWeb || isDesktopTarget;
