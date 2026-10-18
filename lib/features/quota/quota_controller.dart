import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';

class QuotaController extends ChangeNotifier {
  QuotaController({required BackendClient backendClient})
      : _backendClient = backendClient;

  final BackendClient _backendClient;
  int _quotaScheduleRevision = 0;

  int get quotaScheduleRevision => _quotaScheduleRevision;

  UsageReport? _lastUsageReport;

  /// The most recent quota report, kept so the usage and scheduler screens can
  /// paint the previous numbers immediately instead of holding a spinner for a
  /// round trip that reaches Anthropic and OpenAI. Cleared on a machine switch,
  /// since quota belongs to the host's credentials.
  UsageReport? get lastUsageReport => _lastUsageReport;

  /// Queries every quota source, or only [source]. A single-source result is
  /// merged into [lastUsageReport] and the merged report returned, so sources
  /// queried separately can land one at a time.
  Future<UsageReport> usageReport({String? source}) async {
    final UsageReport report = await _backendClient.usageReport(source: source);
    final UsageReport? last = _lastUsageReport;
    return _lastUsageReport =
        source == null || last == null ? report : last.merge(report);
  }

  Future<List<QuotaSchedule>> quotaSchedules() =>
      _backendClient.quotaSchedules();

  Future<QuotaSchedule> createQuotaSchedule({
    required String sourceKey,
    required String agentKey,
    required String sessionId,
    required String prompt,
    String? targetResetsAt,
    bool replaceExisting = false,
  }) async {
    return _backendClient.createQuotaSchedule(
      sourceKey: sourceKey,
      agentKey: agentKey,
      sessionId: sessionId,
      prompt: prompt,
      targetResetsAt: targetResetsAt,
      replaceExisting: replaceExisting,
    );
  }

  Future<void> cancelQuotaSchedule(String id) =>
      _backendClient.cancelQuotaSchedule(id);

  void clearUsageReport() {
    _lastUsageReport = null;
  }

  void quotaSchedulesChanged() {
    _quotaScheduleRevision += 1;
    notifyListeners();
  }
}
