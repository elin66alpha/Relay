import 'package:flutter/foundation.dart';

/// Android and iOS, natively or in a mobile browser (on the Web this is the
/// browser's own OS): touch and a soft keyboard.
bool get isPhoneOrTablet =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

bool get usesHardwareKeyboard => !isPhoneOrTablet;
