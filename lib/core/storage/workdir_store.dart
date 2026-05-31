import 'package:shared_preferences/shared_preferences.dart';

/// The work directory this device is currently in. With shared sessions keyed by
/// `workdir + agent`, each device holds its own current path locally and sends
/// it back on every request (the `X-Workdir` header), so two devices can be in
/// different paths at once and converge to one conversation when they match.
class WorkdirStore {
  WorkdirStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _key = 'agentdeck.workdir.v1';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// The stored path, or null when this device has not chosen one yet (the
  /// backend then falls back to its default workdir).
  Future<String?> read() async {
    final String? value = (await _store).getString(_key);
    final String trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> write(String dir) async {
    final String trimmed = dir.trim();
    if (trimmed.isEmpty) {
      await (await _store).remove(_key);
      return;
    }
    await (await _store).setString(_key, trimmed);
  }

  Future<void> clear() async {
    await (await _store).remove(_key);
  }
}
