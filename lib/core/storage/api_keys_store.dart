import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/llm_provider.dart';

class ApiKeysStore {
  ApiKeysStore({FlutterSecureStorage? storage})
      : _storage = storage ?? _defaultStorage();

  final FlutterSecureStorage _storage;

  static FlutterSecureStorage _defaultStorage() {
    return const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
  }

  String _key(LlmProvider provider) => 'agentdeck.api_key.${provider.name}';

  Future<String?> read(LlmProvider provider) async {
    final String? value = await _storage.read(key: _key(provider));
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  Future<void> write(LlmProvider provider, String apiKey) {
    return _storage.write(key: _key(provider), value: apiKey.trim());
  }

  Future<void> clear(LlmProvider provider) {
    return _storage.delete(key: _key(provider));
  }

  Future<Map<LlmProvider, bool>> presence() async {
    final Map<LlmProvider, bool> out = <LlmProvider, bool>{};
    for (final LlmProvider provider in LlmProvider.values) {
      final String? key = await read(provider);
      out[provider] = key != null;
    }
    return out;
  }
}
