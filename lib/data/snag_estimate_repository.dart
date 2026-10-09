import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';
import '../core/network/envelope.dart';
import '../domain/snag.dart';
import '../domain/snag_estimate.dart';
import '../state/providers.dart';

/// Snag estimate & quote help (server documentation/snag-assistant.md §4c).
///
/// ONLINE-ONLY on purpose (takes [ApiClient], not SyncClient): an estimate is
/// a read that only makes sense with the catalogue and stock as they are now,
/// and the three writes — draft quote, reserve/request materials, work order —
/// are approvals a person makes while looking at the numbers. Replaying one
/// of those hours later from the queue would act on numbers nobody saw.
/// Offline, the card says it needs a connection and nothing is queued.
///
/// Each write carries a `requestId` minted once per approval (the sheet keeps
/// it across retries), so a double tap or a retry after a timeout returns the
/// first quote / work order instead of making a second one.
abstract interface class SnagEstimateGateway {
  Future<SnagEstimate> estimate(String snagId, {bool ai = false, bool fresh = false, Map<String, num>? assumptions});
  Future<({String quoteNumber, String quoteId, double grandTotal, String currency, bool replayed})> draftQuote(
    String snagId, {
    required String requestId,
    required List<QuoteLineDraft> lines,
    double? contingencyPct,
    String? subject,
    String? scope,
    List<String> assumptions = const [],
  });
  Future<List<({String name, bool ok, String message})>> materials(
    String snagId, {
    required String requestId,
    required List<({String materialId, int quantity, String action, String? vendorId})> lines,
  });
  Future<({String workOrderId, String id, bool alreadyLinked})> workOrder(
    String snagId, {
    required String requestId,
    DateTime? dueDate,
    double? estimatedHours,
  });

  /// Applies the estimate's suggested priority or fix-by date (a normal
  /// `PATCH /api/snags/:id`, logged as "Details edited" under the person).
  /// Online like the rest of the card; the screen re-reads the snag after.
  Future<void> applySuggestion(String snagId, {SnagPriority? priority, DateTime? dueDate});
}

/// Thrown for an answer the screen can show as is (the server's own plain
/// words, e.g. "Add a price for: Joint cover."), or for no connection.
class SnagEstimateFailure implements Exception {
  const SnagEstimateFailure(this.message, {this.offline = false, this.code});
  final String message;
  final bool offline;
  final String? code;
  @override
  String toString() => 'SnagEstimateFailure($code): $message';
}

class SnagEstimateRepository implements SnagEstimateGateway {
  SnagEstimateRepository(this._api);
  final ApiClient _api;

  static String newRequestId() => const Uuid().v4();

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, Duration timeout) async {
    try {
      final res = await _api.post(path, data: body, receiveTimeout: timeout);
      return unwrapMap(res.data);
    } on NetworkFailure {
      throw const SnagEstimateFailure('', offline: true);
    } on HttpFailure catch (e) {
      final b = e.body;
      final code = b is Map ? b['code']?.toString() : null;
      // 5xx text from mapDioException is already plain; 4xx carries the server's message.
      throw SnagEstimateFailure(e.message, code: code);
    } on ApiFailure catch (e) {
      throw SnagEstimateFailure(e.message);
    }
  }

  @override
  Future<SnagEstimate> estimate(String snagId, {bool ai = false, bool fresh = false, Map<String, num>? assumptions}) async {
    // The server gives the engine 45 s; a fresh answer measured 16–24 s (2026-10-10).
    final data = await _post(
      '/api/snags/$snagId/ai/estimate',
      {'ai': ai, if (fresh) 'fresh': true, 'assumptions': ?assumptions},
      Duration(seconds: ai ? 60 : 20),
    );
    final e = SnagEstimate.fromJson(data);
    if (e == null) throw const SnagEstimateFailure('');
    return e;
  }

  @override
  Future<({String quoteNumber, String quoteId, double grandTotal, String currency, bool replayed})> draftQuote(
    String snagId, {
    required String requestId,
    required List<QuoteLineDraft> lines,
    double? contingencyPct,
    String? subject,
    String? scope,
    List<String> assumptions = const [],
  }) async {
    final data = await _post(
      '/api/snags/$snagId/ai/quote',
      {
        'requestId': requestId,
        'lines': [for (final l in lines) l.toJson()],
        'contingencyPct': ?contingencyPct,
        'subject': ?subject,
        'scope': ?scope,
        'assumptions': assumptions,
      },
      const Duration(seconds: 30),
    );
    final q = data['quote'] is Map ? Map<String, dynamic>.from(data['quote'] as Map) : const <String, dynamic>{};
    return (
      quoteNumber: firstNonEmpty([q['quoteNumber']]) ?? '—',
      quoteId: firstNonEmpty([q['id']]) ?? '',
      grandTotal: asDouble(q['grandTotal']) ?? 0,
      currency: firstNonEmpty([q['currency']]) ?? 'AED',
      replayed: asBool(data['replayed']) ?? false,
    );
  }

  @override
  Future<List<({String name, bool ok, String message})>> materials(
    String snagId, {
    required String requestId,
    required List<({String materialId, int quantity, String action, String? vendorId})> lines,
  }) async {
    final data = await _post(
      '/api/snags/$snagId/ai/materials',
      {
        'requestId': requestId,
        'lines': [
          for (final l in lines) {'materialId': l.materialId, 'quantity': l.quantity, 'action': l.action, 'vendorId': ?l.vendorId},
        ],
      },
      const Duration(seconds: 30),
    );
    return (data['lines'] is List ? data['lines'] as List : const [])
        .whereType<Map>()
        .map((l) => (name: l['name']?.toString() ?? '—', ok: asBool(l['ok']) ?? false, message: l['message']?.toString() ?? ''))
        .toList();
  }

  @override
  Future<({String workOrderId, String id, bool alreadyLinked})> workOrder(
    String snagId, {
    required String requestId,
    DateTime? dueDate,
    double? estimatedHours,
  }) async {
    final data = await _post(
      '/api/snags/$snagId/work-order',
      {
        'requestId': requestId,
        'dueDate': ?dueDate?.toUtc().toIso8601String(),
        'estimatedHours': ?estimatedHours,
      },
      const Duration(seconds: 30),
    );
    final wo = data['workOrder'] is Map ? Map<String, dynamic>.from(data['workOrder'] as Map) : const <String, dynamic>{};
    return (
      workOrderId: firstNonEmpty([wo['workOrderId']]) ?? '—',
      id: firstNonEmpty([wo['id']]) ?? '',
      alreadyLinked: asBool(data['alreadyLinked']) ?? false,
    );
  }

  @override
  Future<void> applySuggestion(String snagId, {SnagPriority? priority, DateTime? dueDate}) async {
    try {
      await _api.patch('/api/snags/$snagId', data: {
        'priority': ?priority?.wire,
        'dueDate': ?dueDate?.toUtc().toIso8601String(),
      });
    } on NetworkFailure {
      throw const SnagEstimateFailure('', offline: true);
    } on ApiFailure catch (e) {
      throw SnagEstimateFailure(e.message);
    }
  }
}

final snagEstimateRepositoryProvider = Provider<SnagEstimateGateway>(
  (ref) => SnagEstimateRepository(ref.watch(apiClientProvider)),
);
