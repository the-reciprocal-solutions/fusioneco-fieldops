import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/offline/sign_out_wipe.dart';

/// PENDING P-002: `logout()` (manual, the 24h timer, any 401) wiped the whole
/// offline DB whenever the queue was empty — including snags the server had
/// refused (kept on the phone as `local_only`), unsent capture drafts and the
/// conflict log. The sign-out wipe may clear server copies, never unsent work.
class _RecordingExecutor implements WipeExecutor {
  final deletes = <({String table, String? where})>[];

  @override
  Future<void> deleteRows(String table, {String? where}) async {
    deletes.add((table: table, where: where));
  }
}

void main() {
  group('runSignOutWipe — clears server copies, keeps unsent work', () {
    late _RecordingExecutor exec;

    setUp(() async {
      exec = _RecordingExecutor();
      await runSignOutWipe(exec);
    });

    test('never touches the queue, the conflict log, drafts or tag reports', () {
      final touched = exec.deletes.map((d) => d.table).toSet();
      for (final kept in [
        'pending_mutations',
        'conflicts',
        'verification_drafts',
        'tag_issue_reports',
      ]) {
        expect(touched, isNot(contains(kept)), reason: '$kept holds unsent work');
      }
    });

    test('snags, surveys and AR markers lose only rows the server already has', () {
      for (final table in ['snags', 'snag_surveys', 'ar_markers']) {
        final rows = exec.deletes.where((d) => d.table == table).toList();
        expect(rows, hasLength(1), reason: table);
        expect(rows.single.where, 'local_only = 0', reason: table);
      }
    });

    test('AR progress keeps rows still ahead of the server (pending)', () {
      final rows = exec.deletes.where((d) => d.table == 'ar_progress').toList();
      expect(rows, hasLength(1));
      expect(rows.single.where, 'pending = 0');
    });

    test('pure server caches are cleared whole', () {
      for (final table in ['cached_entities', 'c2o_assets', 'route_packs', 'ar_manifests', 'ar_tiles']) {
        expect(
          exec.deletes.where((d) => d.table == table && d.where == null),
          hasLength(1),
          reason: table,
        );
      }
    });
  });

  test('every table the offline DB creates is classified (kept or wiped)', () {
    // A new table must be a deliberate decision: wiping unsent work loses
    // field data, keeping a cache leaks one user's data to the next.
    final source = File('lib/core/offline/offline_db.dart').readAsStringSync();
    final created = RegExp(r'CREATE TABLE (?:IF NOT EXISTS )?(\w+)')
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toSet();
    final wiped = kSignOutWipe.map((s) => s.table).toSet();

    expect(created, isNotEmpty);
    expect(wiped.intersection(kKeptOnSignOut), isEmpty);
    expect(
      created.difference(wiped.union(kKeptOnSignOut)),
      isEmpty,
      reason: 'unclassified tables — add them to kSignOutWipe or kKeptOnSignOut',
    );
  });
}
