import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/data/bootstrap_repository.dart';
import 'package:technician_portal/admin/domain/admin_user.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/state/auth_controller.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/locale_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/fe_status_tokens.dart';
import 'package:technician_portal/admin/theme/theme_extensions.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final posts = <(String, Object?)>[];
  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add((path, body));
    return 'OK';
  }
}

class _Boot extends BootstrapRepository {
  _Boot(super.api);
  String language = 'en';
  @override
  Future<MobileBootstrap> fetch() async => MobileBootstrap.fromJson({'prefs': <String, dynamic>{'language': language}});
}

class _Auth extends AuthController {
  @override
  AuthState build() => const AuthState(user: AdminUser(id: 'u1', name: 'Ragul', role: 'Admin'));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [const MapLocale('en', {}), const MapLocale('ar', {})], initLanguageCode: 'en');
  });

  group('P-001 language', () {
    late _Api api;
    late _Boot boot;
    late ProviderContainer c;

    setUp(() {
      api = _Api();
      boot = _Boot(api);
      c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        bootstrapRepositoryProvider.overrideWithValue(boot),
        authControllerProvider.overrideWith(_Auth.new),
      ]);
    });
    tearDown(() => c.dispose());

    test('a choice in the app is saved to the own config', () async {
      await c.read(localeControllerProvider.notifier).choose('ar');
      expect(c.read(localeControllerProvider), 'ar');
      expect(api.posts.single.$1, '/api/auth/config');
      expect(api.posts.single.$2, {'language': 'ar'});
    });

    test('a refetch does not undo the phone; a change on the web is followed', () async {
      await c.read(catalogProvider.future); // server: en
      c.read(localeControllerProvider.notifier).set('ar'); // switched on the phone, save lost
      c.invalidate(catalogProvider);
      await c.read(catalogProvider.future); // server still en
      expect(c.read(localeControllerProvider), 'ar');

      boot.language = 'ar';
      c.invalidate(catalogProvider);
      await c.read(catalogProvider.future);
      boot.language = 'en'; // switched back on the web
      c.invalidate(catalogProvider);
      await c.read(catalogProvider.future);
      expect(c.read(localeControllerProvider), 'en');
    });
  });

  group('P-011 / P-014 chip colours', () {
    const chips = FeStatusColors();
    final grey = chips.priority('???').foreground;

    test('condition and severity words get a colour', () {
      expect(chips.priority('good').foreground, FeStatusHues.conditionGood);
      expect(chips.priority('excellent').foreground, FeStatusHues.conditionExcellent);
      expect(chips.priority('poor').foreground, FeStatusHues.conditionPoor);
      expect(chips.priority('warning').foreground, FeStatusHues.priorityHigh);
      expect(chips.priority('major').foreground, FeStatusHues.priorityHigh);
      expect(chips.priority('minor').foreground, FeStatusHues.priorityLow);
      for (final w in ['good', 'fair', 'warning', 'major', 'minor', 'info']) {
        expect(chips.priority(w).foreground, isNot(grey), reason: w);
      }
    });

    test('status words beyond the web switch, matched as whole values', () {
      expect(chips.status('checked_in').foreground, FeStatusHues.open);
      expect(chips.status('checked-out').foreground, FeStatusHues.completed);
      expect(chips.status('ok').foreground, FeStatusHues.completed);
      expect(chips.status('risk').foreground, FeStatusHues.overdue);
      expect(chips.status('warn').foreground, FeStatusHues.inProgress);
      expect(chips.status('info').foreground, FeStatusHues.open);
      expect(chips.status('neutral').foreground, FeStatusHues.draft);
      // The shared rules still win, and unknown stays grey.
      expect(chips.status('In Progress').foreground, FeStatusHues.inProgress);
      expect(chips.status('Completed').foreground, FeStatusHues.completed);
      expect(chips.status('something else').foreground, FeStatusHues.draft);
    });
  });
}
