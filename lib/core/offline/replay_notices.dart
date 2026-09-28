/// What a queued write's successful (2xx) replay still has to tell the
/// technician. The flush logs each notice in the local conflict log, which
/// the Sync Center shows.
///
/// - `captureConflict` (FR-4.8): the write succeeded, but the register moved
///   while it sat in the queue — informational, `dropped: false`.
/// - `rejected[]` (PENDING P-008 (2)): the request succeeded but the server
///   refused some items, e.g. an AR progress verify that breaks four-eyes.
///   Offline, the phone never saw that answer and kept showing the refused
///   status — so this is a real "could not be saved", `dropped: true`.
///   Only a list of `{globalId, reason}` counts: some endpoints (AR alignment
///   events) return `rejected` as a plain number, which is not a refusal the
///   technician can act on.
library;

class ReplayNotice {
  const ReplayNotice({required this.reason, required this.dropped});

  final String reason;
  final bool dropped;
}

List<ReplayNotice> replayNoticesFrom(dynamic responseData) {
  if (responseData is! Map) return const [];
  final body = responseData['data'] is Map ? responseData['data'] as Map : responseData;
  final notices = <ReplayNotice>[];

  final conflict = body['captureConflict'];
  final message = conflict is Map ? conflict['message'] : null;
  if (message is String && message.isNotEmpty) {
    notices.add(ReplayNotice(reason: message, dropped: false));
  }

  final rejected = body['rejected'];
  if (rejected is List) {
    final items = rejected.whereType<Map>().toList();
    if (items.isNotEmpty) {
      final reasons = <String>{
        for (final r in items)
          if (r['reason'] is String && (r['reason'] as String).isNotEmpty) r['reason'] as String,
      };
      final count = items.length;
      final what = count == 1 ? '1 item' : '$count items';
      notices.add(ReplayNotice(
        reason: reasons.isEmpty
            ? 'The server refused $what.'
            : 'The server refused $what: ${reasons.join(' ')}',
        dropped: true,
      ));
    }
  }
  return notices;
}
