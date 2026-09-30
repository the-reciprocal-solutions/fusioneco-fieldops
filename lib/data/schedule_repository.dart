import '../core/network/api_client.dart';
import '../core/network/envelope.dart';
import '../domain/user_schedule.dart';

/// `/api/schedules` (orchestrator spec O3 "Management"; server contract under
/// "## Contract (server)" in
/// `docs/superpowers/specs/2026-09-30-orchestrator-and-schedules.md`).
///
/// Online only, like the AI chat: pausing or deleting a reminder from a
/// plant room with no signal and having it apply an hour later is worse
/// than a plain "you're offline" — the screen says that and offers retry.
/// Schedules are *created* in a thread ("@agent remind me…"), which goes
/// through the conversation's offline-capable post.
class ScheduleRepository {
  ScheduleRepository(this._api);
  final ApiClient _api;

  static List<Map<String, dynamic>> _rows(dynamic body) {
    final data = unwrap(body);
    if (data is List) return unwrapList(data);
    if (data is Map) {
      for (final k in const ['schedules', 'items', 'rows']) {
        if (data[k] is List) return unwrapList(data[k]);
      }
    }
    return const [];
  }

  /// The signed-in person's schedules.
  Future<List<UserSchedule>> mine() async {
    final res = await _api.get('/api/schedules');
    return _rows(res.data).map(UserSchedule.fromJson).where((s) => s.id.isNotEmpty).toList();
  }

  Future<UserSchedule?> setPaused(String id, bool paused) async {
    final res = await _api.patch(
      '/api/schedules/${Uri.encodeComponent(id)}',
      data: {'status': paused ? 'paused' : 'active'},
    );
    final row = unwrapMap(res.data);
    final inner = row['schedule'] is Map ? Map<String, dynamic>.from(row['schedule'] as Map) : row;
    return inner.isEmpty ? null : UserSchedule.fromJson(inner);
  }

  /// A one-click follow-up from a Flow Agent reply (C1): the server's
  /// `ScheduleDraft` as-is, plus the record and the thread message it came
  /// from, so the done notification links back into that thread.
  Future<UserSchedule> createFromDraft(
    Map<String, dynamic> draft, {
    required String entity,
    required String entityId,
    String? messageId,
  }) async {
    final body = <String, dynamic>{
      for (final k in const ['kind', 'title', 'request', 'cron', 'runAt', 'tz', 'until', 'watch'])
        if (draft.containsKey(k)) k: draft[k],
      'record': draft['record'] ?? {'entity': entity, 'id': entityId},
      'origin': {'entity': entity, 'entityId': entityId, 'messageId': ?messageId},
    };
    final res = await _api.post('/api/schedules', data: body);
    return UserSchedule.fromJson(unwrapMap(res.data));
  }

  /// "Run now" / "Try again" (within the run budget).
  Future<void> runNow(String id) => _api.post('/api/schedules/${Uri.encodeComponent(id)}/run-now');

  Future<void> delete(String id) => _api.delete('/api/schedules/${Uri.encodeComponent(id)}');

  Future<List<ScheduleRun>> runs(String id) async {
    final res = await _api.get('/api/schedules/${Uri.encodeComponent(id)}/runs');
    final data = unwrap(res.data);
    final rows = data is Map && data['runs'] is List ? unwrapList(data['runs']) : _rows(res.data);
    return rows.map(ScheduleRun.fromJson).toList();
  }
}
