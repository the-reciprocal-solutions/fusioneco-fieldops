import 'dart:convert';

/// Where one inspection submission is on its way to the server, in the terms
/// a technician cares about (2026-10-06 iPhone report "inspections are not
/// getting submitted"). Before this, the form said either "Inspection
/// Submitted", "Saved — Will Sync / You're offline" or "Failed to submit
/// this inspection. Please try again." — the last one for every refusal,
/// including the server's location check-in gate (428), which no amount of
/// tapping Submit again could get past.
enum InspectionSendState {
  /// The queue is sending it right now.
  sending,

  /// Queued; nothing has gone wrong yet (usually no signal).
  waiting,

  /// Queued behind the location check-in (HTTP 428). Sends after check-in.
  waitingCheckIn,

  /// Queued; the session expired (401). Sends after the next sign-in.
  waitingSignIn,

  /// Queued; the server failed (5xx). Retries on its own.
  retrying,

  /// Not queued and not on the server: the server refused it. The answers
  /// are kept on the phone; only a Submit/Retry tap sends them again.
  notSent;

  bool get isQueued => this != InspectionSendState.notSent;
}

class InspectionSendStatus {
  const InspectionSendStatus(this.state, {this.reasonKey});

  final InspectionSendState state;

  /// i18n key of the plain-words reason, null when there is nothing to add.
  final String? reasonKey;

  /// Short label for a list flag / banner title.
  String get labelKey => switch (state) {
    InspectionSendState.sending => 'inspection.send.sending',
    InspectionSendState.notSent => 'inspection.send.not_sent',
    _ => 'inspection.send.waiting',
  };
}

/// Why the last attempt to send a submission did not land.
class InspectionSendIssue {
  const InspectionSendIssue({
    required this.status,
    this.code,
    this.dropped = false,
    this.missing = const [],
  });

  /// HTTP status; 0 when the server never gave one.
  final int status;
  final String? code;

  /// true: the server refused it for good (4xx) and it left the queue.
  final bool dropped;

  /// Field labels the server reported as missing (400 `missingFields`).
  final List<String> missing;

  Map<String, dynamic> toJson() => {
    'status': status,
    'code': ?code,
    'dropped': dropped,
    if (missing.isNotEmpty) 'missing': missing,
  };

  static InspectionSendIssue? fromJson(Object? json) {
    if (json is! Map) return null;
    final status = json['status'];
    return InspectionSendIssue(
      status: status is int ? status : int.tryParse('$status') ?? 0,
      code: json['code'] as String?,
      dropped: json['dropped'] == true,
      missing: json['missing'] is List
          ? [for (final m in json['missing'] as List) m.toString()]
          : const [],
    );
  }
}

/// The answers a submission carried, kept on the phone until the server has
/// them — so leaving the form after "Waiting to send" never loses work, and a
/// refused replay can be retried from the form.
class InspectionSubmitDraft {
  const InspectionSubmitDraft({
    required this.answers,
    required this.savedAt,
    this.issue,
  });

  final Map<String, dynamic> answers;
  final DateTime savedAt;
  final InspectionSendIssue? issue;

  InspectionSubmitDraft withIssue(InspectionSendIssue? issue) =>
      InspectionSubmitDraft(answers: answers, savedAt: savedAt, issue: issue);

  String encode() => jsonEncode({
    'answers': answers,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'issue': ?issue?.toJson(),
  });

  static InspectionSubmitDraft? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['answers'] is! Map) return null;
      return InspectionSubmitDraft(
        answers: Map<String, dynamic>.from(json['answers'] as Map),
        savedAt: DateTime.tryParse('${json['savedAt']}') ?? DateTime.now(),
        issue: InspectionSendIssue.fromJson(json['issue']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// [queued]: a submit for this inspection is in the offline queue.
/// [flushing]: the queue is draining right now.
/// [serverStatus]: the assignment's status as last read from the server; a
/// refusal is only worth showing while the server still has it `pending`.
InspectionSendStatus? inspectionSendStatus({
  required bool queued,
  required bool flushing,
  InspectionSubmitDraft? draft,
  String? serverStatus,
}) {
  final issue = draft?.issue;
  if (queued) {
    if (issue == null || issue.dropped) {
      return flushing
          ? const InspectionSendStatus(InspectionSendState.sending)
          : const InspectionSendStatus(
              InspectionSendState.waiting,
              reasonKey: 'inspection.send.waiting_hint',
            );
    }
    if (issue.status == 428) {
      return const InspectionSendStatus(
        InspectionSendState.waitingCheckIn,
        reasonKey: 'inspection.send.checkin_hint',
      );
    }
    if (issue.status == 401) {
      return const InspectionSendStatus(
        InspectionSendState.waitingSignIn,
        reasonKey: 'inspection.send.signin_hint',
      );
    }
    if (flushing) return const InspectionSendStatus(InspectionSendState.sending);
    return const InspectionSendStatus(
      InspectionSendState.retrying,
      reasonKey: 'inspection.send.retrying_hint',
    );
  }
  if (issue != null && issue.dropped && (serverStatus == null || serverStatus == 'pending')) {
    return InspectionSendStatus(
      InspectionSendState.notSent,
      reasonKey: refusedReasonKey(issue.status),
    );
  }
  return null;
}

/// Plain words for a refusal. The server's own message is not shown: some
/// of them are written for developers ("POST your current position to …").
String refusedReasonKey(int status) => switch (status) {
  400 => 'inspection.send.refused_missing_fields',
  403 => 'inspection.send.refused_access',
  404 => 'inspection.send.refused_missing',
  409 || 410 => 'inspection.send.refused_expired',
  413 => 'inspection.send.refused_too_large',
  _ => 'inspection.send.refused_hint',
};
