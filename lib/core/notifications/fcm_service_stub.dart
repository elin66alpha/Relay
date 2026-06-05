import '../backend/backend_client.dart';

class FcmService {
  FcmService._();

  static final FcmService instance = FcmService._();

  Future<bool> syncRegistration({
    required BackendClient backendClient,
    required String lang,
    required bool quotaPushEnabled,
    required bool taskPushEnabled,
  }) async {
    return true;
  }

  Future<void> unregister(BackendClient backendClient) async {}
}
