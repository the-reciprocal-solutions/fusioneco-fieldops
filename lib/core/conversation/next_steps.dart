import '../../app/router.dart';
import '../../domain/conversation.dart';

/// Pure rules for replying to an agent and for the one-tap next steps under
/// its answer (docs/conversations-and-schedules.md "Replying to an agent").

/// Where a next step goes. Every one OPENS a screen with the record
/// pre-filled — raising the snag still needs the technician to save it, and
/// nothing here approves an agent's suggestion (that stays Admin-only).
String routeForNextStep(ConvNextStep s) => switch (s.action) {
  ConvNextStepAction.raiseSnag => Routes.snagNew(
    buildingId: s.target['buildingId'],
    assetId: s.target['assetId'],
    assetName: s.target['assetName'],
    assetReferenceId: s.target['assetRef'],
    workOrderId: s.target['workOrderId'],
  ),
  ConvNextStepAction.openAsset => Routes.assetDetail(s.target['assetId'] ?? ''),
  ConvNextStepAction.openPermits => Routes.permits,
};

/// The i18n key for a next step's chip.
String nextStepLabelKey(ConvNextStepAction a) => switch (a) {
  ConvNextStepAction.raiseSnag => 'conv.next.raise_snag',
  ConvNextStepAction.openAsset => 'conv.next.open_asset',
  ConvNextStepAction.openPermits => 'conv.next.open_permits',
};

/// True when a plain reply to [replyingTo] (no `@agent` typed) goes to the
/// agent: the server continues with the agent whose message it is (a reply
/// under its answer — services/conversations/continuation.ts). Only a hint
/// for the composer; the server decides.
bool replyReachesAgent(ConvMessage? replyingTo, {required bool canMentionAgents}) =>
    canMentionAgents && replyingTo != null && replyingTo.isAgent && !replyingTo.isDeleted;
