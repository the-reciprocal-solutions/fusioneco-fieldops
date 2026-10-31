import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/network/api_client.dart' as admin;
import 'package:technician_portal/admin/core/realtime/socket_service.dart' as admin;
import 'package:technician_portal/admin/core/storage/secure_store.dart' as admin;
import 'package:technician_portal/admin/core/storage/session_store.dart' as admin;
import 'package:technician_portal/admin/domain/admin_user.dart';
import 'package:technician_portal/admin/state/auth_controller.dart' as admin;
import 'package:technician_portal/admin/state/providers.dart' as admin;
import 'package:technician_portal/admin/state/socket_controller.dart' as admin;
import 'package:technician_portal/admin/app/app.dart';
import 'package:technician_portal/app/app.dart';
import 'package:technician_portal/app/app_root.dart';

class _Api extends admin.ApiClient {
  _Api() : super(secureStore: admin.SecureStore());
  final posts = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    if (path == '/api/mobile/bootstrap') {
      return {
        'modules': [
          for (final (id, tab) in [('dashboard', 'home'), ('alerts', 'alerts')])
            {'id': id, 'label': id, 'group': 'fm', 'icon': 'gauge', 'webPath': '/x', 'navTab': tab, 'pages': <dynamic>[], 'tabs': <String>[]},
        ],
        'prefs': <String, dynamic>{},
      };
    }
    return {'success': true, 'data': <String, dynamic>{}};
  }

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add(path);
    return {'ok': true};
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
  });

  testWidgets('an admin signed in on the phone gets the admin side; signing out leaves it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final sessions = await admin.SessionStore.open();
    await sessions.writeUser(const AdminUser(id: '7', name: 'Dana Admin', role: 'Admin'));
    expect(await admin.SessionStore.signedInOnDevice(), isTrue);

    final api = _Api();
    final c = ProviderContainer(overrides: [
      admin.secureStoreProvider.overrideWithValue(admin.SecureStore()),
      admin.sessionStoreProvider.overrideWithValue(sessions),
      admin.apiClientProvider.overrideWithValue(api),
      admin.socketServiceFactoryProvider.overrideWithValue(_NoSocket.new),
    ]);
    addTearDown(c.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const AppRoot()));
    // Only the switch: AdminApp's first frame waits on assets/i18n/*.json
    // (real IO a widget test never finishes, LEARNINGS 2026-10-21). The admin
    // shell behind it is app_shell_test.dart's job.
    expect(find.byType(AdminApp), findsOneWidget);
    expect(find.byType(TechnicianApp), findsNothing);

    // Sign-out ends the admin side; the push handler then draws for FieldOps.
    await c.read(admin.authControllerProvider.notifier).logout(revoke: false);
    expect(c.read(admin.authControllerProvider).isAuthenticated, isFalse);
    // (AppRoot would now build TechnicianApp, which needs FieldOps' whole
    // provider set; the switch itself is the line above.)
    expect(await admin.SessionStore.signedInOnDevice(), isFalse);
  });
}

class _NoSocket implements admin.SocketService {
  _NoSocket(Object? _);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
