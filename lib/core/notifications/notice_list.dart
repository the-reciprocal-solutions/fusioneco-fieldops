import '../../domain/app_notification.dart';
import '../push/push_content.dart';

/// Pure helpers behind the notifications screen (tested in
/// `test/notice_list_test.dart`): which tab a row is in, the per-tab counts,
/// the "Today / Earlier" split and the short relative time.

/// Per tab: how many, and how many unread.
typedef GroupCount = ({int total, int unread});

/// Counts what is loaded. The screen prefers the server's `groupCounts`
/// (which covers everything, not just the loaded page) when it has them.
Map<NoticeGroup, GroupCount> countByGroup(Iterable<AppNotification> items) {
  final out = {for (final g in NoticeGroup.values) g: (total: 0, unread: 0)};
  for (final n in items) {
    if (n.archived) continue;
    final c = out[n.group]!;
    out[n.group] = (total: c.total + 1, unread: c.unread + (n.isRead ? 0 : 1));
  }
  return out;
}

/// The rows of one tab ([group] null = All), archived ones left out.
List<AppNotification> inGroup(Iterable<AppNotification> items, NoticeGroup? group) =>
    [for (final n in items) if (!n.archived && (group == null || n.group == group)) n];

enum NoticeSection { today, earlier }

/// "Today" is the technician's local calendar day.
NoticeSection sectionOf(DateTime? createdAt, DateTime now) {
  if (createdAt == null) return NoticeSection.earlier;
  final t = createdAt.toLocal();
  final n = now.toLocal();
  return t.year == n.year && t.month == n.month && t.day == n.day ? NoticeSection.today : NoticeSection.earlier;
}

/// The rows split into Today and Earlier, each newest first; an empty
/// section is left out.
List<({NoticeSection section, List<AppNotification> items})> sectioned(List<AppNotification> items, DateTime now) {
  final today = <AppNotification>[];
  final earlier = <AppNotification>[];
  for (final n in items) {
    (sectionOf(n.createdAt, now) == NoticeSection.today ? today : earlier).add(n);
  }
  int newestFirst(AppNotification a, AppNotification b) =>
      (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
  today.sort(newestFirst);
  earlier.sort(newestFirst);
  return [
    if (today.isNotEmpty) (section: NoticeSection.today, items: today),
    if (earlier.isNotEmpty) (section: NoticeSection.earlier, items: earlier),
  ];
}

/// A relative time as an i18n key plus its number: `now`, `minutes` (n),
/// `hours` (n), `yesterday`, `days` (n, under a week) or `date` (show the date).
({String key, int n}) relativeTimeOf(DateTime? at, DateTime now) {
  if (at == null) return (key: 'date', n: 0);
  final diff = now.difference(at);
  if (diff.inMinutes < 1) return (key: 'now', n: 0);
  if (diff.inMinutes < 60) return (key: 'minutes', n: diff.inMinutes);
  if (sectionOf(at, now) == NoticeSection.today) return (key: 'hours', n: diff.inHours);
  final l = at.toLocal();
  final yesterday = now.toLocal().subtract(const Duration(days: 1));
  if (l.year == yesterday.year && l.month == yesterday.month && l.day == yesterday.day) {
    return (key: 'yesterday', n: 1);
  }
  if (diff.inDays < 7) return (key: 'days', n: diff.inDays < 2 ? 2 : diff.inDays);
  return (key: 'date', n: 0);
}

/// The quick actions a card in the list can offer — the same rules as the
/// tray buttons, minus the ones that only make sense in a tray (Mark read is
/// a swipe here; Open is the tap).
List<PushAction> cardActionsFor(AppNotification n) {
  final actions = pushActionsFor(n.asPushData());
  return [
    for (final a in actions)
      if (a == PushAction.acceptInvite || a == PushAction.declineInvite || a == PushAction.reply || a == PushAction.scan) a,
  ];
}
