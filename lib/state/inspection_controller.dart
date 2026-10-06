import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/inspection/conditional_logic.dart';
import '../core/inspection/inspection_send_state.dart';
import '../core/offline/offline_db.dart' show PendingMutation;
import '../data/inspection_repository.dart';
import '../domain/inspection.dart';
import 'providers.dart';

final inspectionRepositoryProvider = Provider<InspectionRepository>((ref) {
  final sync = ref.watch(syncClientProvider);
  final repo = InspectionRepository(sync);
  // 2026-10-06 — a queued submit that syncs clears the answers kept on the
  // phone; one that fails on replay records why (check-in needed, refused…)
  // for the form banner and the list flag. One hook per entity type.
  void bump() => ref.read(inspectionSendTickProvider.notifier).state++;
  sync.onReplayed(InspectionRepository.entityType, (id) async {
    await repo.afterReplay(id);
    bump();
  });
  sync.onReplayFailed(InspectionRepository.entityType, (id, failure) async {
    await repo.afterReplayFailed(id, failure);
    bump();
  });
  return repo;
});

/// Bumped after every change to a kept submit (`sync_meta` is not part of
/// the queue, so [queueChangedProvider] alone would miss a refusal).
final inspectionSendTickProvider = StateProvider<int>((ref) => 0);

/// Where this inspection's last submit is: null when there is nothing to say
/// (never submitted from this phone, or the server has it).
final inspectionSendStatusProvider =
    FutureProvider.family<InspectionSendStatus?, ({String id, String? serverStatus})>((ref, key) async {
      ref.watch(inspectionSendTickProvider);
      final queue = await ref.watch(pendingMutationsProvider.future);
      final flushing = ref.watch(syncProgressProvider) != null;
      final queued = queue.any(
        (m) => m.entityType == InspectionRepository.entityType && m.entityId == key.id,
      );
      final draft = await ref.read(inspectionRepositoryProvider).readDraft(key.id);
      return inspectionSendStatus(
        queued: queued,
        flushing: flushing,
        draft: draft,
        serverStatus: key.serverStatus,
      );
    });

/// The id of the queued submit for [assignmentId], for a Retry tap.
String? queuedSubmitId(List<PendingMutation> queue, String assignmentId) {
  for (final m in queue) {
    if (m.entityType == InspectionRepository.entityType && m.entityId == assignmentId) {
      return m.clientMutationId;
    }
  }
  return null;
}

/// The assigned-inspections list. A queued submission flushing (or being
/// dropped as a conflict) moves an assignment from pending to completed
/// without this provider knowing, so it refetches on every queue change —
/// same reasoning as `OrderDetailController`.
final assignedInspectionsProvider =
    FutureProvider<List<InspectionAssignmentSummary>>((ref) async {
      ref.watch(queueChangedProvider);
      return ref.read(inspectionRepositoryProvider).listAssigned();
    });

class InspectionDetailController
    extends FamilyAsyncNotifier<InspectionAssignmentDetail, String> {
  var _disposed = false;

  @override
  Future<InspectionAssignmentDetail> build(String assignmentId) {
    ref.onDispose(() => _disposed = true);
    ref.listen(queueChangedProvider, (_, _) => refresh());
    return ref.read(inspectionRepositoryProvider).detail(assignmentId);
  }

  Future<void> refresh() async {
    final result = await AsyncValue.guard(
      () => ref.read(inspectionRepositoryProvider).detail(arg),
    );
    if (_disposed) return;
    state = result;
  }

  /// Required fields the server won't accept blank, evaluated against the
  /// same conditional show/hide/require engine the form screen renders
  /// with (`visibleFieldsFor`) — a hidden field is never required, and a
  /// field a rule has `require`d is checked even if the schema itself
  /// didn't mark it required. Server-side (`findMissingRequiredFields` in
  /// `technicianInspectionController.ts`) still uses the cruder "skip any
  /// conditional-rule target" fallback, so it stays a conservative backstop
  /// under this more accurate client check, never a stricter one.
  List<String> missingRequiredFields(Map<String, dynamic> responseData) {
    final schema = state.valueOrNull?.schema;
    if (schema == null) return const [];

    final missing = <String>[];
    for (final field in visibleFieldsFor(schema, responseData)) {
      if (!field.required) continue;
      switch (field.type) {
        case InspectionFieldType.panel:
        case InspectionFieldType.html:
        case InspectionFieldType.button:
        case InspectionFieldType.unsupported:
          // Never blockable — mirrors the web, which has no meaningful
          // "filled" state for these (a latent web bug lets `required`
          // block `html`/`panel` submission there; not worth replicating).
          continue;
        case InspectionFieldType.photo:
        case InspectionFieldType.signature:
          final value = responseData[field.key];
          final hasUploaded =
              value is Map &&
              value['values'] is List &&
              (value['values'] as List).any(
                (v) => v is Map && v['uploadStatus'] == 'uploaded',
              );
          if (!hasUploaded) missing.add(field.label);
        case InspectionFieldType.selectboxes:
          final value = responseData[field.key];
          final anyChecked = value is Map && value.values.any((v) => v == true);
          if (!anyChecked) missing.add(field.label);
        case InspectionFieldType.survey:
          final value = responseData[field.key];
          final allAnswered =
              value is Map && field.surveyRows.every((row) => value.containsKey(row.value));
          if (!allAnswered) missing.add(field.label);
        case InspectionFieldType.checkbox:
          // Web's `!formData[key]` treats an unchecked `false` as falsy —
          // match that rather than the generic null/empty-string check.
          if (responseData[field.key] != true) missing.add(field.label);
        default:
          final value = responseData[field.key];
          final isEmpty =
              value == null ||
              (value is String && value.trim().isEmpty) ||
              (value is List && value.isEmpty);
          if (isEmpty) missing.add(field.label);
      }
    }
    return missing;
  }

  /// Sends the answers (see [InspectionRepository.submit] for what each
  /// outcome means). Never throws: anything unexpected is a plain refusal.
  Future<InspectionSubmitOutcome> submit(Map<String, dynamic> responseData) async {
    InspectionSubmitOutcome outcome;
    try {
      outcome = await ref.read(inspectionRepositoryProvider).submit(arg, responseData);
    } catch (_) {
      outcome = const InspectionRefused(reasonKey: 'inspection.send.refused_hint');
    }
    ref.read(inspectionSendTickProvider.notifier).state++;
    if (outcome is InspectionSubmitted) {
      await refresh();
      ref.invalidate(assignedInspectionsProvider);
    }
    return outcome;
  }
}

final inspectionDetailControllerProvider = AsyncNotifierProvider.family<
  InspectionDetailController,
  InspectionAssignmentDetail,
  String
>(InspectionDetailController.new);
