import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/c2o/c2o_asset_resolver.dart';
import 'package:technician_portal/core/offline/sign_out_wipe.dart';
import 'package:technician_portal/core/scanner/scan_history.dart';
import 'package:technician_portal/core/utils/qr_payload.dart';
import 'package:technician_portal/features/scanner/scan_history_screen.dart';
import 'package:technician_portal/state/scan_history_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// The scanner's history (owner, 2026-10-06: "keep all past scans in local
/// storage so I can get to them with one tap"). The store fake below has
/// the same semantics as `OfflineDb`'s `scan_history` SQL (insert-or-replace,
/// per-user newest-first, trim keeps the newest N per user, age prune is
/// global); the SQL itself was checked against sqlite3 separately.
class MemoryScanStore implements ScanHistoryStore {
  final rows = <String, String>{}; // id → encoded json, like the DB column

  List<ScanRecord> get _all => [for (final v in rows.values) ScanRecord.decode(v)!];

  @override
  Future<void> putScan(ScanRecord record) async => rows[record.id] = record.encode();

  @override
  Future<List<ScanRecord>> listScans(String userId, {int limit = 500}) async {
    final mine = _all.where((r) => r.userId == userId).toList()..sort((a, b) => b.at.compareTo(a.at));
    return mine.take(limit).toList();
  }

  @override
  Future<void> deleteScansBefore(DateTime cutoff) async =>
      rows.removeWhere((_, v) => ScanRecord.decode(v)!.at.isBefore(cutoff));

  @override
  Future<void> trimScans(String userId, int keep) async {
    final keepIds = (await listScans(userId, limit: keep)).map((r) => r.id).toSet();
    rows.removeWhere((id, v) => ScanRecord.decode(v)!.userId == userId && !keepIds.contains(id));
  }

  @override
  Future<void> clearScans(String userId) async => rows.removeWhere((_, v) => ScanRecord.decode(v)!.userId == userId);
}

ScanRecord _text(String id, DateTime at, {String user = 'u1', String code = 'hello'}) => scanRecordForOther(
      id: id,
      userId: user,
      at: at,
      raw: code,
      kind: ScanKind.text,
      code: code,
    );

Map<String, dynamic> _claims() => {
      'asset': {
        'id': 'asset-1',
        'assetName': 'AHU-01',
        'assetReferenceId': 'STTCC-AHU-001',
        'locationPath': [
          {'level': 'building', 'label': 'Tower A'},
          {'level': 'floor', 'label': 'L3'},
          {'level': 'room', 'code': 'PR-301'},
        ],
      },
    };

void main() {
  group('ScanHistory store', () {
    late MemoryScanStore store;
    var now = DateTime(2026, 10, 6, 9);
    ScanHistory history() => ScanHistory(store, clock: () => now);

    setUp(() {
      store = MemoryScanStore();
      now = DateTime(2026, 10, 6, 9);
    });

    test('persists: a later instance over the same store lists it, every field intact', () async {
      final h = history();
      final r = scanRecordForC2o(
        id: h.newId(),
        userId: 'u1',
        at: now,
        raw: 'c2o:asset-1:tok',
        outcome: C2oResolved(assetId: 'asset-1', claims: _claims(), fromCache: true),
        offRoute: true,
      );
      expect(await h.record(r), isTrue);

      final reopened = await history().list('u1');
      expect(reopened, hasLength(1));
      final back = reopened.single;
      expect(back.toJson(), r.toJson());
      expect(back.title, 'AHU-01');
      expect(back.code, 'STTCC-AHU-001');
      expect(back.place, 'Tower A › L3 › PR-301');
      expect(back.status, ScanStatus.foundOffline);
      expect(back.offRoute, isTrue);
      expect(back.target, '/asset/asset-1');
    });

    test('caps at 500 per user, keeping the newest', () async {
      final h = history();
      for (var i = 0; i < ScanHistoryPolicy.maxEntries + 5; i++) {
        await h.record(_text('id-$i', now.add(Duration(seconds: i))));
      }
      final list = await h.list('u1');
      expect(list, hasLength(ScanHistoryPolicy.maxEntries));
      expect(list.first.id, 'id-504', reason: 'newest first');
      expect(list.any((r) => r.id == 'id-0'), isFalse, reason: 'the oldest five went');
    });

    test('prunes scans older than 90 days on the next record', () async {
      final h = history();
      await h.record(_text('old', now.subtract(const Duration(days: 91))));
      await h.record(_text('recent', now.subtract(const Duration(days: 89))));
      final ids = (await h.list('u1')).map((r) => r.id);
      expect(ids, ['recent']);
    });

    test('another user never sees, trims or clears my scans', () async {
      final h = history();
      await h.record(_text('mine', now));
      await h.record(_text('theirs', now, user: 'u2'));
      expect((await h.list('u2')).map((r) => r.id), ['theirs']);
      await h.clear('u2');
      expect((await h.list('u1')).map((r) => r.id), ['mine']);
    });

    test('recording never throws, even when the store does', () async {
      final broken = ScanHistory(_ThrowingStore());
      expect(await broken.record(_text('x', now)), isFalse);
    });

    test('kept on sign-out (a 24 h expiry must not wipe a shift), never wiped', () {
      expect(kKeptOnSignOut, contains('scan_history'));
      expect(kSignOutWipe.map((s) => s.table), isNot(contains('scan_history')));
    });

    test('a corrupt row is skipped, not a crash', () {
      expect(ScanRecord.decode('{nope'), isNull);
      expect(ScanRecord.decode('{"id":"a","at":1,"kind":"future-kind","status":"x"}')!.kind, ScanKind.text);
    });
  });

  group('what each scan records', () {
    final at = DateTime(2026, 10, 6);

    test('C2O outcomes: mismatch and not-found are problems with a reason; no signal waits', () {
      final mismatch = scanRecordForC2o(id: '1', userId: 'u', at: at, raw: 'r', outcome: const C2oTokenMismatch('a'));
      expect(mismatch.status, ScanStatus.failed);
      expect(mismatch.reasonKey, 'scans.reason_mismatch');
      final missing = scanRecordForC2o(id: '2', userId: 'u', at: at, raw: 'r', outcome: const C2oNotFound('a'));
      expect(missing.reasonKey, 'scans.reason_not_found');
      final waiting = scanRecordForC2o(id: '3', userId: 'u', at: at, raw: 'r', outcome: const C2oNeedsSignal('a'));
      expect(waiting.status, ScanStatus.waiting);

      final later = rescanned(waiting, C2oResolved(assetId: 'a', claims: _claims(), fromCache: false));
      expect(later.id, waiting.id);
      expect(later.at, waiting.at);
      expect(later.status, ScanStatus.found);
      expect(later.reasonKey, isNull);
      expect(later.title, 'AHU-01');
    });

    test('a general label opens its page; a work order opens in the app', () {
      final asset = scanRecordForLabel(
        id: '1',
        userId: 'u',
        at: at,
        raw: 'x',
        record: const ScannedRecord(path: '/public/assets/42', label: 'Asset'),
        webBaseUrl: 'https://web',
      );
      expect(asset.kind, ScanKind.asset);
      expect(asset.code, '42');
      expect(asset.target, 'https://web/public/assets/42');
      final wo = scanRecordForLabel(
        id: '2',
        userId: 'u',
        at: at,
        raw: 'x',
        record: const ScannedRecord(path: '/orders/work-order/7', label: 'Work Order'),
        webBaseUrl: 'https://web',
      );
      expect(wo.kind, ScanKind.workOrder);
      expect(wo.target, '/orders/work-order/7');
    });

    test('filters and search', () {
      final rows = [
        scanRecordForC2o(id: '1', userId: 'u', at: at, raw: 'r', outcome: const C2oNeedsSignal('a')),
        scanRecordForC2o(id: '2', userId: 'u', at: at, raw: 'r', outcome: const C2oTokenMismatch('b')),
        scanRecordForOther(id: '3', userId: 'u', at: at, raw: 'r', kind: ScanKind.permit, code: 'PTW1234…'),
      ];
      List<String> ids(ScanFilter f) => [for (final r in rows) if (f.accepts(r)) r.id];
      expect(ids(ScanFilter.waiting), ['1']);
      expect(ids(ScanFilter.problems), ['2']);
      expect(ids(ScanFilter.assets), ['1', '2']);
      expect(ids(ScanFilter.other), ['3']);
      expect(rows[2].matches('ptw'), isTrue);
      expect(rows[2].matches('ahu'), isFalse);
    });
  });

  group('Scans page', () {
    Map<String, dynamic> strings() {
      final all = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
      return {
        for (final e in all.entries)
          if (e.key.startsWith('scans.') || e.key.startsWith('common.')) e.key: e.value,
      };
    }

    final en = strings();

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      final l = FlutterLocalization.instance;
      await l.ensureInitialized();
      l.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
    });

    Future<MemoryScanStore> pump(WidgetTester tester, {C2oResolution? retryAnswer}) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final store = MemoryScanStore();
      final now = DateTime.now();
      final h = ScanHistory(store);
      // Scans no older than "now" so they group under Today.
      await h.record(scanRecordForC2o(
        id: 'a',
        userId: 'u1',
        at: now.subtract(const Duration(minutes: 3)),
        raw: 'c2o:asset-1:tok',
        outcome: C2oResolved(assetId: 'asset-1', claims: _claims(), fromCache: false),
      ));
      await h.record(scanRecordForC2o(
        id: 'b',
        userId: 'u1',
        at: now.subtract(const Duration(minutes: 2)),
        raw: 'c2o:asset-2:tok',
        outcome: const C2oNeedsSignal('asset-2'),
      ));
      await h.record(scanRecordForC2o(
        id: 'c',
        userId: 'u1',
        at: now.subtract(const Duration(minutes: 1)),
        raw: 'c2o:asset-3:tok',
        outcome: const C2oTokenMismatch('asset-3'),
      ));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          scanHistoryProvider.overrideWithValue(h),
          scanUserIdProvider.overrideWithValue('u1'),
          scanRetryResolverProvider.overrideWithValue((raw) async => retryAnswer),
        ],
        child: MaterialApp(
          theme: AppTheme.build(),
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
          home: const ScanHistoryScreen(),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return store;
    }

    testWidgets('lists every scan with what, where, status and the plain reason', (tester) async {
      await pump(tester);
      expect(find.byType(ScanRow), findsNWidgets(3));
      expect(find.text('AHU-01'), findsOneWidget);
      expect(find.textContaining('Tower A › L3'), findsOneWidget);
      expect(find.text(en['scans.status_waiting'] as String), findsOneWidget);
      expect(find.text(en['scans.reason_mismatch'] as String), findsOneWidget);
      expect(find.text(en['scans.today'].toString().toUpperCase()), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search and filter narrow the list', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'ahu');
      await tester.pump();
      expect(find.byType(ScanRow), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      final chip = find.widgetWithText(ChoiceChip, en['scans.filter_problems'] as String);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      expect(find.byType(ScanRow), findsOneWidget);
      expect(find.text(en['scans.reason_mismatch'] as String), findsOneWidget);
    });

    testWidgets('a waiting tag resolves on retry once there is signal', (tester) async {
      final store = await pump(tester, retryAnswer: C2oResolved(assetId: 'asset-2', claims: _claims(), fromCache: false));
      // The page retries waiting tags once on open.
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(en['scans.status_waiting'] as String), findsNothing);
      expect(ScanRecord.decode(store.rows['b']!)!.status, ScanStatus.found);
    });

    testWidgets('Clear history asks first, then empties the list', (tester) async {
      final store = await pump(tester);
      await tester.tap(find.byTooltip(en['scans.clear'] as String));
      await tester.pumpAndSettle();
      expect(find.text(en['scans.clear_title'] as String), findsOneWidget);
      await tester.tap(find.text(en['common.cancel'] as String));
      await tester.pumpAndSettle();
      expect(store.rows, hasLength(3));

      await tester.tap(find.byTooltip(en['scans.clear'] as String));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en['scans.clear_confirm'] as String));
      await tester.pumpAndSettle();
      expect(store.rows, isEmpty);
      expect(find.text(en['scans.empty_title'] as String), findsOneWidget);
    });
  });
}

class _ThrowingStore implements ScanHistoryStore {
  @override
  Future<void> putScan(ScanRecord record) => throw StateError('disk full');
  @override
  Future<List<ScanRecord>> listScans(String userId, {int limit = 500}) => throw StateError('x');
  @override
  Future<void> deleteScansBefore(DateTime cutoff) => throw StateError('x');
  @override
  Future<void> trimScans(String userId, int keep) => throw StateError('x');
  @override
  Future<void> clearScans(String userId) => throw StateError('x');
}
