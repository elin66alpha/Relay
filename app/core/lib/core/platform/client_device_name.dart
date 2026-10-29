import 'client_device_name_stub.dart'
    if (dart.library.html) 'client_device_name_web.dart' as platform;

String clientDeviceName() => platform.clientDeviceName();
