import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bim_viewer/bim_view_wire.dart';
import 'providers.dart';

/// How the model viewer lays itself out (docs/bim-viewer.md §5.5).
///
/// - [split]: 3D and plan side by side (landscape) or stacked (portrait),
///   with a draggable divider.
/// - [pip]: 3D full screen, the plan as a floating mini-map in a corner
///   (Dalux's walk view with the drawing inset).
/// - [model] / [plan]: one pane, full screen.
enum BimViewLayout { split, pip, model, plan }

/// Mini-map size, as a share of the pane's shorter side.
enum BimPipSize {
  small(0.34),
  medium(0.46),
  large(0.62);

  const BimPipSize(this.share);
  final double share;

  BimPipSize get next => BimPipSize.values[(index + 1) % BimPipSize.values.length];
}

/// Corners, reading order: top-start, top-end, bottom-start, bottom-end.
enum BimPipCorner { topStart, topEnd, bottomStart, bottomEnd }

/// The viewer's per-phone UI choices, remembered between visits: a
/// technician who likes the mini-map in the bottom corner shouldn't set it
/// up on every floor. Stored as one JSON pref in the AR pack store (the same
/// small key/value table the AR Demo flag lives in), so a logout or a
/// missing DB (widget tests) just falls back to the defaults.
class BimViewerPrefs {
  const BimViewerPrefs({
    this.layout = BimViewLayout.split,
    this.splitRatio = 0.56,
    this.swapped = false,
    this.pipCorner = BimPipCorner.bottomEnd,
    this.pipSize = BimPipSize.medium,
    this.layers = const BimLayerState(),
    this.cutHeightM = 2.2,
    this.followInWalk = true,
  });

  final BimViewLayout layout;

  /// Share of the split taken by the FIRST pane (3D, or the plan when
  /// [swapped]). Clamped to [minRatio]…[maxRatio].
  final double splitRatio;

  /// Plan first (top / start), 3D second.
  final bool swapped;
  final BimPipCorner pipCorner;
  final BimPipSize pipSize;
  final BimLayerState layers;

  /// Orbit section cut above the floor datum, metres.
  final double cutHeightM;

  /// Keep the walker's dot in view on the plan.
  final bool followInWalk;

  static const minRatio = 0.22;
  static const maxRatio = 0.78;
  static const minCutM = 0.8;
  static const maxCutM = 4.5;

  BimViewerPrefs copyWith({
    BimViewLayout? layout,
    double? splitRatio,
    bool? swapped,
    BimPipCorner? pipCorner,
    BimPipSize? pipSize,
    BimLayerState? layers,
    double? cutHeightM,
    bool? followInWalk,
  }) =>
      BimViewerPrefs(
        layout: layout ?? this.layout,
        splitRatio: (splitRatio ?? this.splitRatio).clamp(minRatio, maxRatio).toDouble(),
        swapped: swapped ?? this.swapped,
        pipCorner: pipCorner ?? this.pipCorner,
        pipSize: pipSize ?? this.pipSize,
        layers: layers ?? this.layers,
        cutHeightM: (cutHeightM ?? this.cutHeightM).clamp(minCutM, maxCutM).toDouble(),
        followInWalk: followInWalk ?? this.followInWalk,
      );

  Map<String, Object?> toJson() => {
        'layout': layout.name,
        'splitRatio': splitRatio,
        'swapped': swapped,
        'pipCorner': pipCorner.name,
        'pipSize': pipSize.name,
        'layers': layers.toArgs(),
        'cutHeightM': cutHeightM,
        'followInWalk': followInWalk,
      };

  /// Tolerant: anything missing or malformed keeps its default, so a pref
  /// written by an older app version never breaks the screen.
  static BimViewerPrefs fromJson(Object? raw) {
    const d = BimViewerPrefs();
    if (raw is! Map) return d;
    T pick<T extends Enum>(List<T> values, Object? v, T fallback) =>
        values.where((e) => e.name == v).firstOrNull ?? fallback;
    bool flag(Map m, String k, bool fallback) => m[k] is bool ? m[k] as bool : fallback;
    final l = raw['layers'];
    final layers = l is Map
        ? BimLayerState(
            mep: flag(l, 'mep', true),
            structure: flag(l, 'structure', true),
            architecture: flag(l, 'architecture', true),
            architectureSolid: flag(l, 'architecture_solid', true),
            massing: flag(l, 'massing', true),
            xray: flag(l, 'xray', false),
            cut: flag(l, 'cut', true),
          )
        : d.layers;
    return d.copyWith(
      layout: pick(BimViewLayout.values, raw['layout'], d.layout),
      splitRatio: raw['splitRatio'] is num ? (raw['splitRatio'] as num).toDouble() : null,
      swapped: raw['swapped'] is bool ? raw['swapped'] as bool : null,
      pipCorner: pick(BimPipCorner.values, raw['pipCorner'], d.pipCorner),
      pipSize: pick(BimPipSize.values, raw['pipSize'], d.pipSize),
      layers: layers,
      cutHeightM: raw['cutHeightM'] is num ? (raw['cutHeightM'] as num).toDouble() : null,
      followInWalk: raw['followInWalk'] is bool ? raw['followInWalk'] as bool : null,
    );
  }

  /// The corner nearest a point, for snapping a dragged mini-map.
  static BimPipCorner cornerNearest(double x, double y, double width, double height, {required bool rtl}) {
    final right = x > width / 2;
    final bottom = y > height / 2;
    final end = rtl ? !right : right;
    return bottom
        ? (end ? BimPipCorner.bottomEnd : BimPipCorner.bottomStart)
        : (end ? BimPipCorner.topEnd : BimPipCorner.topStart);
  }
}

class BimViewerPrefsController extends Notifier<BimViewerPrefs> {
  static const _key = 'bim_viewer.prefs';
  Timer? _saveTimer;
  final _restored = Completer<void>();

  /// Completes once the saved prefs are read (or found missing), so the
  /// viewer opens with the user's layout, not a flash of the default.
  Future<void> get ready => _restored.future;

  @override
  BimViewerPrefs build() {
    ref.onDispose(() => _saveTimer?.cancel());
    unawaited(_restore());
    return const BimViewerPrefs();
  }

  Future<void> _restore() async {
    try {
      final raw = await ref.read(arPackStoreProvider).getArPref(_key);
      if (raw != null) state = BimViewerPrefs.fromJson(jsonDecode(raw));
    } catch (_) {
      // No DB (widget test) or a corrupt pref: defaults.
    } finally {
      if (!_restored.isCompleted) _restored.complete();
    }
  }

  void update(BimViewerPrefs Function(BimViewerPrefs p) change) {
    state = change(state);
    // A dragged divider updates many times a second; write once it rests.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () async {
      try {
        await ref.read(arPackStoreProvider).setArPref(_key, jsonEncode(state.toJson()));
      } catch (_) {}
    });
  }
}

final bimViewerPrefsProvider =
    NotifierProvider<BimViewerPrefsController, BimViewerPrefs>(BimViewerPrefsController.new);
