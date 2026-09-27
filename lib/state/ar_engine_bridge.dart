import 'package:flutter/widgets.dart';

import '../core/ar/ar_engine.dart';
import '../core/ar/ar_view.dart';
import '../core/ar/fake_ar_engine.dart';
import '../core/ar/tile_residency.dart';
import '../core/ar/vec.dart';
import '../domain/ar_models.dart' show ManifestTile;
import 'ar_view_models.dart' show ArGridLine, ArPickHit, ArPinSpec;

/// The single place the AR screens construct `lib/core/ar` engine types and
/// read the manifest tile type. The screens and controllers were written in
/// parallel with the core (contract v1); keeping every constructor call here
/// means a signature change in the core is a one-file fix.

/// Manifest tiles stay opaque to the UI: sizes and hashes come from here.
typedef ArTile = ManifestTile;

String arTileHash(ArTile t) => t.hash;
int arTileBytes(ArTile t) => t.bytes;
String arTileBuildId(ArTile t) => t.buildId;
Vec3 arTileCentre(ArTile t) => t.centre;

TileResidency makeResidency() => const TileResidency();

TileRef makeTileRef(String hash, String path) => TileRef(hash: hash, path: path);

LayerState makeLayerState({
  required bool mep,
  required bool structure,
  required bool architecture,
  required double opacity,
  double? sectionY,
  bool contrast = false,
}) => LayerState(
  mep: mep,
  structure: structure,
  architecture: architecture,
  opacity: opacity,
  sectionY: sectionY,
  contrast: contrast,
);

GridLineRef makeGridLineRef(ArGridLine g) => GridLineRef(name: g.name, p0: g.p0, p1: g.p1);

ArPin makePin(ArPinSpec p) => ArPin(
  id: p.id,
  posTile: p.posTile,
  label: p.label ?? '',
  kind: p.kind,
  normalTile: p.normalTile,
);

ArPickHit readPick(PickResult r) => ArPickHit(
  featureId: r.featureId,
  buildId: r.buildId,
  hitTile: r.hitPointTile,
  distanceM: r.distanceM,
);

ArCapabilities unsupportedCapabilities(String reason) => ArCapabilities.unsupported(reason);

/// Demo mode's engine: tracking only ([FakeArScript.manual]). Sightings in
/// Demo mode come from `ArDemoDirector`, which knows the sample building
/// the screens show; the fake's own scripted story plays against a
/// different sample floor, so it is left silent here.
ArEngine makeFakeEngine() => FakeArEngine(script: FakeArScript.manual);

/// The camera layer: the native AR view when the engine is supported,
/// otherwise core's stand-in surface; Demo mode passes its sample room as
/// [child], drawn on that surface.
Widget buildArView({
  ArCapabilities? capabilities,
  bool demo = false,
  void Function(int id)? onCreated,
  Widget? child,
}) => ArView(
  supported: (capabilities?.supported ?? false) && capabilities?.platform != 'demo',
  demo: demo,
  onPlatformViewCreated: onCreated,
  child: child,
);
