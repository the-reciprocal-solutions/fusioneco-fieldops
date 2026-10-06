import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/offline/waiting_reasons.dart';
import 'package:technician_portal/state/sync_waiting_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';
import 'package:technician_portal/widgets/offline_banner.dart';

/// iPhone report 2026-10-06: the "1 change waiting to sync" bar was drawn
/// under the status bar, with a big blank gap below it before "Orders".
const _strings = {
  'widgets.offline_message': 'Offline — your work is saved on this device',
  'widgets.offline_message_with_queued': 'Offline — your work is saved on this device (%a queued)',
  'widgets.waiting_send_one': '%a change waiting to send',
  'widgets.waiting_send_other': '%a changes waiting to send',
  'widgets.waiting_view': 'View',
  'widgets.waiting_title': 'Waiting to send',
  'widgets.waiting_subtitle': 'Saved on this phone.',
  'widgets.waiting_send_all': 'Send now',
  'widgets.waiting_retry': 'Retry',
  'widgets.waiting_discard': 'Discard',
  'widgets.waiting_discard_title': 'Discard this change?',
  'widgets.waiting_discard_body': 'It hasn\'t been sent yet.',
  'widgets.waiting_keep': 'Keep it',
  'widgets.waiting_queued_at': 'Saved %a',
  'widgets.waiting_empty': 'Everything has been sent.',
  'widgets.waiting_reason_check_in': 'Waiting for your location check-in.',
  'widgets.waiting_reason_behind': 'Waiting for the change above to go first.',
  'widgets.waiting_reason_not_sent': 'Not sent yet.',
};

class _Offline extends DeviceOfflineController {
  _Offline(this.value);
  final bool value;
  @override
  bool build() => value;
}

class _Actions implements WaitingActions {
  final discarded = <String>[];
  final retried = <String>[];
  @override
  Future<void> discard(String id) async => discarded.add(id);
  @override
  Future<void> retry(String id) async => retried.add(id);
  @override
  Future<void> sendAll() async {}
}

final _now = DateTime.now();
List<WaitingItem> _stuck() => explainQueue(
      queue: [
        QueueEntry(id: 'm1', label: 'Checklist update', createdAt: _now.subtract(const Duration(minutes: 5))),
        QueueEntry(id: 'm2', label: 'Close work order', createdAt: _now.subtract(const Duration(minutes: 4))),
      ],
      statuses: {'m1': ReplayStatus(WaitKind.location, at: _now, status: 428)},
      offline: false,
    );

/// An iPhone with a Dynamic Island: 59 pt status-bar inset.
void _iphone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(393 * 3, 852 * 3);
  tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

Future<_Actions> _pump(WidgetTester tester, {required List<WaitingItem> items, bool offline = false}) async {
  final actions = _Actions();
  final localization = FlutterLocalization.instance;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceOfflineProvider.overrideWith(() => _Offline(offline)),
        waitingItemsProvider.overrideWithValue(items),
        waitingActionsProvider.overrideWithValue(actions),
      ],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: localization.supportedLocales,
        localizationsDelegates: localization.localizationsDelegates,
        locale: localization.currentLocale,
        home: Scaffold(
          body: TopChromeLayout(
            top: const [OfflineBanner()],
            // What every branch screen does (orders_screen.dart).
            body: const Scaffold(body: SafeArea(bottom: false, child: Text('Orders'))),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return actions;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final localization = FlutterLocalization.instance;
    await localization.ensureInitialized();
    localization.init(mapLocales: [const MapLocale('en', _strings)], initLanguageCode: 'en');
  });

  testWidgets('banner sits below the Dynamic Island, the screen right below it — no gap', (tester) async {
    _iphone(tester);
    await _pump(tester, items: _stuck());

    final banner = find.byKey(const ValueKey('sync-banner'));
    expect(banner, findsOneWidget);
    expect(find.text('2 changes waiting to send'), findsOneWidget);
    expect(tester.getTopLeft(banner).dy, closeTo(59, 0.5));
    final gap = tester.getTopLeft(find.text('Orders')).dy - tester.getBottomLeft(banner).dy;
    expect(gap, closeTo(0, 0.5), reason: 'the branch SafeArea must not add the status-bar inset again');
  });

  testWidgets('nothing waiting: no banner, the screen starts at the inset as before', (tester) async {
    _iphone(tester);
    await _pump(tester, items: const []);
    expect(find.byKey(const ValueKey('sync-banner')), findsNothing);
    expect(tester.getTopLeft(find.text('Orders')).dy, closeTo(59, 0.5));
  });

  testWidgets('a write about to go (seconds old, not stuck) shows no bar', (tester) async {
    _iphone(tester);
    final fresh = explainQueue(
      queue: [QueueEntry(id: 'm1', label: 'Note', createdAt: DateTime.now())],
      statuses: const {},
      offline: false,
    );
    await _pump(tester, items: fresh);
    expect(find.byKey(const ValueKey('sync-banner')), findsNothing);
  });

  testWidgets('offline: dark bar, still below the inset', (tester) async {
    _iphone(tester);
    await _pump(tester, items: _stuck(), offline: true);
    expect(find.text('Offline — your work is saved on this device (2 queued)'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('sync-banner'))).dy, closeTo(59, 0.5));
  });

  testWidgets('tap opens "Waiting to send" with plain reasons; Discard asks first', (tester) async {
    _iphone(tester);
    final actions = await _pump(tester, items: _stuck());

    await tester.tap(find.byKey(const ValueKey('sync-banner')));
    await tester.pumpAndSettle();
    expect(find.text('Waiting to send'), findsOneWidget);
    expect(find.text('Checklist update'), findsOneWidget);
    expect(find.text('Waiting for your location check-in.'), findsOneWidget);
    expect(find.text('Waiting for the change above to go first.'), findsOneWidget);

    await tester.tap(find.text('Retry').first);
    await tester.pumpAndSettle();
    expect(actions.retried, ['m1']);

    await tester.tap(find.text('Discard').first);
    await tester.pumpAndSettle();
    expect(find.text('Discard this change?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(actions.discarded, isEmpty);

    await tester.tap(find.text('Discard').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('waiting-discard-confirm')));
    await tester.pumpAndSettle();
    expect(actions.discarded, ['m1']);
  });
}
