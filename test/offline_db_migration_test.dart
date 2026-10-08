// FR-4.9 — the offline queue must survive an app upgrade. This builds the
// database exactly as the first release (schema v1) created it, fills the
// queue the way a technician in a basement would, runs the app's real
// upgrade path to the current version, and reads every row back through the
// app's own queries. Plain SQLite (sqflite_common_ffi) stands in for
// SQLCipher: same `Database` interface, same SQL, no phone needed.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:technician_portal/core/offline/offline_db.dart';

/// The v1 schema, copied from the first commit of offline_db.dart (82ab613).
/// Frozen on purpose: it is what is on phones that never updated, so it must
/// never follow later edits to [OfflineDb.createSchema].
Future<void> _createV1(Database db) async {
  await db.execute('''
    CREATE TABLE pending_mutations (
      client_mutation_id TEXT PRIMARY KEY,
      method TEXT NOT NULL,
      url TEXT NOT NULL,
      body TEXT,
      label TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      attachment BLOB,
      attachment_name TEXT,
      attachment_field TEXT,
      placeholder TEXT
    )
  ''');
  await db.execute('CREATE INDEX idx_pending_created_at ON pending_mutations (created_at)');
  await db.execute('''
    CREATE TABLE cached_entities (
      url TEXT PRIMARY KEY,
      body TEXT NOT NULL,
      cached_at INTEGER NOT NULL,
      ttl_ms INTEGER NOT NULL
    )
  ''');
  await db.execute('CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT)');
  await db.execute('''
    CREATE TABLE conflicts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      label TEXT,
      url TEXT,
      reason TEXT,
      at INTEGER NOT NULL,
      dropped INTEGER NOT NULL DEFAULT 1
    )
  ''');
}

final _photo = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 9, 8, 7, 6]);

/// A shift's worth of v1 queue: a check carrying its one photo in the old
/// single-attachment columns, then a plain write queued after it.
Future<void> _fillV1(Database db) async {
  await db.insert('pending_mutations', {
    'client_mutation_id': 'm-photo',
    'method': 'post',
    'url': '/api/c2o/assets/a-1/verify',
    'body': '{"result":"verified","photos":[{"url":"__pending_photo_0__"}]}',
    'label': 'Submit asset verification',
    'attempts': 2,
    'created_at': DateTime(2026, 10, 1, 9).millisecondsSinceEpoch,
    'attachment': _photo,
    'attachment_name': 'nameplate.jpg',
    'attachment_field': 'image',
    'placeholder': '__pending_photo_0__',
  });
  await db.insert('pending_mutations', {
    'client_mutation_id': 'm-plain',
    'method': 'patch',
    'url': '/api/fm/work-orders/w-1',
    'body': '{"status":"done"}',
    'label': 'Close work order',
    'attempts': 0,
    'created_at': DateTime(2026, 10, 1, 10).millisecondsSinceEpoch,
  });
  await db.insert('conflicts', {
    'label': 'Old write',
    'url': '/api/x',
    'reason': 'Refused',
    'at': DateTime(2026, 9, 30).millisecondsSinceEpoch,
    'dropped': 1,
  });
  await db.insert('sync_meta', {'key': 'lastFlush', 'value': '2026-10-01'});
}

Future<Map<String, Set<String>>> _shape(Database db) async {
  final tables = await db.rawQuery(
    "SELECT name, type FROM sqlite_master WHERE type IN ('table','index') "
    "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
  );
  final out = <String, Set<String>>{};
  for (final t in tables) {
    final name = t['name']! as String;
    if (t['type'] == 'index') {
      out.putIfAbsent('#indexes', () => {}).add(name);
      continue;
    }
    final cols = await db.rawQuery('PRAGMA table_info($name)');
    out[name] = {for (final c in cols) c['name']! as String};
  }
  return out;
}

