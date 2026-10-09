import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/push/push_content.dart';
import 'package:technician_portal/data/notifications_repository.dart';
import 'package:technician_portal/domain/app_notification.dart';
import 'package:technician_portal/features/notifications/notification_card.dart';
import 'package:technician_portal/features/notifications/notifications_screen.dart';
import 'package:technician_portal/state/providers.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// The bell list on a small phone, in English and Arabic (RTL): tabs with
/// unread counts, Today / Earlier, swipe to read and to archive, and a type
/// with no screen opening its details sheet instead of nothing.
class _FakeRepo implements NotificationsRepository {
  _FakeRepo(this.rows, {this.counts = const {}});

  final List<AppNotification> rows;
  final Map<NoticeGroup, ({int total, int unread})> counts;
  final read = <String>[];
  final archived = <String>[];
  final allRead = <NoticeGroup?>[];

  @override
  Future<NotificationsPage> list({int limit = 10, NoticeGroup? group, bool unread = false}) async =>
      NotificationsPage(notifications: rows, unseenCount: 2, groupCounts: counts);

  @override
  Future<void> markAllSeen() async {}

  @override
  Future<void> markRead(String id) async => read.add(id);

  @override
  Future<void> markAllRead({NoticeGroup? group}) async => allRead.add(group);

  @override
  Future<void> archive(String id) async => archived.add(id);

  @override
  Future<void> unarchive(String id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

Map<String, dynamic> _strings(String lang) =>
    jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final now = DateTime.now();
  List<AppNotification> rows() => [
        AppNotification(
          id: 'n1',
          title: 'Scheduled job assigned to you',
          message: 'WO-0042 · Chiller 2. Due today.',
          type: 'info',
          entityType: 'WorkOrder',
          entityId: 'w1',
          link: '/technician/orders/work-order/w1',
          createdAt: now.subtract(const Duration(minutes: 5)),
          ref: 'WO-0042',
          location: 'Tower A · Level 3',
        ),
        AppNotification(
          id: 'n2',
          title: 'Snag assigned to you',
          message: 'Cracked tile near the lift lobby.',
          type: 'info',
          entityType: 'Snag',
          entityId: 's1',
          createdAt: now.subtract(const Duration(minutes: 30)),
          imageUrl: 'https://files.example.com/snag.jpg',
        ),
        AppNotification(
          id: 'n3',
          title: 'Finding raised from your check',
          message: 'The nameplate serial does not match the register.',
          type: 'warning',
          entityType: 'c2o_finding',
          entityId: 'f1',
          link: '/c2o/findings/f1',
          isRead: true,
          createdAt: now.subtract(const Duration(days: 3)),
        ),
        AppNotification(
          id: 'n4',
          title: 'Asha mentioned you on SN-00006',
          message: 'Can you check this today?',
          type: 'info',
          entityType: 'conversation:snag:mention',
          entityId: 's1',
          link: '/facility-management/snags?snag=s1&message=m1',
          createdAt: now.subtract(const Duration(days: 2)),
        ),
      ];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(
      mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))],
      initLanguageCode: 'en',
    );
  });

  Future<_FakeRepo> pump(WidgetTester tester, String lang, {Map<NoticeGroup, ({int total, int unread})> counts = const {}}) async {
    FlutterLocalization.instance.translate(lang);
    tester.view.physicalSize = const Size(375, 667) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _FakeRepo(rows(), counts: counts);
    await tester.pumpWidget(ProviderScope(
      overrides: [notificationsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
        locale: Locale(lang),
        home: const NotificationsScreen(),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return repo;
  }

  for (final lang in ['en', 'ar']) {
    testWidgets('tabs, counts, Today / Earlier, rich cards — $lang', (tester) async {
      final s = _strings(lang);
      await pump(tester, lang);
      expect(tester.takeException(), isNull);
      expect(find.text(s['notifications.tab_all'] as String), findsOneWidget);
      expect(find.text(s['notifications.group_snags'] as String), findsOneWidget);
      expect(find.text(s['notifications.section_today'] as String), findsOneWidget);
      expect(find.text(s['notifications.section_earlier'] as String), findsOneWidget);
      // 3 unread across all tabs; the record ref and location ride on the card.
      expect(find.text('3'), findsWidgets);
      expect(find.text('WO-0042'), findsOneWidget);
      expect(find.text('Tower A · Level 3'), findsOneWidget);
      // The mention offers Reply in place.
      expect(find.text(s['notifications.action_reply'] as String), findsOneWidget);
      if (lang == 'ar') {
        expect(Directionality.of(tester.element(find.byType(NotificationCard).first)), TextDirection.rtl);
      }
    });
  }

  testWidgets('a tab shows only its group', (tester) async {
    final s = _strings('en');
    await pump(tester, 'en');
    await tester.tap(find.text(s['notifications.group_snags'] as String));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(NotificationCard), findsNWidgets(2)); // the snag + the finding
    expect(find.text('Scheduled job assigned to you'), findsNothing);

    // The chips scroll sideways; Permits may be off-screen on a small phone.
    await tester.dragUntilVisible(
      find.text(s['notifications.group_permits'] as String),
      find.byType(ListView).first,
      const Offset(-120, 0),
    );
    await tester.ensureVisible(find.text(s['notifications.group_permits'] as String));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(s['notifications.group_permits'] as String));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(s['notifications.empty_permits_title'] as String), findsOneWidget);
  });

  testWidgets('server counts drive the chips when the server sends them', (tester) async {
    await pump(tester, 'en', counts: {NoticeGroup.work: (total: 40, unread: 12)});
    expect(find.text('12'), findsWidgets);
  });

  testWidgets('swipe right marks read, swipe left archives', (tester) async {
    final repo = await pump(tester, 'en');
    final first = find.byType(NotificationCard).first;
    await tester.drag(first, const Offset(400, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1)); // the card slides back
    expect(repo.read, contains('n1'));
    expect(find.text('Scheduled job assigned to you'), findsOneWidget);

    await tester.drag(find.byType(NotificationCard).first, const Offset(-400, 0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(repo.archived, ['n1']);
    expect(find.text('Scheduled job assigned to you'), findsNothing);
    expect(find.text(_strings('en')['notifications.archived'] as String), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6)); // let the SnackBar time out
  });

  testWidgets('a type with no screen opens its details sheet', (tester) async {
    final repo = await pump(tester, 'en');
    await tester.scrollUntilVisible(find.text('Finding raised from your check'), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Finding raised from your check'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(_strings('en')['notifications.details_no_screen'] as String), findsOneWidget);
    expect(find.text('The nameplate serial does not match the register.'), findsWidgets);
    expect(repo.read, isEmpty); // it was already read
  });

  testWidgets('mark all read on a tab only marks that tab (server that understands tabs)', (tester) async {
    final repo = await pump(tester, 'en', counts: {NoticeGroup.snags: (total: 2, unread: 1)});
    await tester.tap(find.text(_strings('en')['notifications.group_snags'] as String));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(_strings('en')['notifications.mark_all_read'] as String));
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.allRead, [NoticeGroup.snags]);
  });
}
