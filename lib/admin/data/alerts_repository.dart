import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';
import '../domain/alert.dart';

/// Alert Center (`/api/fm/alerts`, server alertCenterController.ts). Online
/// only: actions are not queued in v1 (FE-mobile.md Phase 4 "no queued sync").
class AlertsRepository {
  AlertsRepository(this._api);

  final ApiClient _api;

  static Map<String, dynamic> _data(Object? body) {
    final data = body is Map ? body['data'] : null;
    if (data is! Map<String, dynamic>) throw const UnknownFailure('Unexpected alerts response');
    return data;
  }

  Future<AlertPage> list(AlertFilters filters, {int page = 1}) async =>
      AlertPage.fromJson(_data(await _api.get('/api/fm/alerts', query: filters.toQuery(page: page))));

  Future<AlertDetail> detail(String key) async =>
      AlertDetail.fromJson(_data(await _api.get('/api/fm/alerts/${Uri.encodeComponent(key)}')));

  /// acknowledge | resolve | reopen | note | take | assign | unassign |
  /// snooze | unsnooze | work_order — [note] travels with any of them;
  /// [extra] carries `userId` (assign), `minutes` + `reason` (snooze) or
  /// `workOrderId` (work_order; null unlinks).
  Future<AlertItem> act(String key, String action, {String? note, Map<String, Object?> extra = const {}}) async =>
      AlertItem.fromJson(_data(await _api.post(
        '/api/fm/alerts/${Uri.encodeComponent(key)}/$action',
        body: {if (note != null && note.trim().isNotEmpty) 'note': note.trim(), ...extra},
      )));

  /// Who may be handed this alert: the covering teams first (server
  /// alertCenterController.ts alertAssignees).
  Future<List<Assignee>> assignees(String key) async {
    final body = await _api.get('/api/fm/alerts/${Uri.encodeComponent(key)}/assignees');
    final data = body is Map ? body['data'] : null;
    return [for (final p in (data as List? ?? const []).whereType<Map<String, dynamic>>()) assigneeFromJson(p)];
  }

  /// acknowledge | resolve several at once. The server answers
  /// `{done: [keys], skipped: [{key, reason}]}` (services/alerts/actions.ts bulkAct).
  Future<({int done, int skipped})> bulk(List<String> keys, String action) async {
    final data = _data(await _api.post('/api/fm/alerts/bulk', body: {'keys': keys, 'action': action}));
    return (done: (data['done'] as List? ?? const []).length, skipped: (data['skipped'] as List? ?? const []).length);
  }
}
