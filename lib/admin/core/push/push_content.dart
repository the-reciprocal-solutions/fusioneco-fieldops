/// What a push is about, read from its FCM data (all values are strings).
/// Pure, so the routing rule is unit-tested.
///
/// Two kinds reach this app (server, FE-mobile.md 0.4):
///   - the alert fan-out (services/alerts/mobilePush.ts):
///     `kind: alert`, `alertKey`, `buildingId`, `severity`, `reason`
///   - any bell notification to this user (services/notificationService.ts),
///     e.g. alert routing's "Assigned to you": `link: /alerts?alert=<key>`,
///     `entityType: alert` — or something else entirely (a WO, a snag…).
sealed class PushTarget {
  const PushTarget();
}

class AlertTarget extends PushTarget {
  const AlertTarget(this.key);
  final String key;

  @override
  bool operator ==(Object other) => other is AlertTarget && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// Anything else: the notifications list.
class NotificationsTarget extends PushTarget {
  const NotificationsTarget();

  @override
  bool operator ==(Object other) => other is NotificationsTarget;
  @override
  int get hashCode => 0;
}

String? _s(Object? v) {
  final t = v?.toString().trim() ?? '';
  return t.isEmpty ? null : t;
}

PushTarget pushTargetOf(Map<String, dynamic> data) {
  final key = _s(data['alertKey']);
  if (key != null) return AlertTarget(key);
  final link = _s(data['link']);
  if (link != null) {
    final uri = Uri.tryParse(link);
    final fromLink = uri?.queryParameters['alert'];
    if (uri != null && uri.path == '/alerts' && fromLink != null && fromLink.isNotEmpty) return AlertTarget(fromLink);
  }
  return const NotificationsTarget();
}

/// Alerts get their own channels (critical ones louder); the rest is "Updates".
/// The alert fan-out says `severity`; routing's bell push ("Critical alert: …")
/// has no severity, only `type`, which is `error` for a critical alert
/// (server services/alerts/router.ts `notifType`).
String channelIdFor(Map<String, dynamic> data) {
  final isAlert = pushTargetOf(data) is AlertTarget;
  final critical = data['severity'] == 'critical' || data['priority'] == 'critical' || data['type'] == 'error';
  if (isAlert) return critical ? 'fe_alerts_critical' : 'fe_alerts';
  return 'fe_updates';
}
