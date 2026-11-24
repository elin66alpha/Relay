import 'package:flutter/foundation.dart';

/// Android and iOS, natively or in a mobile browser (on the Web this is the
/// browser's own OS): touch and a soft keyboard.
bool get isPhoneOrTablet =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

bool get usesHardwareKeyboard => !isPhoneOrTablet;

/// Drag-and-drop file upload is a desktop and desktop-Web feature; phones and
/// tablets (native or mobile browser) never show the drop zone or hint.
bool get supportsFileDrop => !isPhoneOrTablet;
