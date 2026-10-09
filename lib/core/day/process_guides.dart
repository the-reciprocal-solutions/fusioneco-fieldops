import '../../app/router.dart';

/// "How do I…?" — short step guides for the app's real processes, shown from
/// the home screen's Your day card (docs/day-brief.md §Guides).
///
/// Every step was written from the screens themselves (button labels are the
/// `en.json` strings those screens use), not from memory — when a flow
/// changes, change its guide in the same task. Each guide has a screen to
/// open ("Open this screen", must exist in router.dart — a test checks every
/// one) and a question to prefill in the order assistant ("Ask AI about it").
class ProcessGuide {
  const ProcessGuide({
    required this.id,
    required this.stepCount,
    required this.route,
  });

  final String id;

  /// Steps are `day.guide.<id>.step<n>` for n = 1…[stepCount].
  final int stepCount;

  /// The screen this guide is about. [nextJobId] is the next open work order
  /// on today's plan, when there is one — some guides open that job.
  final String Function({String? nextJobId}) route;

  String get titleKey => 'day.guide.$id.title';
  String get askKey => 'day.guide.$id.ask';
  List<String> get stepKeys => [for (var i = 1; i <= stepCount; i++) 'day.guide.$id.step$i'];
}

final List<ProcessGuide> kProcessGuides = [
  // order_detail_screen.dart (offer panel, Tasks tab), checklist_item_sheet.dart
  // (Start Timer / Pause / Mark Complete), verification_sheet.dart
  // ("Start task now"), checklist_tab.dart ("Completed Works"), close_sheet.dart
  // (1 downtime · 2 root cause · 3 sign off → "Confirm & close").
  ProcessGuide(
    id: 'work_order',
    stepCount: 6,
    route: ({String? nextJobId}) => nextJobId == null ? Routes.orders : Routes.orderDetail('work-order', nextJobId),
  ),
  // inspection_list_screen.dart → inspection_form_screen.dart ("Fetch GPS
  // Location", Start/Stop timer, "Add Signature" → "Lock Signature",
  // "Submit Inspection", queued send states).
  ProcessGuide(id: 'inspection', stepCount: 5, route: ({String? nextJobId}) => Routes.inspections),
  // snag_hub_screen.dart ("Quick snag", "Start walk"), snag_raise_screen.dart
  // (photo required, What / Where, "Raise snag"), snag_walk_screen.dart
  // ("Take a snag photo", "Save & next", "Room clear", "Finish"), duplicate guard.
  ProcessGuide(id: 'snag', stepCount: 5, route: ({String? nextJobId}) => Routes.snags),
  // permits_hub_screen.dart ("Scan worksite QR"), permit_detail_screen.dart,
  // sheets/sign_on_sheet.dart (briefing ack + signature), sheets/gas_test_sheet.dart
  // (O2 → LEL, H2S, CO; "Save gas test"; a fail suspends), stop_work_sheet.dart.
  ProcessGuide(id: 'permit', stepCount: 5, route: ({String? nextJobId}) => Routes.permits),
  // widgets/location_checkin_gate.dart (24 h, "Share Location"), state/checkin_controller.dart
  // (resumes the queue), verification_sheet.dart (location at timer start).
  ProcessGuide(id: 'checkin', stepCount: 4, route: ({String? nextJobId}) => Routes.syncCenter),
  // scanner_screen.dart (asset tag → "Asset found" / "Tag not recognised";
  // AR board codes → Routes.arMarker), ar_entry_widgets.dart ("Scan a board").
  ProcessGuide(id: 'scan', stepCount: 5, route: ({String? nextJobId}) => Routes.scan),
  // docs/conversations-and-schedules.md: @agent, "Answer", Reply continues
  // with the agent ("thanks"/"ok" don't wake it), next-step chips only open
  // a screen, "@agent remind me…" → My schedules.
  ProcessGuide(
    id: 'agent',
    stepCount: 5,
    route: ({String? nextJobId}) => nextJobId == null ? Routes.schedules() : Routes.orderConversation(nextJobId),
  ),
];
