import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/app/router.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/network/session_renewer.dart';
import 'package:technician_portal/admin/core/realtime/socket_service.dart';
import 'package:technician_portal/admin/state/socket_controller.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/core/storage/session_store.dart';
import 'package:technician_portal/admin/data/auth_repository.dart';
import 'package:technician_portal/admin/domain/admin_user.dart';
import 'package:technician_portal/admin/features/shell/admin_shell.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = AdminUser(id: '7', name: 'Dana Admin', role: 'Admin', email: 'dana@example.com');

Map<String, dynamic> _module(String id, String label, String group, {String? navTab, List<Map<String, dynamic>> pages = const []}) =>
    {'id': id, 'label': label, 'group': group, 'icon': 'gauge', 'webPath': '/x', 'navTab': navTab, 'pages': pages, 'tabs': <String>[]};

/// A bootstrap shaped like the server's (src/services/mobileBootstrapService.ts).
Map<String, dynamic> _bootstrap(List<Map<String, dynamic>> modules) => {
      'success': true,
      'data': {
        'role': 'Admin',
        'isSuperAdmin': false,
        'access': {'scope': 'all', 'buildings': <Object>[]},
        'prefs': {'language': 'en'},
        'license': {'state': 'active', 'access': 'full'},
        'modules': modules,
        'webOnly': ['Settings'],
        'catalogVersion': 1,
      },
    };

final _fullCatalog = [
  _module('efficiency', 'Building Efficiency', 'Building Efficiency', navTab: 'efficiency', pages: [
    {'id': 'overview', 'label': 'Building health', 'group': 'Today'},
    {'id': 'comfort', 'label': 'Comfort & air', 'group': 'Health areas'},
  ]),
  _module('alerts', 'Alerts', 'Facility Operations', navTab: 'alerts'),
  _module('work_orders', 'Work Orders', 'Facility Management', navTab: 'operations'),
  _module('plant_room', 'Plant Room', 'Building Performance'),
];

/// A socket that never touches the network; [fire] plays a server push.
class _FakeSocket extends SocketService {
  _FakeSocket(void Function(String event) onEvent)
      : super(baseUrl: '', readToken: () async => null, renewSession: () async => RenewOutcome.rejected, onEvent: onEvent);

  @override
  Future<void> connect() async => _live = this;

  @override
  void disconnect() {}

  void fire([String event = SocketService.configChanged]) => onEvent(event);
}

_FakeSocket? _live;

Map<String, dynamic> _alert(String key, String title, String severity, {String status = 'active'}) => {
      'key': key,
      'title': title,
      'severity': severity,
      'status': status,
      'ref': 'ALT-$key',
      'buildingName': 'Tower A',
      'lastAt': DateTime.now().toIso8601String(),
      'raisedAt': DateTime.now().toIso8601String(),
    };

/// Answers login, bootstrap and the Alert Center without a server.
class _FakeApi extends ApiClient {
  _FakeApi(this.modules) : super(secureStore: SecureStore());
  List<Map<String, dynamic>> modules;
  Object? lastBody;
  final posts = <String>[];
  Map<String, dynamic>? lastQuery;

  /// The server's alert rows; actions change them like the server would.
  List<Map<String, dynamic>> alerts = [
    _alert('sa:1', 'Chiller 2 supply temp high', 'critical'),
    _alert('sa:2', 'AHU-3 filter dirty', 'medium'),
  ];

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add(path);
    lastBody = body;
    if (path.endsWith('/logout')) return {'ok': true};
    if (path == '/api/fm/alerts/bulk') {
      final b = body as Map;
      for (final a in alerts) {
        if ((b['keys'] as List).contains(a['key'])) a['status'] = b['action'] == 'resolve' ? 'resolved' : 'acknowledged';
      }
      return {'success': true, 'data': {'done': b['keys'], 'skipped': []}};
    }
    if (path.startsWith('/api/fm/alerts/')) {
      final parts = path.split('/');
      final key = Uri.decodeComponent(parts[4]);
      final a = alerts.firstWhere((x) => x['key'] == key);
      a['status'] = switch (parts[5]) { 'acknowledge' => 'acknowledged', 'resolve' => 'resolved', 'reopen' => 'active', _ => a['status'] };
      return {'success': true, 'data': a};
    }
    return {'accessToken': 'a', 'refreshToken': 'r', 'user': _user.toJson()};
  }

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    if (path == '/api/fm/alerts') {
      lastQuery = query;
      final statuses = '${query?['status'] ?? ''}'.split(',');
      final rows = alerts.where((a) => statuses.contains(a['status'])).toList();
      final open = alerts.where((a) => a['status'] != 'resolved').length;
      return {'success': true, 'data': {'rows': rows, 'total': rows.length, 'summary': {'open': open, 'critical': 1}}};
    }
    if (path.startsWith('/api/fm/alerts/')) {
      final key = Uri.decodeComponent(path.split('/').last);
      final a = alerts.firstWhere((x) => x['key'] == key);
      return {
        'success': true,
        'data': {
          'alert': a,
          'events': [
            {'action': 'raised', 'at': DateTime.now().toIso8601String()},
          ],
          'can': {'take': true},
        },
      };
    }
    return _bootstrap(modules);
  }
}

