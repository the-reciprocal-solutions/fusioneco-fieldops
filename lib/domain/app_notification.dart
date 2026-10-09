import '../core/network/envelope.dart';
import '../core/push/push_content.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    this.category,
    this.entityId,
    this.entityType,
    this.link,
    this.isSeen = false,
    this.isRead = false,
    this.createdAt,
    this.groupWire,
    this.priorityWire,
    this.imageUrl,
    this.ref,
    this.location,
    this.threadId,
    this.route,
    this.archived = false,
  });

  final String id;
  final String title;
  final String message;

  /// info | warning | success | error
  final String type;
  final String? category;
  final String? entityId;
  final String? entityType;
  final String? link;

  /// Seen means the bell was opened after it arrived; read means this one was
  /// opened. The badge counts unseen.
  final bool isSeen;
  final bool isRead;
  final DateTime? createdAt;

  // ── Extras (server 2026-10-10: `group` per row + `meta` from the
  // `app_notification_extras` side table). All optional: an older server
  // sends none and the app works them out from entityType/category/type.
  final String? groupWire;
  final String? priorityWire;

  /// A photo for the card (snag, finding…), absolute http(s).
  final String? imageUrl;

  /// Short record reference, e.g. "WO-0042".
  final String? ref;

  /// Where, e.g. "Tower A · Level 3".
  final String? location;
  final String? threadId;

  /// A `/technician/...` deep link for a type the app has no rule for.
  final String? route;
  final bool archived;

  /// The tab it belongs to (the server's, else derived like the server does).
  NoticeGroup get group =>
      NoticeGroup.fromWire(groupWire) ?? noticeGroupFor(entityType: entityType, category: category);

  NoticePriority get priority => pushPriorityOf(asPushData());

  /// The same fields as a push payload, so the list and the tray share
  /// one set of rules (kind, priority, actions).
  PushData asPushData() => PushData(
        title: title,
        body: message.isEmpty ? null : message,
        link: link,
        entityId: entityId,
        entityType: entityType,
        notificationId: id,
        type: type,
        category: category,
        group: NoticeGroup.fromWire(groupWire),
        priority: NoticePriority.fromWire(priorityWire),
        threadId: threadId,
        route: route,
        imageUrl: imageUrl,
        ref: ref,
        location: location,
      );

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'] is Map ? Map<String, dynamic>.from(json['meta'] as Map) : const <String, dynamic>{};
    String? str(Object? v) {
      final s = v?.toString().trim();
      return s == null || s.isEmpty ? null : s;
    }

    final image = str(meta['imageUrl']);
    return AppNotification(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      type: json['type']?.toString() ?? 'info',
      category: json['category']?.toString(),
      entityId: json['entityId']?.toString(),
      entityType: json['entityType']?.toString(),
      link: json['link']?.toString(),
      isSeen: asBool(json['isSeen']) ?? false,
      isRead: asBool(json['isRead']) ?? false,
      createdAt: asDate(json['createdAt']),
      groupWire: str(meta['group']) ?? str(json['group']),
      priorityWire: str(meta['priority']),
      imageUrl: image != null && RegExp(r'^https?://', caseSensitive: false).hasMatch(image) ? image : null,
      ref: str(meta['ref']),
      location: str(meta['location']),
      threadId: str(meta['threadId']),
      route: str(meta['route']),
      archived: json['archivedAt'] != null,
    );
  }

  AppNotification copyWith({bool? isSeen, bool? isRead, bool? archived}) => AppNotification(
        id: id,
        title: title,
        message: message,
        type: type,
        category: category,
        entityId: entityId,
        entityType: entityType,
        link: link,
        isSeen: isSeen ?? this.isSeen,
        isRead: isRead ?? this.isRead,
        createdAt: createdAt,
        groupWire: groupWire,
        priorityWire: priorityWire,
        imageUrl: imageUrl,
        ref: ref,
        location: location,
        threadId: threadId,
        route: route,
        archived: archived ?? this.archived,
      );
}
