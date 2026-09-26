import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'providers.dart';

/// Whether a "Show in AR" door may be drawn (the user asked, 2026-09-27: AR is
/// not sold to every client, so never swap the app's model/3D buttons for AR —
/// show AR only where it is enabled for the building).
///
/// Two switches, both must be on:
/// 1. the client's `isArView` flag from /api/auth/config (opt-out: only an
///    explicit `false` hides it), and
/// 2. the floor (or the asset's floor) has a published AR model —
///    `ArRepository.isArAvailable`, cached for offline use.
///
/// Loading and errors count as "not available": a door that appears late is
/// fine, a door into an empty AR screen is not.
final arDoorAvailableProvider =
    FutureProvider.autoDispose.family<bool, ({String? floorId, String? assetId})>((ref, key) async {
  final enabled = ref.watch(authControllerProvider.select((s) => s.permissions.isArView)) != false;
  if (!enabled) return false;
  return ref.watch(arRepositoryProvider).isArAvailable(floorId: key.floorId, assetId: key.assetId);
});

/// The dashboard's AR card: client flag on and at least one building with AR.
final arAnyBuildingProvider = FutureProvider.autoDispose<bool>((ref) async {
  final enabled = ref.watch(authControllerProvider.select((s) => s.permissions.isArView)) != false;
  if (!enabled) return false;
  return ref.watch(arRepositoryProvider).anyArBuilding();
});
