import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:technician_portal/admin/app/router.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/network/api_exception.dart';
import 'package:technician_portal/admin/core/push/local_notifications.dart';
import 'package:technician_portal/admin/core/push/push_content.dart';
import 'package:technician_portal/admin/core/push/push_service.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/state/providers.dart';

/// Acknowledge answers like the server; [fail] makes it refuse.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final posts = <String>[];
  bool fail = false;

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add(path);
    if (fail) throw const HttpFailure(status: 409, message: 'Already acknowledged');
    return {
      'success': true,
      'data': {'key': 'sa:7', 'title': 'x', 'severity': 'high', 'status': 'acknowledged'},
    };
  }
}

void main() {
  (ProviderContainer, _Api, List<String>) setup() {
    final api = _Api();
    final opened = <String>[];
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const SizedBox()),
      GoRoute(path: '/alert/:key', builder: (_, s) {
        opened.add(s.pathParameters['key']!);
        return const SizedBox();
      }),
    ]);
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      routerProvider.overrideWithValue(router),
    ]);
    addTearDown(c.dispose);
    return (c, api, opened);
  }

  final alertPush = jsonEncode({'kind': 'alert', 'alertKey': 'sa:7', 'severity': 'high', 'reason': 'raised'});

  test('alert pushes get the button; other pushes do not', () {
    expect(canAckFromTray({'alertKey': 'sa:7'}), isTrue);
    expect(canAckFromTray({'link': '/alerts?alert=sa:7'}), isTrue);
    expect(canAckFromTray({'link': '/facility-management/work-order/view/1'}), isFalse);
  });

  List<String> stack(ProviderContainer c) =>
      [for (final m in c.read(routerProvider).routerDelegate.currentConfiguration.matches) m.matchedLocation];

  Future<(ProviderContainer, _Api, List<String>)> pump(WidgetTester tester) async {
    final (c, api, opened) = setup();
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp.router(routerConfig: c.read(routerProvider))));
    return (c, api, opened);
  }

  testWidgets('Acknowledge from the tray: the call is made, then the alert opens', (tester) async {
    final (c, api, opened) = await pump(tester);
    await tester.runAsync(() => c.read(pushServiceProvider).respond(alertPush, ackActionId));
    await tester.pumpAndSettle();
    expect(api.posts, ['/api/fm/alerts/sa%3A7/acknowledge']);
    expect(stack(c), ['/', '/alert/sa%3A7']);
  });

  testWidgets('a tap on the body only opens; a refused acknowledge still opens', (tester) async {
    final (c, api, opened) = await pump(tester);
    await tester.runAsync(() => c.read(pushServiceProvider).respond(alertPush, null));
    await tester.pumpAndSettle();
    expect(api.posts, isEmpty);
    expect(stack(c), ['/', '/alert/sa%3A7']);

    api.fail = true;
    await tester.runAsync(() => c.read(pushServiceProvider).respond(alertPush, ackActionId));
    await tester.pumpAndSettle();
    expect(api.posts, hasLength(1));
    expect(stack(c), ['/', '/alert/sa%3A7', '/alert/sa%3A7']);
  });
}
