import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../../domain/maintenance_record.dart';

/// Shows a queued write's label in the app's language.
///
/// Repositories store the label in English (it is also used in logs, and
/// writes queued before this existed are already in the database that way),
/// so the translation happens here, when the label is drawn. A label this
/// table doesn't know is shown as it was stored.
String mutationLabelText(BuildContext context, String raw) {
  final key = _exact[raw];
  if (key != null) return key.getString(context);

  String fmt(String k, List<Object> args) => context.formatString(k.getString(context), args);

  var m = _close.firstMatch(raw);
  if (m != null) {
    final type = OrderType.values.where((t) => t.label.toLowerCase() == m!.group(1)).firstOrNull;
    if (type != null) return fmt('sync.label.close', [type.displayLabel(context)]);
  }
  m = _message.firstMatch(raw);
  if (m != null) return fmt('sync.label.message', [m.group(1)!]);
  m = _snag.firstMatch(raw);
  if (m != null) {
    final what = _snagWhat[m.group(2)];
    if (what != null) return fmt('sync.label.snag', [m.group(1)!, what.getString(context)]);
  }
  m = _room.firstMatch(raw);
  if (m != null) return fmt('sync.label.room_checked', [m.group(1)!]);
  m = _arProgress.firstMatch(raw);
  if (m != null) {
    final status = m.group(2)!;
    final statusKey = 'ar.progress.status.$status';
    final shown = _arStatuses.contains(status) ? statusKey.getString(context) : status;
    return fmt('sync.label.ar_progress', [m.group(1)!, shown]);
  }
  m = _arSave.firstMatch(raw);
  if (m != null) return fmt('sync.label.ar_save_board', [m.group(1)!]);
  m = _arInstalled.firstMatch(raw);
  if (m != null) return fmt('sync.label.ar_board_installed', [m.group(1)!]);
  return raw;
}

const _exact = <String, String>{
  'Accept assignment': 'sync.label.accept_assignment',
  'Decline assignment': 'sync.label.decline_assignment',
  'Report tag issue': 'sync.label.report_tag_issue',
  'Checklist item': 'sync.label.checklist_item',
  'Start task timer': 'sync.label.start_task_timer',
  'Stop task timer': 'sync.label.stop_task_timer',
  'Checklist note': 'sync.label.checklist_note',
  'Checklist voice note': 'sync.label.checklist_voice_note',
  'Checklist photo': 'sync.label.checklist_photo',
  'Remove checklist photo': 'sync.label.remove_checklist_photo',
  'Remove voice note': 'sync.label.remove_voice_note',
  'Work order voice note': 'sync.label.work_order_voice_note',
  'Add other task': 'sync.label.add_other_task',
  'Technician signature': 'sync.label.technician_signature',
  'Root cause': 'sync.label.root_cause',
  'Downtime': 'sync.label.downtime',
  'Start of day': 'sync.label.start_of_day',
  'End of day': 'sync.label.end_of_day',
  'Submit asset verification': 'sync.label.submit_asset_verification',
  'Inspection submission': 'sync.label.inspection_submission',
  'Sign on to permit': 'sync.label.permit_sign_on',
  'Sign off permit': 'sync.label.permit_sign_off',
  'Record gas test': 'sync.label.record_gas_test',
  'Apply isolation': 'sync.label.apply_isolation',
  'Verify isolation': 'sync.label.verify_isolation',
  'Restore isolation': 'sync.label.restore_isolation',
  'Stop work': 'sync.label.stop_work',
  'Mark work complete': 'sync.label.mark_work_complete',
  'Sign off fire watch': 'sync.label.sign_off_fire_watch',
  'Permit comment': 'sync.label.permit_comment',
  'Raise snag': 'sync.label.raise_snag',
  'Raise snag (retry)': 'sync.label.raise_snag_retry',
  'Start snag survey': 'sync.label.start_snag_survey',
  'Complete snag survey': 'sync.label.complete_snag_survey',
  'AR session log': 'sync.label.ar_session_log',
};

const _snagWhat = <String, String>{
  'start': 'snags.action.start',
  'ready': 'snags.action.ready',
  'verify': 'snags.action.verify',
  'reject': 'snags.action.reject',
  'reopen': 'snags.action.reopen',
  'waive': 'sync.label.snag_waive',
  'comment': 'sync.label.snag_comment',
  'photo': 'sync.label.snag_photo',
  'also seen': 'sync.label.snag_also_seen',
};

const _arStatuses = {'installed', 'issue', 'not_started', 'verified'};

final _close = RegExp(r'^Close (.+)$');
final _message = RegExp(r'^Message: (.*)$', dotAll: true);
final _snag = RegExp(r'^Snag (.+?): (start|ready|verify|reject|reopen|waive|comment|photo|also seen)$');
final _room = RegExp(r'^Room checked: (.*)$');
final _arProgress = RegExp(r'^AR progress: (\d+) × (.+)$');
final _arSave = RegExp(r'^AR: save board (.*)$');
final _arInstalled = RegExp(r'^AR: board (.*) installed$');
