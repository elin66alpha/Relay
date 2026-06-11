import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/machine_credential.dart';
import '../storage/device_id_store.dart';
import '../storage/machine_credentials_store.dart';
import '../storage/workdir_store.dart';

class BackendException implements Exception {
  BackendException(this.message, {this.status, this.code});

  final String message;
  final int? status;
  final String? code;

  @override
  String toString() => 'BackendException(${status ?? '-'}): $message';
}

class ApiTransport {
  ApiTransport({
    MachineCredentialsStore? credentialsStore,
    DeviceIdStore? deviceIdStore,
    WorkdirStore? workdirStore,
    http.Client? httpClient,
  })  : _credentialsStore = credentialsStore ?? MachineCredentialsStore(),
        _deviceIdStore = deviceIdStore ?? DeviceIdStore(),
        _workdirStore = workdirStore ?? WorkdirStore(),
        httpClient = httpClient ?? http.Client();

  final MachineCredentialsStore _credentialsStore;
  final DeviceIdStore _deviceIdStore;
  final WorkdirStore _workdirStore;
  final http.Client httpClient;

  Future<String?> currentWorkdir() => _workdirStore.read();

  Future<void> writeWorkdir(String dir) => _workdirStore.write(dir);

  void close() {
    httpClient.close();
  }

  Future<Object?> requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final MachineCredential credential = await requireCredential();
    return requestJsonWithCredential(
      credential,
      method,
      path,
      body: body,
      timeout: timeout,
    );
  }

  Future<Object?> requestJsonWithCredential(
    MachineCredential credential,
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Uri requestUri = uri(credential, path);
    final Map<String, String> requestHeaders = await headers(credential);
    late final http.Response response;
    try {
      if (method == 'GET') {
        response = await httpClient
            .get(requestUri, headers: requestHeaders)
            .timeout(timeout);
      } else if (method == 'POST') {
        response = await httpClient
            .post(
              requestUri,
              headers: requestHeaders,
              body: jsonEncode(body ?? const <String, Object?>{}),
            )
            .timeout(timeout);
      } else {
        throw BackendException('Unsupported method: $method');
      }
    } on BackendException {
      rethrow;
    } on TimeoutException {
      throw BackendException(
        'Timed out connecting to ${requestUri.host}.',
        code: 'NETWORK_TIMEOUT',
      );
    } on http.ClientException catch (err) {
      throw networkExceptionFor(err, requestUri);
    } catch (err) {
      throw networkExceptionFor(err, requestUri);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw exceptionFor(response.statusCode, response.body);
    }
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw BackendException('Backend returned non-JSON content.');
    }
  }

  Future<MachineCredential> requireCredential() async {
    final MachineCredential? credential = await _credentialsStore.readActive();
    if (credential == null) {
      throw BackendException('Import a machine credential first.');
    }
    return credential;
  }

  Uri uri(MachineCredential credential, String path) {
    final String base = credential.baseUrl.endsWith('/')
        ? credential.baseUrl
        : '${credential.baseUrl}/';
    final String cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(base).resolve(cleanPath);
  }

  Future<Map<String, String>> headers(
    MachineCredential credential, {
    String accept = 'application/json',
    String contentType = 'application/json',
  }) async {
    final String deviceId = await _deviceIdStore.readOrCreate();
    final String? workdir = await _workdirStore.read();
    return <String, String>{
      'Accept': accept,
      'Content-Type': contentType,
      'Authorization': 'Bearer ${credential.token.trim()}',
      'X-Device-Id': deviceId,
      if (workdir != null && workdir.isNotEmpty) 'X-Workdir': workdir,
    };
  }

  BackendException exceptionFor(int status, String body) {
    String message = body.trim();
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        if (decoded['error'] != null) {
          message = decoded['error'].toString();
        }
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

  BackendException networkExceptionFor(Object err, Uri uri) {
    final String raw = err.toString();
    final String lower = raw.toLowerCase();
    String code = 'NETWORK_ERROR';
    if (lower.contains('failed host lookup') ||
        lower.contains('no address associated') ||
        lower.contains('name_not_resolved') ||
        lower.contains('nodename nor servname')) {
      code = 'NETWORK_HOST_LOOKUP';
    } else if (lower.contains('connection refused')) {
      code = 'NETWORK_CONNECTION_REFUSED';
    } else if (lower.contains('network is unreachable') ||
        lower.contains('no route to host')) {
      code = 'NETWORK_UNREACHABLE';
    }
    return BackendException(raw, code: code);
  }
}
