import '../../domain/conversation.dart';

/// Pure layout of a conversation: which rows the list draws, in order
/// (docs/conversations-and-schedules.md). Kept out of the widget so the
/// rules — day dividers, the unread divider, who gets a header, and
/// one-level replies — are unit-tested.

sealed class ThreadItem {
  const ThreadItem();
}

class DayDivider extends ThreadItem {
  const DayDivider(this.day);
  final DateTime day;
}

class UnreadDivider extends ThreadItem {
  const UnreadDivider(this.count);
  final int count;
}

class MessageItem extends ThreadItem {
  const MessageItem({required this.message, required this.showHeader, this.parent, this.parentMissing = false});
  final ConvMessage message;

  /// First of a run by the same author: draw the avatar and name.
  final bool showHeader;

  /// The message this one answers (one level only).
  final ConvMessage? parent;

  /// It answers a message older than the loaded page.
  final bool parentMissing;
}

/// Consecutive messages by one author inside this window share one header.
const kGroupWindow = Duration(minutes: 5);

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// True when [m] was written by the signed-in person — by the server's
/// `mine` flag (GET/POST) or, for socket events where `mine` is always false,
/// by author id against [myIds] (a technician may be known by user id or
/// technician id).
bool isMine(ConvMessage m, Set<String> myIds) =>
    m.mine || m.isLocal || (!m.isAgent && m.author.id.isNotEmpty && myIds.contains(m.author.id));

/// The rows for [messages] (oldest first). [lastReadAt] is where this person
/// had read up to before opening the thread; messages by others after it sit
/// below an unread divider.
List<ThreadItem> layoutThread(
  List<ConvMessage> messages, {
  DateTime? lastReadAt,
  Set<String> myIds = const {},
  Duration groupWindow = kGroupWindow,
}) {
  final byId = {for (final m in messages) m.id: m};
  final items = <ThreadItem>[];
  DateTime? lastDay;
  ConvMessage? prev;
  var unreadPlaced = lastReadAt == null;
  final unreadCount = lastReadAt == null
      ? 0
      : messages.where((m) => m.createdAt.isAfter(lastReadAt) && !isMine(m, myIds)).length;

  for (final m in messages) {
    final day = _day(m.createdAt);
    var breakGroup = false;
    if (lastDay == null || day != lastDay) {
      items.add(DayDivider(day));
      lastDay = day;
      breakGroup = true;
    }
    if (!unreadPlaced && unreadCount > 0 && m.createdAt.isAfter(lastReadAt!) && !isMine(m, myIds)) {
      items.add(UnreadDivider(unreadCount));
      unreadPlaced = true;
      breakGroup = true;
    }
    final parent = m.replyTo == null ? null : byId[m.replyTo];
    final showHeader = breakGroup ||
        prev == null ||
        prev.author.id != m.author.id ||
        prev.author.type != m.author.type ||
        m.createdAt.difference(prev.createdAt).abs() > groupWindow ||
        m.replyTo != null ||
        m.kind != ConvMessageKind.message ||
        prev.kind != ConvMessageKind.message;
    items.add(MessageItem(
      message: m,
      showHeader: showHeader,
      parent: parent,
      parentMissing: m.replyTo != null && parent == null,
    ));
    prev = m;
  }
  return items;
}

/// Replies are one level deep (spec): answering a reply answers its parent.
String replyTargetFor(ConvMessage m) => m.replyTo ?? m.id;

/// Server messages plus this phone's unsent ones. A local message whose
/// `clientId` the server already echoed is dropped (the server copy wins);
/// the rest go after the server's, oldest first.
List<ConvMessage> mergeWithLocal(List<ConvMessage> server, List<ConvMessage> local) {
  final echoed = {for (final m in server) ?m.clientId};
  final pending = local.where((m) => m.clientId == null || !echoed.contains(m.clientId)).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return [...server, ...pending];
}

/// Inserts or replaces [incoming] by id (a socket `message.created` /
/// `message.updated`, or a POST answer), keeping oldest-first order.
List<ConvMessage> upsertMessage(List<ConvMessage> list, ConvMessage incoming) {
  final i = list.indexWhere((m) => m.id == incoming.id);
  if (i >= 0) {
    final next = [...list];
    // A socket echo says `mine: false` on the wire; keep what the GET said.
    next[i] = incoming.mine || !list[i].mine ? incoming : incoming.copyWith(mine: true);
    return next;
  }
  final next = [...list, incoming]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return next;
}
