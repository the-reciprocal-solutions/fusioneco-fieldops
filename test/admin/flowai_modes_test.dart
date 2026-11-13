import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/chat_screen.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// A 1×1 JPEG.
final _jpeg = base64Decode('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=');
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

/// The live shapes (server utilityAiController.ts + facilityPrompts.ts, 2026-11-02).
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  Object? streamBody;
  Object? assetBody;
  List<Map<String, dynamic>> events = const [];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async => switch (path) {
        '/api/fm/bs/building-systems' => {
            'data': [
              {'id': 'b1', 'name': 'Tower A'},
              {'id': 'b2', 'name': 'Research Lab'},
            ],
          },
        _ => {'messages': <Object>[]},
      };

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    expect(path, '/api/fm/assets');
    assetBody = body;
    return {'success': true, 'data': {'id': 'a1', 'assetReferenceId': 'AST1201', 'isAccepted': true}};
  }

  @override
  Stream<Map<String, dynamic>> postEvents(String path, {Object? body, Duration timeout = const Duration(minutes: 3)}) async* {
    streamBody = body;
    yield* Stream.fromIterable(events);
  }
}

MobileBootstrap _boot({bool asset = true, bool report = true}) => MobileBootstrap(
      role: 'Admin',
      isSuperAdmin: false,
      accessScope: 'all',
      buildings: const [],
      language: 'en',
      license: const LicenseInfo(state: 'active', access: 'full'),
      modules: const [MobileModule(id: 'ask_flowai', label: 'Ask FlowAI', group: 'AI', icon: 'bot', webPath: '/fu-agent')],
      webOnly: const [],
      catalogVersion: 1,
      aiCreateAsset: asset,
      aiAssetReport: report,
    );

Future<void> _pump(WidgetTester tester, _Api api, MobileBootstrap boot) async {
  const module = MobileModule(id: 'ask_flowai', label: 'Ask FlowAI', group: 'AI', icon: 'bot', webPath: '/fu-agent');
  final l = FlutterLocalization.instance;
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      loadedCatalogProvider.overrideWithValue(boot),
      chatPhotoPickerProvider.overrideWithValue((_) async => (bytes: _jpeg, name: 'x.jpg')),
    ],
    child: MaterialApp(
      theme: AppTheme.build(),
      supportedLocales: l.supportedLocales,
      localizationsDelegates: l.localizationsDelegates,
      home: const ChatScreen(module: module, sessionId: 's-1'),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  test('a photo is a data URL the server reads; PNG stays PNG', () {
    expect(photoDataUrl(_jpeg), startsWith('data:image/jpeg;base64,'));
    expect(photoDataUrl(_png), startsWith('data:image/png;base64,'));
    expect(dataUrlBytes(photoDataUrl(_jpeg)), _jpeg);
    expect(dataUrlBytes('https://x/y.jpg'), isNull);
  });

  test('the request: flags only when on, a photo-only turn still has text', () {
    expect(chatRequest(text: 'hi', sessionId: 's', env: 'test'), {'message': 'hi', 'sessionId': 's', 'env': 'test'});
    expect(chatRequest(text: '', sessionId: 's', env: 'test', images: ['data:x'], mode: ChatMode.createAsset, fallbackText: 'Look'), {
      'message': 'Look',
      'sessionId': 's',
      'env': 'test',
      'images': ['data:x'],
      'isCreateAsset': true,
    });
    expect(chatRequest(text: 'r', sessionId: 's', env: 'test', mode: ChatMode.report)['isAssetReport'], true);
  });

  testWidgets('modes show only when the user has them', (tester) async {
    await _pump(tester, _Api(), _boot(asset: false, report: true));
    expect(find.text('Create asset'), findsNothing);
    expect(find.text('Inspection report'), findsOneWidget);
  });

  testWidgets('Create asset: photo + mode → draft → building → saved', (tester) async {
    final api = _Api()
      ..events = [
        {'type': 'step', 'title': 'Looking at the photo'},
        {
          'type': 'final',
          'content': '# Asset Analysis\nA **split AC** unit.',
          'context': {
            'assetData': {'name': 'Split AC 2TR', 'manufacturer': 'Daikin', 'model': 'FTKF60', 'type': 'HVAC', 'assetTypeID': 't1', 'status': 'active'},
          },
          'actions': [
            {'label': 'Create Asset', 'type': 'createAsset'},
          ],
        },
      ];
    await _pump(tester, api, _boot());
    await tester.tap(find.text('Create asset'));
    await tester.pumpAndSettle();
    expect(find.text('Attach a photo and describe the asset.'), findsOneWidget);
    await tester.tap(find.byTooltip('Add a photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.send));
    await tester.pumpAndSettle();

    final body = api.streamBody! as Map;
    expect(body['isCreateAsset'], true);
    expect(body['message'], 'Please look at this photo.');
    expect((body['images'] as List).single, startsWith('data:image/jpeg;base64,'));
    expect(find.textContaining('split AC', findRichText: true), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Create asset'));
    await tester.pumpAndSettle();
    expect(find.text('Daikin'), findsOneWidget);
    await tester.tap(find.text('Building'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tower A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create asset').last);
    await tester.pumpAndSettle();
    expect(api.assetBody, containsPair('buildingID', 'b1'));
    expect(api.assetBody, containsPair('assetTypeID', 't1'));
    expect(find.text('Asset AST1201 created.'), findsOneWidget);
  });

  testWidgets('Inspection report: the answer can be shared', (tester) async {
    final api = _Api()
      ..events = [
        {
          'type': 'final',
          'content': '# Asset Inspection Report\nFilter is clogged.',
          'context': {'reportType': 'inspection', 'urgency': 'soon'},
          'actions': [
            {'label': 'Create Maintenance Request', 'type': 'reactive'},
          ],
        },
      ];
    await _pump(tester, api, _boot());
    await tester.tap(find.text('Inspection report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'AHU-01 filter');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect((api.streamBody! as Map)['isAssetReport'], true);
    expect(find.text('Share report'), findsOneWidget);
    expect(find.text('Create Maintenance Request'), findsNothing); // the web's button does nothing either
  });
}
