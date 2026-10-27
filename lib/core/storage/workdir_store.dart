import 'package:shared_preferences/shared_preferences.dart';

/// The work directory this device is currently in on each machine. Sessions
/// are scoped by `workdir + agent + session`, while each device holds its own
/// current path locally and sends it back on every request (the `X-Workdir`
/// header). A path belongs to one backend's file system, so it is kept per
/// machine: sending one host's path to another would make that backend create
/// it.
class WorkdirStore {
  WorkdirStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _keyPrefix = 'relay.workdir.v2.';
  static final Map<String, String?> _cache = <String, String?>{};

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  static void resetCacheForTest() {
    _cache.clear();
  }

  /// The stored path for [machineId], or null when this device has not chosen
  /// one there yet (the backend then falls back to its default workdir).
  Future<String?> read(String machineId) async {
    if (_cache.containsKey(machineId)) return _cache[machineId];

    final String? value = (await _store).getString(_keyPrefix + machineId);
    final String trimmed = value?.trim() ?? '';
    return _cache[machineId] = trimmed.isEmpty ? null : trimmed;
  }

  Future<void> write(String machineId, String dir) async {
    final String trimmed = dir.trim();
    if (trimmed.isEmpty) {
      await (await _store).remove(_keyPrefix + machineId);
      _cache[machineId] = null;
      return;
    }
    await (await _store).setString(_keyPrefix + machineId, trimmed);
    _cache[machineId] = trimmed;
  }
}
