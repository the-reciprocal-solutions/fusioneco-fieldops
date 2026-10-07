import '../../app/router.dart';

/// Where a conversation, agent-session or schedule notification opens in
/// this app (docs/conversations-and-schedules.md "Notifications").
///
/// The server (`services/conversations/notify.ts`) stamps
/// `entityType = conversation:<entity>:<mention|reply|message>`,
/// `entityId` = the record UUID, and a **web admin** link such as
/// `/facility-management/snags?snag=<id>&message=<mid>`. The generic
/// notification router drops any link outside `/technician`, so without this
/// every conversation push would open nothing. Called first by
/// `routeForNotificationFields` (notification_route.dart), the one routing
/// rule the in-app list and a tray tap both use.
///
/// Schedules / sessions (orchestrator spec: `schedule:started|done|failed`,
/// `session:started|done`) open their origin thread when the link names one,
/// otherwise My schedules.
///
/// Returns null when the notification is none of these, so the caller's
/// usual rules run.
String? conversationRouteFor({String? entityType, String? entityId, String? link}) {
  final type = entityType?.trim() ?? '';
  final id = entityId?.trim() ?? '';
  final messageId = messageIdFromLink(link);

  if (type.startsWith('conversation:')) {
    final parts = type.split(':');
    final entity = parts.length > 1 ? parts[1] : '';
    if (entity.isEmpty) return null;
    if (id.isEmpty) return threadRouteForWebLink(link);
    return threadRoute(entity, id, messageId: messageId);
  }

  final isSchedule = type == 'schedule' ||
      type.startsWith('schedule:') ||
      type == 'user_schedule' ||
      type == 'UserSchedule';
  final isSession = type.startsWith('session:') || type == 'agent_session';
  if (isSchedule || isSession) {
    final fromLink = threadRouteForWebLink(link);
    if (fromLink != null) return fromLink;
    // A `/technician/...` link maps 1:1 like every other technician link.
    final l = link?.trim() ?? '';
    if (l.startsWith('/technician/')) return l.substring('/technician'.length);
    if (isSchedule) return Routes.schedules(focus: id.isEmpty ? null : id);
    return null;
  }
  return null;
}

/// The in-app thread for a record. Work orders open their detail screen on
/// the Comments tab (the thread lives there); every other record opens the
/// stand-alone thread screen, which links back to the record.
String threadRoute(String entity, String id, {String? messageId}) => switch (entity) {
  'work_order' => Routes.orderConversation(id, messageId: messageId),
  _ => Routes.conversation(entity, id, messageId: messageId),
};

/// `message=<id>` from a server link, if any.
String? messageIdFromLink(String? link) {
  final l = link?.trim();
  if (l == null || l.isEmpty) return null;
  final uri = Uri.tryParse(l);
  final m = uri?.queryParameters['message']?.trim();
  return m == null || m.isEmpty ? null : m;
}

/// Maps the server's web record links (`recordHref` in
/// `services/conversations/records.ts`) onto this app's thread routes.
String? threadRouteForWebLink(String? link) {
  final l = link?.trim();
  if (l == null || l.isEmpty) return null;
  final uri = Uri.tryParse(l);
  if (uri == null) return null;
  final seg = uri.pathSegments;
  final message = uri.queryParameters['message'];
  if (seg.length < 2 || seg.first != 'facility-management') return null;
  String? at(int i) => seg.length > i && seg[i].isNotEmpty ? seg[i] : null;
  switch (seg[1]) {
    case 'snags':
      final id = uri.queryParameters['snag'] ?? at(2);
      return id == null ? null : threadRoute('snag', id, messageId: message);
    case 'work-order':
      final id = at(2) == 'view' ? at(3) : at(2);
      return id == null ? null : threadRoute('work_order', id, messageId: message);
    case 'reactive-maintenance':
      final id = at(2);
      return id == null ? null : threadRoute('service_request', id, messageId: message);
    case 'preventive-maintenance':
      final id = at(2);
      return id == null ? null : threadRoute('pm_plan', id, messageId: message);
    case 'permits':
      final id = at(2);
      return id == null ? null : threadRoute('permit', id, messageId: message);
    case 'assets':
      final id = at(2) == 'view' ? at(3) : at(2);
      return id == null ? null : threadRoute('asset', id, messageId: message);
    case 'inspections':
      // /facility-management/inspections/<templateId>/responses/<id>
      final id = at(3) == 'responses' ? at(4) : null;
      return id == null ? null : threadRoute('inspection_response', id, messageId: message);
  }
  return null;
}

/// Which family a notification belongs to, for its icon and colour in the
/// in-app list.
enum NoticeFamily { agentReply, mention, conversation, scheduleStarted, scheduleDone, scheduleFailed, other }

/// True for families that come from an AI teammate (violet in the list).
bool isAiNotice(NoticeFamily f) => f != NoticeFamily.mention && f != NoticeFamily.conversation && f != NoticeFamily.other;

NoticeFamily noticeFamily(String? entityType, {String? category}) {
  final t = entityType?.trim() ?? '';
  if (t.startsWith('conversation:')) {
    if (t.endsWith(':mention')) return NoticeFamily.mention;
    // notify.ts: category `ai_conversation` when an agent wrote it, `user`
    // when a person did (a person answering your message is also `:reply`).
    if (category == 'ai_conversation') return NoticeFamily.agentReply;
    return NoticeFamily.conversation;
  }
  if (t.startsWith('schedule:') || t.startsWith('session:')) {
    if (t.endsWith(':failed')) return NoticeFamily.scheduleFailed;
    if (t.endsWith(':done')) return NoticeFamily.scheduleDone;
    return NoticeFamily.scheduleStarted;
  }
  return NoticeFamily.other;
}
