import 'dart:async';

// Uint8List comes through package:flutter/services.dart (restoration.dart
// re-exports it); a direct dart:typed_data import trips `unnecessary_import`.
import 'package:flutter/services.dart';

import 'ar_engine.dart';
import 'vec.dart';

/// Thrown by a command when the native engine refused it or isn't there.
/// [capabilities] never throws; every other command can.
class ArEngineException implements Exception {
  const ArEngineException(this.code, [this.message = '']);

  final String code;
  final String message;

  @override
  String toString() => 'ArEngineException($code): $message';
}

/// [ArEngine] over the `packages/fe_ar` plugin (CONTRACT C8).
///
/// Wire contract, shared with the Kotlin and Swift halves — change all
/// three together:
///
/// - `MethodChannel('fusioneco/ar')`; method name = the [ArEngine] command
///   name. Arguments are a map whose keys are the Dart parameter names:
///   `loadTiles {tiles: [{hash, path}]}` · `unloadTiles {hashes}` ·
///   `setModelTransform {arFromTile: [16], easeMs}` ·
///   `setFeatureState {rgba: Uint8List, width, buildId?}` ·
///   `setLayers {mep, structure, architecture, opacity, sectionY}` ·
///   `setTarget {featureIds: [int] | null, buildId?}` ·
///   `setGridLines {lines: [{name, p0: [x,z], p1: [x,z]}], floorY}` ·
///   `setPins {pins: [{id, posTile, label, kind, colorRgb, normalTile}]}` ·
///   `detectCornerAt {x, y}` → corner map or null · `pick {x, y}` →
///   `{featureId, hitPointTile, distanceM, tileHash?, buildId?}` or null ·
///   `capture` → JPEG path or null · `capabilities` →
///   `{supported, depth, lidar, recording, platform, reason}`.
/// - Vectors are `[x, y, z]` lists, matrices 16-number **column-major**
///   lists, the feature state a `Uint8List` (StandardMessageCodec).
/// - `EventChannel('fusioneco/ar/events')`: maps with `type` in
///   `tracking | marker | corner | anchor | pose | targetScreen | error`
///   and fields named like the Dart event classes ([ArEvent.fromMap]).
/// - Platform view type `fusioneco/ar/view` ([ArView]).
///
/// A build without the plugin (or a platform with no engine) answers every
/// call with `MissingPluginException`; [capabilities] turns that into
/// `supported: false, reason: 'engine-not-installed'`, so the app offers the
/// floor plan or Demo mode instead of crashing.
class ChannelArEngine implements ArEngine {
  ChannelArEngine({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel(methodChannelName),
        _eventChannel = events ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'fusioneco/ar';
  static const eventChannelName = 'fusioneco/ar/events';
  static const viewType = 'fusioneco/ar/view';

  final MethodChannel _methods;
  final EventChannel _eventChannel;
  Stream<ArEvent>? _events;

  @override
  Future<ArCapabilities> capabilities() async {
    try {
      final result = await _methods.invokeMethod<Object?>('capabilities');
      if (result is Map) return ArCapabilities.fromMap(result);
      return const ArCapabilities.unsupported('bad-capabilities');
    } on MissingPluginException {
      return const ArCapabilities.unsupported(ArCapabilities.engineNotInstalled);
    } on PlatformException catch (e) {
      return ArCapabilities.unsupported(e.code);
    }
  }

  @override
  Future<void> startSession() => _call('startSession');

  @override
  Future<void> loadTiles(List<TileRef> tiles) =>
      _call('loadTiles', {'tiles': [for (final t in tiles) t.toMap()]});

  @override
  Future<void> unloadTiles(List<String> hashes) => _call('unloadTiles', {'hashes': hashes});

  @override
  Future<void> setModelTransform(Mat4 arFromTile, {int easeMs = 300}) =>
      _call('setModelTransform', {'arFromTile': arFromTile.toList(), 'easeMs': easeMs});

  @override
  Future<void> setFeatureState(Uint8List rgba, int width, {String? buildId}) => _call('setFeatureState', {
        'rgba': rgba,
        'width': width,
        if (buildId != null) 'buildId': buildId,
      });

  @override
  Future<void> setLayers(LayerState s) => _call('setLayers', s.toMap());

  @override
  Future<void> setTarget(List<int>? featureIds, {String? buildId}) => _call('setTarget', {
        'featureIds': featureIds,
        if (buildId != null) 'buildId': buildId,
      });

  @override
  Future<void> setGridLines(List<GridLineRef> lines, double floorY) => _call('setGridLines', {
        'lines': [for (final l in lines) l.toMap()],
        'floorY': floorY,
      });

  @override
  Future<void> setPins(List<ArPin> pins) =>
      _call('setPins', {'pins': [for (final p in pins) p.toMap()]});

  @override
  Future<CornerSeenEvent?> detectCornerAt(double x, double y) async =>
      CornerSeenEvent.tryParse(await _call<Object?>('detectCornerAt', {'x': x, 'y': y}));

  @override
  Future<String?> anchorAt(Vec3 posAr) async {
    try {
      final id = await _call<Object?>('anchorAt', {'posAr': posAr.toList()});
      return id?.toString();
    } on ArEngineException {
      return null; // an older plugin without the extension
    }
  }

  @override
  Future<PickResult?> pick(double x, double y) async =>
      PickResult.fromMap(await _call<Object?>('pick', {'x': x, 'y': y}));

  @override
  Future<String?> capture() async {
    final path = await _call<Object?>('capture');
    return path is String && path.isNotEmpty ? path : null;
  }

  @override
  Future<void> pause() => _call('pause');

  @override
  Future<void> resume() => _call('resume');

  @override
  Future<void> stop() => _call('stop');

  /// Broadcast; a malformed or plugin-error event arrives as an
  /// [ArErrorEvent] rather than an error on the stream, so one bad event
  /// never tears down a listener mid-session.
  @override
  Stream<ArEvent> get events => _events ??= _eventChannel.receiveBroadcastStream().transform(
        StreamTransformer<dynamic, ArEvent>.fromHandlers(
          handleData: (data, sink) {
            final event = ArEvent.fromMap(data);
            if (event != null) sink.add(event);
          },
          handleError: (error, stack, sink) {
            sink.add(ArErrorEvent(
              code: error is PlatformException
                  ? error.code
                  : error is MissingPluginException
                      ? ArCapabilities.engineNotInstalled
                      : 'event-channel',
              detail: '$error',
            ));
          },
        ),
      );

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw ArEngineException(ArCapabilities.engineNotInstalled, method);
    } on PlatformException catch (e) {
      throw ArEngineException(e.code, e.message ?? method);
    }
  }
}
