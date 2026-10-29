import '../backend/api_transport.dart';
import '../i18n/app_strings.dart';
import '../models/machine_credential.dart';

String friendlyErrorText(AppStrings strings, Object err) {
  if (err is MachineCredentialException) {
    return err.message;
  }
  if (err is BackendException) {
    if (err.code?.startsWith('NETWORK_') ?? false) {
      return strings.networkError(err.code);
    }
    return err.message;
  }
  return err.toString();
}