void main() {
  late Directory dir;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fe_offline_db_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<Database> openAt(String name, int version, {OnDatabaseCreateFn? onCreate}) =>
      databaseFactoryFfi.openDatabase(
        '${dir.path}/$name',
        options: OpenDatabaseOptions(
          version: version,
          onCreate: onCreate,
          onUpgrade: OfflineDb.upgradeSchema,
        ),
      );

  test('a v1 queue reads back intact after upgrading to the current schema', () async {
    final v1 = await openAt('q.db', 1, onCreate: (db, _) => _createV1(db));
    await _fillV1(v1);
    await v1.close();

    final upgraded = await openAt('q.db', OfflineDb.schemaVersion);
    expect(await upgraded.getVersion(), OfflineDb.schemaVersion);
    final store = OfflineDb.wrap(upgraded);

    final queue = await store.listMutations();
    expect(queue.map((m) => m.clientMutationId), ['m-photo', 'm-plain'], reason: 'oldest first, none lost');

    final check = queue.first;
    expect(check.label, 'Submit asset verification');
    expect(check.attempts, 2);
    expect(check.body, {
      'result': 'verified',
      'photos': [
        {'url': '__pending_photo_0__'},
      ],
    });
    expect(check.attachments, hasLength(1), reason: 'the photo queued before FR-4.7 must not be dropped');
    expect(check.attachments.single.bytes, _photo);
    expect(check.attachments.single.fileName, 'nameplate.jpg');
    expect(check.attachments.single.field, 'image');
    expect(check.attachments.single.placeholder, '__pending_photo_0__');
    expect(check.entityType, isNull);

    expect(queue.last.attachments, isEmpty);
    expect(await store.countMutations(), 2);

    final conflicts = await store.listConflicts();
    expect(conflicts.single.reason, 'Refused');
    expect(await store.readMeta('lastFlush'), '2026-10-01');

    await upgraded.close();
  });

  test('after the upgrade the old rows keep working with new-version code', () async {
    final v1 = await openAt('q.db', 1, onCreate: (db, _) => _createV1(db));
    await _fillV1(v1);
    await v1.close();
    final upgraded = await openAt('q.db', OfflineDb.schemaVersion);
    final store = OfflineDb.wrap(upgraded);

    // A partial replay of the old row records its upload, FR-4.7-style.
    final legacy = (await store.listMutations()).first;
    await store.updateMutationAttachments(legacy.clientMutationId, [
      legacy.attachments.single.withUploadedUrl('https://files/nameplate.jpg'),
    ]);
    final resumed = (await store.listMutations()).first;
    expect(resumed.attachments.single.uploadedUrl, 'https://files/nameplate.jpg');

    // A new multi-photo check queues behind the old ones.
    await store.enqueue(
      PendingMutation(
        clientMutationId: 'm-new',
        method: 'post',
        url: '/api/c2o/assets/a-2/verify',
        body: const {'result': 'mismatch'},
        label: 'Submit asset verification',
        attempts: 0,
        createdAt: DateTime(2026, 10, 8),
        attachments: [
          PendingAttachment(bytes: _photo, fileName: 'a.jpg', field: 'image', placeholder: '__p0__'),
          PendingAttachment(bytes: _photo, fileName: 'b.jpg', field: 'image', placeholder: '__p1__'),
        ],
        entityType: 'Asset',
        entityId: 'a-2',
      ),
    );
    final all = await store.listMutations();
    expect(all.map((m) => m.clientMutationId), ['m-photo', 'm-plain', 'm-new']);
    expect(all.last.attachments, hasLength(2));

    // Tables added by later versions are usable on the upgraded file.
    await store.saveDraft('a-3', {
      'assetName': 'VLV-03',
      'claimedTag': 'TAG-3',
      'result': 'verified',
      'photos': [
        {'bytesBase64': 'AAAA', 'fileName': 'a.jpg'},
        {'bytesBase64': 'BBBB', 'fileName': 'b.jpg'},
      ],
    });
    // A draft saved before names were stored still lists, unnamed.
    await store.saveDraft('a-4', {'result': 'missing'});
    final left = await store.leftOnDevice();
    expect(left.queued, 3);
    final drafts = {for (final d in left.drafts) d.assetId: d};
    expect(drafts['a-3']!.assetName, 'VLV-03');
    expect(drafts['a-3']!.claimedTag, 'TAG-3');
    expect(drafts['a-3']!.photoCount, 2, reason: 'counted by SQLite, photos never decoded');
    expect(drafts['a-4']!.assetName, isNull);
    expect(drafts['a-4']!.photoCount, 0);
    expect(left.unsentLocal, 0);

    await upgraded.close();
  });

  test('every intermediate version upgrades to the same shape as a fresh install', () async {
    final fresh = await openAt('fresh.db', OfflineDb.schemaVersion, onCreate: (db, _) => OfflineDb.createSchema(db));
    final want = await _shape(fresh);
    await fresh.close();

    // v1 is the only historical schema kept verbatim; every later version
    // is reached from it with the app's own steps, then upgraded the rest
    // of the way, so a phone stuck on any release is covered.
    for (var from = 1; from < OfflineDb.schemaVersion; from++) {
      final name = 'v$from.db';
      final old = await databaseFactoryFfi.openDatabase(
        '${dir.path}/$name',
        options: OpenDatabaseOptions(
          version: from,
          onCreate: (db, _) async {
            await _createV1(db);
            if (from > 1) await OfflineDb.upgradeSchema(db, 1, from);
          },
        ),
      );
      await old.close();

      final upgraded = await openAt(name, OfflineDb.schemaVersion);
      final got = await _shape(upgraded);
      await upgraded.close();

      expect(got.keys.toSet(), want.keys.toSet(), reason: 'tables + indexes after upgrading from v$from');
      for (final table in want.keys) {
        expect(got[table], containsAll(want[table]!), reason: '$table columns after upgrading from v$from');
      }
    }
  });
}
