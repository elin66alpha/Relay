import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/backend/backend_client.dart' show BackendException;
import '../../core/models/card_model.dart';
import '../../core/models/machine_credential.dart';
import '../../core/storage/device_id_store.dart';
import '../../core/storage/machine_credentials_store.dart';

/// HTTP client for the Card Mode endpoints. Mirrors the connection logic of
/// [BackendClient] (same credential/device-id/bearer-token headers and base
/// URL resolution) so cards ride the existing authenticated backend without
/// modifying the existing client.
class CardsService {
  CardsService({
    http.Client? httpClient,
    MachineCredentialsStore? credentialsStore,
    DeviceIdStore? deviceIdStore,
  })  : _httpClient = httpClient ?? http.Client(),
        _credentialsStore = credentialsStore ?? MachineCredentialsStore(),
        _deviceIdStore = deviceIdStore ?? DeviceIdStore();

  final http.Client _httpClient;
  final MachineCredentialsStore _credentialsStore;
  final DeviceIdStore _deviceIdStore;

  Future<List<CardModel>> getCards() async {
    final Object? decoded = await _requestJson('GET', '/api/cards');
    final List<Object?> raw = decoded is Map && decoded['cards'] is List
        ? (decoded['cards'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => CardModel.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<void> sendFeedback(
    String cardId,
    String gesture, {
    DateTime? deferUntil,
  }) async {
    await _requestJson(
      'POST',
      '/api/cards/feedback',
      body: <String, Object?>{
        'cardId': cardId,
        'gesture': gesture,
        if (deferUntil != null)
          'deferUntil': deferUntil.toUtc().toIso8601String(),
      },
    );
  }

  Future<int> refresh() async {
    final Object? decoded = await _requestJson('POST', '/api/cards/refresh');
    if (decoded is Map && decoded['generated'] is num) {
      return (decoded['generated'] as num).toInt();
    }
    return 0;
  }

  void close() => _httpClient.close();

  Future<Object?> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(credential, path);
    final Map<String, String> headers = await _headers(credential);
    const Duration timeout = Duration(seconds: 20);
    late final http.Response response;
    if (method == 'GET') {
      response = await _httpClient.get(uri, headers: headers).timeout(timeout);
    } else {
      response = await _httpClient
          .post(uri, headers: headers, body: jsonEncode(body ?? const {}))
          .timeout(timeout);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, response.body);
    }
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw BackendException('Backend returned non-JSON content.');
    }
  }

  Future<MachineCredential> _requireCredential() async {
    final MachineCredential? credential = await _credentialsStore.readActive();
    if (credential == null) {
      throw BackendException('Import a machine credential first.');
    }
    return credential;
  }

  Uri _uri(MachineCredential credential, String path) {
    final String base = credential.baseUrl.endsWith('/')
        ? credential.baseUrl
        : '${credential.baseUrl}/';
    final String cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(base).resolve(cleanPath);
  }

  Future<Map<String, String>> _headers(MachineCredential credential) async {
    final String deviceId = await _deviceIdStore.readOrCreate();
    return <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${credential.token.trim()}',
      'X-Device-Id': deviceId,
    };
  }

  BackendException _exceptionFor(int status, String body) {
    String message = body.trim();
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        if (decoded['error'] != null) message = decoded['error'].toString();
        return BackendException(
          message.isEmpty ? 'HTTP $status' : message,
          status: status,
          code: decoded['code']?.toString(),
        );
      }
    } on FormatException {
      // Keep raw body.
    }
    if (message.isEmpty) message = 'HTTP $status';
    return BackendException(message, status: status);
  }
}
