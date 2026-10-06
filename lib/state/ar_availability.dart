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

/// Does any building this technician can see have a published AR model?
/// False when the client switched AR off. Says what the dashboard card
/// offers; it does not decide whether the card shows ([arCardModeProvider]).
final arAnyBuildingProvider = FutureProvider.autoDispose<bool>((ref) async {
  final enabled = ref.watch(authControllerProvider.select((s) => s.permissions.isArView)) != false;
  if (!enabled) return false;
  return ref.watch(arRepositoryProvider).anyArBuilding();
});

/// What the dashboard's AR card shows.
enum ArCardMode {
  /// The client explicitly set `isArView = false`.
  hidden,

  /// Still asking whether a published model exists: the card shows its
  /// usual actions without the "no model" line, so it doesn't flicker.
  checking,

  /// At least one building has a published AR model.
  models,

  /// No published model anywhere: "No AR model for your buildings yet",
  /// with the demo room and "Scan an AR board".
  noModels,
}

/// AR is on by default on the phone (owner, 2026-10-06: "make AR active by
/// default"). This supersedes the 2026-09-27 rule that the card shows only
/// for clients with a published model: now only an explicit
/// `isArView == false` hides it. "Show in AR" doors on assets and orders
/// still need a model for that floor ([arDoorAvailableProvider]) — a door
/// into an empty AR screen helps nobody — and never replace "View in 3D".
final arCardModeProvider = Provider.autoDispose<ArCardMode>((ref) {
  final enabled = ref.watch(authControllerProvider.select((s) => s.permissions.isArView)) != false;
  if (!enabled) return ArCardMode.hidden;
  final any = ref.watch(arAnyBuildingProvider);
  return switch (any) {
    AsyncData(:final value) => value ? ArCardMode.models : ArCardMode.noModels,
    AsyncError() => ArCardMode.noModels,
    _ => ArCardMode.checking,
  };
});
