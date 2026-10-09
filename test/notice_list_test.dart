import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/notifications/notice_list.dart';
import 'package:technician_portal/core/push/push_content.dart';
import 'package:technician_portal/data/notifications_repository.dart';
import 'package:technician_portal/domain/app_notification.dart';

AppNotification _n(
  String id, {
  String? entityType,
  String? category,
  bool read = false,
  DateTime? at,
  String title = 't',
  String type = 'info',
  String? entityId = 'e1',
}) =>
    AppNotification(
      id: id,
      title: title,
      message: '',
      type: type,
      entityType: entityType,
      entityId: entityId,
      category: category,
      isRead: read,
      createdAt: at,
    );

void main() {
  final now = DateTime(2026, 10, 10, 15, 30);

  group('grouping', () {
    final items = [
      _n('1', entityType: 'WorkOrder'),
      _n('2', entityType: 'Snag', read: true),
      _n('3', entityType: 'Snag'),
      _n('4', entityType: 'PermitToWork'),
      _n('5', entityType: 'conversation:snag:mention'),
      _n('6', entityType: 'schedule:done'),
      _n('7', entityType: 'Technician'),
      _n('8', entityType: 'room_booking', category: 'ops'),
      _n('9', entityType: null, category: 'ai_conversation'),
    ];

    test('each row lands in its tab', () {
      expect(inGroup(items, NoticeGroup.snags).map((n) => n.id), ['2', '3']);
      expect(inGroup(items, NoticeGroup.messages).map((n) => n.id), ['5', '9']);
      expect(inGroup(items, NoticeGroup.system).map((n) => n.id), ['7', '8']);
      expect(inGroup(items, null), hasLength(9));
    });

    test('counts per tab with unread', () {
      final c = countByGroup(items);
      expect(c[NoticeGroup.snags], (total: 2, unread: 1));
      expect(c[NoticeGroup.work], (total: 1, unread: 1));
      expect(c[NoticeGroup.permits], (total: 1, unread: 1));
      expect(c[NoticeGroup.schedules], (total: 1, unread: 1));
    });

    test("the server's group wins over the derived one", () {
      const n = AppNotification(id: 'x', title: 't', message: '', type: 'info', entityType: 'WorkOrder', groupWire: 'permits');
      expect(n.group, NoticeGroup.permits);
    });

    test('archived rows are left out', () {
      final archived = _n('a', entityType: 'Snag').copyWith(archived: true);
      expect(inGroup([archived], null), isEmpty);
      expect(countByGroup([archived])[NoticeGroup.snags], (total: 0, unread: 0));
    });
  });

  group('Today / Earlier', () {
    test('split by the local calendar day, newest first, empty sections dropped', () {
      final s = sectioned([
        _n('old', at: DateTime(2026, 10, 8, 9)),
        _n('morning', at: DateTime(2026, 10, 10, 8)),
        _n('noon', at: DateTime(2026, 10, 10, 12)),
        _n('none'),
      ], now);
      expect(s.map((x) => x.section), [NoticeSection.today, NoticeSection.earlier]);
      expect(s.first.items.map((n) => n.id), ['noon', 'morning']);
      expect(s.last.items.map((n) => n.id), ['old', 'none']);
      expect(sectioned([_n('old', at: DateTime(2026, 1, 1))], now).single.section, NoticeSection.earlier);
    });
  });

  group('relative time', () {
    test('now, minutes, hours, yesterday, days, date', () {
      expect(relativeTimeOf(now.subtract(const Duration(seconds: 20)), now).key, 'now');
      expect(relativeTimeOf(now.subtract(const Duration(minutes: 5)), now), (key: 'minutes', n: 5));
      expect(relativeTimeOf(DateTime(2026, 10, 10, 9), now), (key: 'hours', n: 6));
      expect(relativeTimeOf(DateTime(2026, 10, 9, 23), now).key, 'yesterday');
      expect(relativeTimeOf(DateTime(2026, 10, 6, 10), now), (key: 'days', n: 4));
      expect(relativeTimeOf(DateTime(2026, 9, 1), now).key, 'date');
      expect(relativeTimeOf(null, now).key, 'date');
    });
  });

  group('card quick actions', () {
    test('Accept/Decline on an invite, Reply on a thread, Scan on a route, nothing else', () {
      expect(
        cardActionsFor(_n('i', entityType: 'work_order', title: kInviteTitle)),
        [PushAction.acceptInvite, PushAction.declineInvite],
      );
      expect(cardActionsFor(_n('m', entityType: 'conversation:snag:message')), [PushAction.reply]);
      expect(cardActionsFor(_n('r', entityType: 'c2o_route_assignment')), [PushAction.scan]);
      expect(cardActionsFor(_n('w', entityType: 'WorkOrder')), isEmpty);
    });
  });

  group('server JSON', () {
    test('a v2 row: group, meta, archived', () {
      final n = AppNotification.fromJson({
        'id': 'n1',
        'title': 'Snag assigned',
        'message': 'm',
        'type': 'info',
        'entityType': 'Snag',
        'entityId': 's1',
        'group': 'snags',
        'meta': {'priority': 'high', 'imageUrl': 'https://x/a.jpg', 'ref': 'SN-1', 'location': 'L3', 'route': '/technician/snags/s1'},
        'archivedAt': null,
      });
      expect(n.group, NoticeGroup.snags);
      expect(n.priority, NoticePriority.high);
      expect(n.imageUrl, 'https://x/a.jpg');
      expect(n.ref, 'SN-1');
      expect(n.location, 'L3');
      expect(n.archived, isFalse);
    });

    test('an older row without meta still works', () {
      final n = AppNotification.fromJson({'id': 'n2', 'title': 'x', 'entityType': 'PermitToWork'});
      expect(n.group, NoticeGroup.permits);
      expect(n.imageUrl, isNull);
    });

    test('groupCounts parse', () {
      final c = NotificationsRepository.parseGroupCounts(jsonDecode('{"work":{"total":5,"unread":2},"snags":{"total":"3","unread":"0"}}'));
      expect(c[NoticeGroup.work], (total: 5, unread: 2));
      expect(c[NoticeGroup.snags], (total: 3, unread: 0));
      expect(NotificationsRepository.parseGroupCounts(null), isEmpty);
    });
  });

  test('every notifications.* key the screen uses exists in both languages', () {
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map;
    final ar = jsonDecode(File('assets/i18n/ar.json').readAsStringSync()) as Map;
    final keys = <String>{
      'notifications.tab_all',
      for (final g in NoticeGroup.values) ...[
        'notifications.group_${g.wire}',
        'notifications.empty_${g.wire}_title',
        'notifications.empty_${g.wire}_subtitle',
      ],
      'notifications.empty_all_title',
      'notifications.empty_all_subtitle',
    };
    final src = [
      'lib/features/notifications/notifications_screen.dart',
      'lib/features/notifications/notification_card.dart',
      'lib/features/notifications/notification_sheets.dart',
      'lib/features/notifications/notification_visuals.dart',
    ].map((p) => File(p).readAsStringSync()).join();
    keys.addAll(RegExp(r"'(notifications\.[a-z_]+)'").allMatches(src).map((m) => m.group(1)!));
    for (final k in keys) {
      expect(en.containsKey(k), isTrue, reason: 'en $k');
      expect(ar.containsKey(k), isTrue, reason: 'ar $k');
    }
  });
}
