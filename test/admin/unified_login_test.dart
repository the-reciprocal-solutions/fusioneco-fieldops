import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/network/api_client.dart' as admin;
import 'package:technician_portal/admin/core/network/api_exception.dart' as admin;
import 'package:technician_portal/admin/core/storage/secure_store.dart' as admin;
import 'package:technician_portal/admin/core/storage/session_store.dart' as admin;
import 'package:technician_portal/admin/state/auth_controller.dart' as admin;
import 'package:technician_portal/admin/state/providers.dart' as admin;
import 'package:technician_portal/features/login/login_screen.dart';
import 'package:technician_portal/state/auth_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// The technician login, answering as the server would for [reply].
class _TechAuth extends AuthController {
  _TechAuth(this.reply);
  final String reply;

  @override
  AuthState build() => const AuthState();

  @override
  Future<bool> login(String username, String password) async {
    state = AuthState(error: reply, notTechnician: reply == 'Technician not found');
    return false;
  }
}

class _AdminApi extends admin.ApiClient {
  _AdminApi() : super(secureStore: admin.SecureStore());
  final paths = <String>[];

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    paths.add(path);
    if ((body as Map)['password'] != 'secret') {
      throw const admin.HttpFailure(status: 400, message: 'Invalid Credentials');
    }
    return {
      'accessToken': 'a',
      'refreshToken': 'r',
      'user': {'id': '7', 'name': 'Dana Admin', 'role': 'Admin'},
    };
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  Future<(ProviderContainer, _AdminApi)> pump(WidgetTester tester, String techReply) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final api = _AdminApi();
    final container = ProviderContainer(overrides: [
      authControllerProvider.overrideWith(() => _TechAuth(techReply)),
      admin.secureStoreProvider.overrideWithValue(admin.SecureStore()),
      admin.sessionStoreProvider.overrideWithValue(await admin.SessionStore.open()),
      admin.apiClientProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);
    final l = FlutterLocalization.instance;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        home: const LoginScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    return (container, api);
  }

  Future<void> signIn(WidgetTester tester, String password) async {
    await tester.enterText(find.byType(TextFormField).first, 'dana');
    await tester.enterText(find.byType(TextFormField).last, password);
    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();
  }

  testWidgets('the sign-in screen reads for technicians and admins alike', (tester) async {
    await pump(tester, 'Technician not found');
    expect(find.text('Facility operations for technicians and admins'), findsOneWidget);
    expect(find.text('SIGN IN TO YOUR ACCOUNT'), findsOneWidget);
    expect(find.text('Username or email'), findsOneWidget);
    expect(find.textContaining('Technician'), findsNothing);
  });

  testWidgets('not a technician → the admin login signs them in', (tester) async {
    final (c, api) = await pump(tester, 'Technician not found');
    await signIn(tester, 'secret');
    expect(api.paths, ['/api/auth/mobile/login']);
    expect(c.read(admin.authControllerProvider).isAuthenticated, isTrue);
    expect(c.read(authControllerProvider).error, isNull);
    expect(find.text('Technician not found'), findsNothing);
  });

  testWidgets("an admin's wrong password shows the admin login's message", (tester) async {
    final (c, _) = await pump(tester, 'Technician not found');
    await signIn(tester, 'wrong');
    expect(c.read(admin.authControllerProvider).isAuthenticated, isFalse);
    expect(find.text('Invalid Credentials'), findsOneWidget);
  });

  testWidgets("a technician's wrong password never tries the admin login", (tester) async {
    final (c, api) = await pump(tester, 'Invalid Credentials');
    await signIn(tester, 'wrong');
    expect(api.paths, isEmpty);
    expect(find.text('Invalid Credentials'), findsOneWidget);
  });
}
