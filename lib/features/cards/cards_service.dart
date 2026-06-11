import 'package:http/http.dart' as http;

import '../../core/backend/api_transport.dart';
import '../../core/models/card_model.dart';
import '../../core/storage/device_id_store.dart';
import '../../core/storage/machine_credentials_store.dart';
import '../../core/storage/workdir_store.dart';

/// HTTP client for the Card Mode endpoints.
class CardsService {
  CardsService({
    http.Client? httpClient,
    MachineCredentialsStore? credentialsStore,
    DeviceIdStore? deviceIdStore,
    WorkdirStore? workdirStore,
  }) : _transport = ApiTransport(
          httpClient: httpClient,
          credentialsStore: credentialsStore,
          deviceIdStore: deviceIdStore,
          workdirStore: workdirStore,
        );

  final ApiTransport _transport;

  Future<List<CardModel>> getCards() async {
    final Object? decoded = await _transport.requestJson('GET', '/api/cards');
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
    await _transport.requestJson(
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
    final Object? decoded =
        await _transport.requestJson('POST', '/api/cards/refresh');
    if (decoded is Map && decoded['generated'] is num) {
      return (decoded['generated'] as num).toInt();
    }
    return 0;
  }

  void close() => _transport.close();
}
