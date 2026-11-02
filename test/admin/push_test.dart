import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/push/push_content.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/more/push_settings_screen.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(secureStore: SecureStore());
  final posts = <(String, Object?)>[];

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add((path, body));
    if (path == '/api/notifications/test-push') return {'success': true, 'data': {'configured': true, 'devices': 2, 'sent': 1}};
    return 'OK';
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final localization = FlutterLocalization.instance;
    await localization.ensureInitialized();
    localization.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  group('where a tapped push goes', () {
    test('the alert fan-out names the alert', () {
      expect(pushTargetOf({'kind': 'alert', 'alertKey': 'sa:42', 'buildingId': 'b'}), const AlertTarget('sa:42'));
    });
    test("routing's bell push carries it in the link", () {
      expect(pushTargetOf({'link': '/alerts?alert=pd%3A7', 'entityType': 'alert'}), const AlertTarget('pd:7'));
    });
    test('anything else opens Notifications', () {
      expect(pushTargetOf({'link': '/fm/work-orders/1'}), const NotificationsTarget());
      expect(pushTargetOf({}), const NotificationsTarget());
      expect(pushTargetOf({'link': '/alerts'}), const NotificationsTarget());
    });
    test('channels: critical alerts are louder', () {
      expect(channelIdFor({'alertKey': 'a', 'severity': 'critical'}), 'fe_alerts_critical');
      expect(channelIdFor({'alertKey': 'a', 'severity': 'high'}), 'fe_alerts');
      expect(channelIdFor({'link': '/x'}), 'fe_updates');
    });
    test("channels: routing's bell push for a critical alert (type error) is louder too", () {
      expect(channelIdFor({'link': '/alerts?alert=sa%3A1', 'type': 'error'}), 'fe_alerts_critical');
      expect(channelIdFor({'link': '/alerts?alert=sa%3A1', 'type': 'warning'}), 'fe_alerts');
      expect(channelIdFor({'link': '/x', 'type': 'error'}), 'fe_updates');
    });
  });

  test('bootstrap prefs: push settings, defaults when an older server omits them', () {
    final boot = MobileBootstrap.fromJson({
      'prefs': <String, dynamic>{'mobilePushAlerts': false, 'mobilePushMinSeverity': 'critical'},
    });
    expect(boot.pushAlerts, isFalse);
    expect(boot.pushMinSeverity, 'critical');
    final old = MobileBootstrap.fromJson({'prefs': <String, dynamic>{}});
    expect(old.pushAlerts, isTrue);
    expect(old.pushMinSeverity, 'high');
  });

  testWidgets('settings: switching off and picking a severity save to the own config', (tester) async {
    final api = _FakeApi();
    final boot = MobileBootstrap.fromJson({
      'prefs': <String, dynamic>{'mobilePushAlerts': true, 'mobilePushMinSeverity': 'high'},
    });
    final localization = FlutterLocalization.instance;
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api), loadedCatalogProvider.overrideWithValue(boot)],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: localization.supportedLocales,
        localizationsDelegates: localization.localizationsDelegates,
        home: const PushSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Critical only'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/api/auth/config');
    expect(api.posts.last.$2, {'mobilePushAlerts': true, 'mobilePushMinSeverity': 'critical'});

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.posts.last.$2, {'mobilePushAlerts': false, 'mobilePushMinSeverity': 'critical'});

    await tester.tap(find.text('Send a test notification'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/api/notifications/test-push');
    expect(find.text('Sent to 1 device(s). It should arrive in a few seconds.'), findsOneWidget);
  });

  test('test push: each outcome has its own message', () {
    expect(testPushMessage(configured: false, devices: 0, sent: 0), 'push.test_off');
    expect(testPushMessage(configured: true, devices: 0, sent: 0), 'push.test_no_device');
    expect(testPushMessage(configured: true, devices: 1, sent: 0), 'push.test_failed');
    expect(testPushMessage(configured: true, devices: 1, sent: 1), 'push.test_sent');
  });
}
