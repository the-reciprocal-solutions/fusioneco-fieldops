import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Developer-only record of snag data-integrity events (2026-10-10, owner
/// iPhone report: a walk shot landed on another snag; snags and their
/// status went missing). **Never shown to users** — no screen reads it. It
/// exists so the next "my snag went somewhere else" can be answered from the
/// phone instead of guessed: what the repository refused, kept, repaired or
/// could not explain.
///
/// One JSON object per line in `snag_media/diag/integrity.jsonl` (the media
/// folder survives sign-out, unlike `sync_meta`), newest last, capped at
/// [maxLines]. In debug builds each event is also printed with a
/// `[snag-integrity]` prefix. Writing never throws: a diagnostics failure
/// must not break a save.
class SnagIntegrityLog {
  SnagIntegrityLog(this._file);

  final Future<File> Function() _file;

  static const maxLines = 500;

  /// Event kinds, for grepping the file.
  static const idReused = 'id-reused';
  static const staleWriteAvoided = 'stale-write-avoided';
  static const deviceOnlyEvidenceKept = 'device-only-evidence-kept';
  static const pruneKept = 'prune-kept';
  static const repairedFromServer = 'repaired-from-server';
  static const refusedWriteResynced = 'refused-write-resynced';
  static const possibleMisattached = 'possible-misattached';
  static const afterPhotoWithoutReady = 'after-photo-without-ready';
  static const clockSkewFullPull = 'clock-skew-full-pull';

  /// [dedupeKey]: when set, an event with the same key already in the file
  /// is not written again (repair scans run on every full pull).
  Future<void> record(
    String kind, {
    String? snagId,
    Map<String, Object?> detail = const {},
    String? dedupeKey,
  }) async {
    final event = <String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'kind': kind,
      'snagId': ?snagId,
      'key': ?dedupeKey,
      if (detail.isNotEmpty) 'detail': detail,
    };
    if (kDebugMode) debugPrint('[snag-integrity] ${jsonEncode(event)}');
    try {
      final file = await _file();
      final lines = file.existsSync() ? await file.readAsLines() : <String>[];
      if (dedupeKey != null && lines.any((l) => l.contains('"key":${jsonEncode(dedupeKey)}'))) return;
      lines.add(jsonEncode(event));
      final kept = lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
      if (!file.parent.existsSync()) await file.parent.create(recursive: true);
      await file.writeAsString('${kept.join('\n')}\n', flush: true);
    } catch (_) {
      // Diagnostics only.
    }
  }

  /// Every event, oldest first. Empty when there is no file yet.
  Future<List<Map<String, dynamic>>> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const [];
      return [
        for (final l in await file.readAsLines())
          if (l.trim().isNotEmpty) Map<String, dynamic>.from(jsonDecode(l) as Map),
      ];
    } catch (_) {
      return const [];
    }
  }
}