_FakeApi? _api;

Future<GoRouter> _pump(WidgetTester tester, {AdminUser? savedUser, List<Map<String, dynamic>>? modules}) async {
  _api = _FakeApi(modules ?? _fullCatalog);
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final sessionStore = await SessionStore.open();
  if (savedUser != null) await sessionStore.writeUser(savedUser);

  late GoRouter router;
  final localization = FlutterLocalization.instance;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        secureStoreProvider.overrideWithValue(SecureStore()),
        sessionStoreProvider.overrideWithValue(sessionStore),
        apiClientProvider.overrideWithValue(_api!),
        socketServiceFactoryProvider.overrideWithValue(_FakeSocket.new),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          router = ref.watch(routerProvider);
          return MaterialApp.router(
            theme: AppTheme.build(),
            supportedLocales: localization.supportedLocales,
            localizationsDelegates: localization.localizationsDelegates,
            locale: localization.currentLocale,
            routerConfig: router,
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Finder _tab(String label) => find.descendant(of: find.byKey(AdminShell.bottomNavKey), matching: find.text(label));

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final localization = FlutterLocalization.instance;
    await localization.ensureInitialized();
    localization.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  // Sign-in itself is FieldOps' screen (unified_login_test.dart); signed
  // out, the admin side shows nothing while AppRoot swaps back.
  testWidgets('signed out: no admin shell', (tester) async {
    await _pump(tester);
    expect(find.byKey(AdminShell.bottomNavKey), findsNothing);
  });

  testWidgets('full catalog: all five tabs', (tester) async {
    await _pump(tester, savedUser: _user);
    for (final label in ['Home', 'Efficiency', 'Alerts', 'Operations', 'More']) {
      expect(_tab(label), findsOneWidget);
    }
  });

  testWidgets('config:changed: a module switched off disappears live, its open screen is blocked', (tester) async {
    final router = await _pump(tester, savedUser: _user);
    router.push(Routes.module('plant_room'));
    await tester.pumpAndSettle();
    expect(find.text('Plant Room'), findsWidgets);

    // An admin switches Plant Room and Alerts off; the server pushes config:changed.
    _api!.modules = _fullCatalog.where((m) => m['id'] != 'plant_room' && m['id'] != 'alerts').toList();
    _live!.fire();
    await tester.pumpAndSettle();

    expect(find.text('This module is switched off for your account.'), findsOneWidget);
    router.go(Routes.home);
    await tester.pumpAndSettle();
    expect(_tab('Alerts'), findsNothing);
    expect(_tab('Efficiency'), findsOneWidget);
  });

  testWidgets('Alerts: open alerts worst first, counts, live refetch on alerts:changed', (tester) async {
    await _pump(tester, savedUser: _user);
    await tester.tap(_tab('Alerts'));
    await tester.pumpAndSettle();
    expect(find.text('Chiller 2 supply temp high'), findsOneWidget);
    expect(find.text('AHU-3 filter dirty'), findsOneWidget);
    expect(_api!.lastQuery?['sort'], '-severity');

    // Someone resolves sa:2 on the web; the server pushes alerts:changed.
    _api!.alerts[1]['status'] = 'resolved';
    _live!.fire(SocketService.alertsChanged);
    await tester.pumpAndSettle();
    expect(find.text('AHU-3 filter dirty'), findsNothing);
  });

  testWidgets('Alert detail: acknowledge, then resolve, refreshes the screen', (tester) async {
    final router = await _pump(tester, savedUser: _user);
    router.push(Routes.alert('sa:1'));
    await tester.pumpAndSettle();
    expect(find.text('Chiller 2 supply temp high'), findsOneWidget);
    expect(find.text('ALT-sa:1'), findsOneWidget); // header = ref
    expect(find.text('Raised'), findsOneWidget); // history

    await tester.tap(find.widgetWithText(OutlinedButton, 'Acknowledge'));
    await tester.pumpAndSettle();
    expect(_api!.posts, contains('/api/fm/alerts/sa%3A1/acknowledge'));
    expect(find.widgetWithText(OutlinedButton, 'Acknowledge'), findsNothing); // gone once acknowledged

    await tester.tap(find.widgetWithText(ElevatedButton, 'Resolve'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ElevatedButton, 'Reopen'), findsOneWidget);
  });

  testWidgets('Alerts: long-press selects, bulk resolve sends the keys', (tester) async {
    await _pump(tester, savedUser: _user);
    await tester.tap(_tab('Alerts'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Chiller 2 supply temp high'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('AHU-3 filter dirty'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Resolve'));
    await tester.pumpAndSettle();
    expect(_api!.posts, contains('/api/fm/alerts/bulk'));
    expect((_api!.lastBody as Map)['keys'], containsAll(['sa:1', 'sa:2']));
    expect(find.text('No alerts'), findsOneWidget);
  });

  testWidgets('modules off: their tabs are hidden, the rest fill the bar', (tester) async {
    await _pump(tester, savedUser: _user, modules: [_module('plant_room', 'Plant Room', 'Building Performance')]);
    expect(_tab('Home'), findsOneWidget);
    expect(_tab('More'), findsOneWidget);
    expect(_tab('Efficiency'), findsNothing);
    expect(_tab('Alerts'), findsNothing);
    expect(_tab('Operations'), findsNothing);
  });

  testWidgets('Efficiency lists only the pages the catalog sent, in groups', (tester) async {
    await _pump(tester, savedUser: _user);
    await tester.tap(_tab('Efficiency'));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Building health'), findsOneWidget);
    expect(find.text('Comfort & air'), findsOneWidget);
    expect(find.text('Savings'), findsNothing);
  });

  testWidgets('deep link to a module not in the catalog is blocked', (tester) async {
    final router = await _pump(tester, savedUser: _user, modules: [_module('alerts', 'Alerts', 'Facility Operations', navTab: 'alerts')]);
    router.go(Routes.module('plant_room'));
    await tester.pumpAndSettle();
    expect(find.text('This module is switched off for your account.'), findsOneWidget);
  });

  testWidgets('hidden tab path redirects to Home', (tester) async {
    final router = await _pump(tester, savedUser: _user, modules: const []);
    router.go(Routes.efficiency);
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, Routes.home);
  });

  testWidgets('More: tab-less modules, web-only footer, log out', (tester) async {
    await _pump(tester, savedUser: _user);
    await tester.tap(_tab('More'));
    await tester.pumpAndSettle();
    expect(find.text('Dana Admin'), findsOneWidget);
    expect(find.text('Plant Room'), findsOneWidget);
    expect(find.text('Work Orders'), findsNothing); // lives under Operations

    await tester.scrollUntilVisible(find.text('Log Out'), 100);
    await tester.tap(find.text('Log Out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Log Out'));
    await tester.pumpAndSettle();
    expect(find.byKey(AdminShell.bottomNavKey), findsNothing);
    expect((await SessionStore.open()).readUser(), isNull);
  });

  test('login sends email or username depending on an @', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = _FakeApi(const []);
    final repo = AuthRepository(api);

    await repo.login(' dana@example.com ', 'p');
    expect(api.lastBody, {'email': 'dana@example.com', 'password': 'p'});

    await repo.login('dana', 'p');
    expect(api.lastBody, {'username': 'dana', 'password': 'p'});
  });
}
