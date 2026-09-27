import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// How the model gets placed (docs/ar-setup-and-gamma-parity.md §2.9, AR-54).
/// The wire name is what `/ar/session?method=` carries.
enum ArPlaceMethod {
  board('board'),
  corners('corners'),
  grid('grid'),
  resume('resume'),
  gnss('gnss');

  const ArPlaceMethod(this.wire);
  final String wire;

  static ArPlaceMethod? parse(String? wire) {
    for (final m in values) {
      if (m.wire == wire) return m;
    }
    return null;
  }
}

class ArPrefsState {
  const ArPrefsState({
    this.demo = false,
    this.methodByFloor = const {},
    this.loaded = false,
    this.coachSeen = true,
    this.sunlight = false,
  });

  /// Demo mode: sample building + FakeArEngine, with a visible banner.
  final bool demo;

  /// "Remember my choice for Level 3" — the chooser is skipped next time.
  final Map<String, ArPlaceMethod> methodByFloor;
  final bool loaded;

  /// The first-time AR tips (sweep, snap, check) were seen or skipped.
  /// True until the saved value is read, so the coach never flashes up on a
  /// phone that already dismissed it; a missing value then reads as "not
  /// seen" and the tips show once.
  final bool coachSeen;

  /// Sunlight mode: high-contrast AR chrome for bright sites (opaque
  /// near-black controls, white text, white outline — `ArChromeStyle`).
  /// Off by default. Public so the model side can boost its colours too:
  /// watch `arPrefsProvider.select((s) => s.sunlight)`.
  final bool sunlight;

  ArPrefsState copyWith({
    bool? demo,
    Map<String, ArPlaceMethod>? methodByFloor,
    bool? loaded,
    bool? coachSeen,
    bool? sunlight,
  }) => ArPrefsState(
    demo: demo ?? this.demo,
    methodByFloor: methodByFloor ?? this.methodByFloor,
    loaded: loaded ?? this.loaded,
    coachSeen: coachSeen ?? this.coachSeen,
    sunlight: sunlight ?? this.sunlight,
  );
}

/// Per-device AR preferences in the offline DB's `ar_prefs` table (schema
/// v10, [ArPackStore]), so they survive restarts and are wiped with the rest
/// of the device state on logout. The method key is the one
/// `ArRepository.rememberMethod` uses (`method:<floorId>`), so both agree.
///
/// The remembered method is stored per floor on purpose: a plant room with
/// two boards wants "scan", the open-plan floor above wants "corners".
class ArPrefsController extends Notifier<ArPrefsState> {
  static const _demoKey = 'demo';

  /// Versioned: new tips for a changed flow get a new key and show again.
  static const _coachKey = 'coach:v1';
  static const _sunlightKey = 'sunlight';
  static const _methodPrefix = 'method:';

  final _restored = Completer<void>();

  /// Completes once the saved Demo flag is read — a session must not start
  /// "live" in the moment before a saved "Demo on" arrives.
  Future<void> get ready => _restored.future;

  @override
  ArPrefsState build() {
    unawaited(_restore());
    return const ArPrefsState();
  }

  Future<void> _restore() async {
    // Let build() return first: with no DB (a widget test) the read below
    // throws synchronously, and the catch would touch `state` before it
    // exists ("uninitialized provider").
    await Future<void>.value();
    try {
      final store = ref.read(arPackStoreProvider);
      final demo = await store.getArPref(_demoKey);
      final coach = await store.getArPref(_coachKey);
      final sunlight = await store.getArPref(_sunlightKey);
      state = state.copyWith(demo: demo == '1', coachSeen: coach == '1', sunlight: sunlight == '1', loaded: true);
    } catch (_) {
      // No DB (a widget test) — defaults are fine (tips count as seen).
      state = state.copyWith(loaded: true);
    } finally {
      if (!_restored.isCompleted) _restored.complete();
    }
  }

  Future<void> setDemo(bool on) async {
    state = state.copyWith(demo: on);
    try {
      await ref.read(arPackStoreProvider).setArPref(_demoKey, on ? '1' : '0');
    } catch (_) {
      // Best effort: the toggle still works for this run.
    }
  }

  /// Marks the first-time tips as seen ([seen] false shows them again: the
  /// menu's "Show tips").
  Future<void> setCoachSeen(bool seen) async {
    state = state.copyWith(coachSeen: seen);
    try {
      await ref.read(arPackStoreProvider).setArPref(_coachKey, seen ? '1' : '0');
    } catch (_) {
      // Best effort: worst case the tips show once more.
    }
  }

  /// Sunlight mode on or off (the menu's "Sunlight mode", the method
  /// chooser's sun button). Saved per device like Demo.
  Future<void> setSunlight(bool on) async {
    state = state.copyWith(sunlight: on);
    try {
      await ref.read(arPackStoreProvider).setArPref(_sunlightKey, on ? '1' : '0');
    } catch (_) {
      // Best effort: the toggle still works for this run.
    }
  }

  /// The remembered method for [floorId], reading through to the DB once.
  Future<ArPlaceMethod?> rememberedMethod(String floorId) async {
    final cached = state.methodByFloor[floorId];
    if (cached != null) return cached;
    try {
      final raw = await ref.read(arPackStoreProvider).getArPref('$_methodPrefix$floorId');
      final method = ArPlaceMethod.parse(raw);
      if (method != null) {
        state = state.copyWith(methodByFloor: {...state.methodByFloor, floorId: method});
      }
      return method;
    } catch (_) {
      return null;
    }
  }

  /// [method] null forgets the choice ("ask me next time").
  Future<void> rememberMethod(String floorId, ArPlaceMethod? method) async {
    final next = {...state.methodByFloor};
    if (method == null) {
      next.remove(floorId);
    } else {
      next[floorId] = method;
    }
    state = state.copyWith(methodByFloor: next);
    try {
      await ref.read(arPackStoreProvider).setArPref('$_methodPrefix$floorId', method?.wire);
    } catch (_) {
      // Best effort.
    }
  }
}

final arPrefsProvider = NotifierProvider<ArPrefsController, ArPrefsState>(ArPrefsController.new);
