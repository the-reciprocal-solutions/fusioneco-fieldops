import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/offline/replay_hooks.dart';

/// PENDING P-008 (2): when the queue replays an `ArProgress` write, the floor's
/// progress must be re-read at once so the server's copy replaces a status it
/// refused. [ReplayHooks] is how a repository asks to hear about its replays.
void main() {
  group('ReplayHooks — per-entity follow-up after a queued write syncs', () {
    test('runs the hook once per distinct entity id of its type', () async {
      final hooks = ReplayHooks();
      final seen = <String>[];
      hooks.register('ArProgress', (id) async => seen.add(id));

      await hooks.runFor([
        (entityType: 'ArProgress', entityId: 'floor-1'),
        (entityType: 'ArProgress', entityId: 'floor-1'),
        (entityType: 'ArProgress', entityId: 'floor-2'),
      ]);

      expect(seen, ['floor-1', 'floor-2']);
    });

    test('ignores other entity types and writes without an entity id', () async {
      final hooks = ReplayHooks();
      final seen = <String>[];
      hooks.register('ArProgress', (id) async => seen.add(id));

      await hooks.runFor([
        (entityType: 'ArMarker', entityId: 'm-1'),
        (entityType: null, entityId: 'x'),
        (entityType: 'ArProgress', entityId: null),
      ]);

      expect(seen, isEmpty);
    });

    test('a failing hook does not stop the others (flush must not throw)', () async {
      final hooks = ReplayHooks();
      final seen = <String>[];
      hooks.register('ArProgress', (id) async {
        if (id == 'floor-1') throw StateError('no signal');
        seen.add(id);
      });

      await hooks.runFor([
        (entityType: 'ArProgress', entityId: 'floor-1'),
        (entityType: 'ArProgress', entityId: 'floor-2'),
      ]);

      expect(seen, ['floor-2']);
    });

    test('registering again replaces the hook (a rebuilt provider must not double-fire)', () async {
      final hooks = ReplayHooks();
      var first = 0;
      var second = 0;
      hooks.register('ArProgress', (_) async => first++);
      hooks.register('ArProgress', (_) async => second++);

      await hooks.runFor([(entityType: 'ArProgress', entityId: 'floor-1')]);

      expect(first, 0);
      expect(second, 1);
    });
  });
}
