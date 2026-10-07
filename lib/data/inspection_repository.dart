import 'dart:typed_data';

import '../core/inspection/inspection_send_state.dart';
import '../core/network/api_exception.dart';
import '../core/network/envelope.dart';
import '../core/offline/flush_policy.dart';
import '../core/offline/sync_client.dart';
import '../domain/inspection.dart';

/// How one tap on Submit ended, for the form to show the technician.
sealed class InspectionSubmitOutcome {
  const InspectionSubmitOutcome();
}

/// The server has it.
class InspectionSubmitted extends InspectionSubmitOutcome {
  const InspectionSubmitted();
}

/// Parked in the offline queue; it sends by itself once [status] clears.
class InspectionQueued extends InspectionSubmitOutcome {
  const InspectionQueued(this.status);
  final InspectionSendStatus status;
}

/// The server refused it. The answers stay on the phone (and in the form).
class InspectionRefused extends InspectionSubmitOutcome {
  const InspectionRefused({required this.reasonKey, this.missing = const []});
  final String reasonKey;

  /// Field labels the server reported missing (400), shown in the reason.
  final List<String> missing;
}

class InspectionRepository {
  InspectionRepository(this._sync);

  final SyncClient _sync;

  /// `PendingMutation.entityType` for a queued submit.
  static const entityType = 'inspection';

  static String submitPath(String id) => '/api/fm/inspections/technician/$id/submit';
  static String _draftKey(String id) => 'inspection.submit.$id';

  Future<List<InspectionAssignmentSummary>> listAssigned() async {
    final read = await _sync.syncGet('/api/fm/inspections/technician/assigned');
    return unwrapList(
      read.data,
    ).map(InspectionAssignmentSummary.fromJson).toList();
  }

  Future<InspectionAssignmentDetail> detail(String id) async {
    final read = await _sync.syncGet('/api/fm/inspections/technician/$id');
    return InspectionAssignmentDetail.fromJson(unwrapMap(read.data));
  }

  /// `POST /api/fm/inspections/technician/:id/submit {data}` — the same call
  /// the web technician portal makes (`app/technician/inspections/[id]`).
  ///
  /// 2026-10-06 iPhone report "inspections are not getting submitted": the
  /// server's location gate answered this POST with 428 whenever the
  /// technician's last check-in was over 24 h old, and the form turned that
  /// into "Failed to submit … try again" — a retry 428'd the same way. Now:
  /// - the answers are kept on the phone (`sync_meta`) until the server has
  ///   them, so nothing is lost if the technician leaves the form;
  /// - no signal, a 5xx, a 428 (check-in needed) or a 401 (sign in again)
  ///   park the submit in the queue, which sends it once that clears
  ///   (`CheckInController.checkIn()` resumes the flush);
  /// - any other refusal comes back as a plain-words reason, never the
  ///   server's raw text.
  /// The server now exempts this POST from the gate (`middleware/auth.ts`);
  /// the 428 path stays for servers that do not have that yet.
  Future<InspectionSubmitOutcome> submit(String id, Map<String, dynamic> responseData) async {
    final draft = InspectionSubmitDraft(
      answers: Map<String, dynamic>.from(responseData),
      savedAt: DateTime.now(),
    );
    await _writeDraft(id, draft);
    final body = {'data': responseData};
    try {
      final write = await _sync.syncRequest(
        'post',
        submitPath(id),
        data: body,
        label: 'Inspection submission',
        entityType: entityType,
        entityId: id,
        queueOnServerError: true,
      );
      if (write.synced) {
        await clearDraft(id);
        return const InspectionSubmitted();
      }
      return const InspectionQueued(
        InspectionSendStatus(
          InspectionSendState.waiting,
          reasonKey: 'inspection.send.waiting_hint',
        ),
      );
    } on HttpFailure catch (e) {
      if (e.status == 428 || e.status == 401) {
        await _writeDraft(id, draft.withIssue(InspectionSendIssue(status: e.status)));
        await _sync.queueRequest(
          'post',
          submitPath(id),
          data: body,
          label: 'Inspection submission',
          entityType: entityType,
          entityId: id,
        );
        return InspectionQueued(
          e.status == 428
              ? const InspectionSendStatus(
                  InspectionSendState.waitingCheckIn,
                  reasonKey: 'inspection.send.checkin_hint',
                )
              : const InspectionSendStatus(
                  InspectionSendState.waitingSignIn,
                  reasonKey: 'inspection.send.signin_hint',
                ),
        );
      }
      final missing = _missingFrom(e.body);
      await _writeDraft(
        id,
        draft.withIssue(
          InspectionSendIssue(status: e.status, code: _codeOf(e.body), dropped: true, missing: missing),
        ),
      );
      return InspectionRefused(reasonKey: refusedReasonKey(e.status), missing: missing);
    }
  }

  /// The answers of a submit the server does not have yet, if any.
  Future<InspectionSubmitDraft?> readDraft(String id) async =>
      InspectionSubmitDraft.decode(await _sync.db.readMeta(_draftKey(id)));

  /// `sync_meta` has no delete; an empty value reads back as "no draft".
  Future<void> clearDraft(String id) => _sync.db.writeMeta(_draftKey(id), '');

  Future<void> _writeDraft(String id, InspectionSubmitDraft draft) =>
      _sync.db.writeMeta(_draftKey(id), draft.encode());

  /// A queued submit replayed fine: the server has the answers.
  Future<void> afterReplay(String id) => clearDraft(id);

  /// A queued submit failed on replay: remember why, for the banner/flag.
  Future<void> afterReplayFailed(String id, ReplayFailure failure) async {
    final draft = await readDraft(id);
    if (draft == null) return;
    await _writeDraft(
      id,
      draft.withIssue(
        InspectionSendIssue(
          status: failure.status,
          code: failure.code,
          dropped: failure.outcome == FlushOutcome.drop,
        ),
      ),
    );
  }

  static List<String> _missingFrom(dynamic body) {
    final raw = body is Map ? body['missingFields'] : null;
    return raw is List ? [for (final m in raw) m.toString()] : const [];
  }

  static String? _codeOf(dynamic body) {
    final code = body is Map ? body['code'] : null;
    return code is String && code.isNotEmpty ? code : null;
  }

  /// Photo/signature fields upload immediately (same limitation the web
  /// FormRenderer has today — see LEARNINGS on the client repo) rather than
  /// riding `syncRequest`'s single-attachment queue slot, since one
  /// inspection can carry several media fields in one submit. Throws
  /// `NetworkFailure` offline; the form screen surfaces that as "not
  /// uploaded yet" for just that field, the rest of the form stays usable.
  Future<String> uploadMedia(Uint8List bytes, String fileName) =>
      _sync.uploadBytes(bytes: bytes, fileName: fileName, field: 'image');
}
