import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/capture/capture_rules.dart';
import '../../domain/capture.dart';
import '../../state/day_capture_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';

/// Opens the "Start my day" / "End my day" sheet. True when it was saved.
Future<bool> showDaySheet(BuildContext context, DayCaptureArgs args) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: FeColors.panel,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.radii.sheet)),
    ),
    builder: (_) => DaySheet(args: args),
  );
  return r == true;
}

/// The start / end of day sheet (docs/daily-attendance-shift-plan.md).
///
/// The confirm button stays locked until the selfie is in (or explicitly
/// skipped) and the position search has finished. A missing position never
/// blocks: the technician picks a short reason and carries on. Saving never
/// waits on the network.
class DaySheet extends ConsumerStatefulWidget {
  const DaySheet({super.key, required this.args});

  final DayCaptureArgs args;

  @override
  ConsumerState<DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends ConsumerState<DaySheet> {
  final _otherController = TextEditingController();
  String? _reasonKey;

  @override
  void dispose() {
    _otherController.dispose();
    super.dispose();
  }

  void _pickReason(String key) {
    setState(() => _reasonKey = key);
    final controller = ref.read(dayCaptureProvider(widget.args).notifier);
    if (key == 'other') {
      controller.setReason(_otherController.text);
    } else {
      controller.setReason(kNoFixReasonText[key] ?? '');
    }
  }

  Future<void> _submit() async {
    final saved = await ref.read(dayCaptureProvider(widget.args).notifier).submit();
    if (saved && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final args = widget.args;
    final state = ref.watch(dayCaptureProvider(args));
    final controller = ref.read(dayCaptureProvider(args).notifier);
    final fix = state.fix;
    final needsReason = fix != null && reasonRequired(fix);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(args: args),
            const SizedBox(height: 4),
            AppText.bodySmall(args.label, color: FeColors.ink2),
            const SizedBox(height: 16),
            _PhotoPanel(
              args: args,
              state: state,
              onTake: controller.takePhoto,
              onSkip: controller.skipPhoto,
            ),
            const SizedBox(height: 16),
            _LocationPanel(state: state, onRetry: controller.findPosition),
            if (needsReason) ...[
              const SizedBox(height: 16),
              _ReasonPanel(
                selectedKey: _reasonKey,
                controller: _otherController,
                onPick: _pickReason,
                onTyped: (text) => controller.setReason(text),
              ),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              AppText.bodySmall(state.error!, color: FeColors.danger),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: state.canSubmit ? _submit : null,
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                child: state.saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : AppText(
                        (args.isStart ? 'attend.confirm_in' : 'attend.confirm_out').getString(context),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            AppText.caption(
              state.canSubmit || state.saving
                  ? 'capture.privacy'.getString(context)
                  : 'capture.unlock_hint'.getString(context),
              align: TextAlign.center,
              color: FeColors.ink2,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.args});
  final DayCaptureArgs args;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          height: 32,
          width: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: args.isStart ? FeColors.success : FeColors.primary,
            borderRadius: BorderRadius.circular(context.radii.lg),
          ),
          child: Icon(
            args.isStart ? LucideIcons.logIn : LucideIcons.logOut,
            size: 18,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AppText.titleMedium(
            (args.isStart ? 'attend.sheet_title_in' : 'attend.sheet_title_out').getString(context),
            weight: FontWeight.w800,
          ),
        ),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(LucideIcons.x, size: 20),
        ),
      ],
    );
  }
}

class _PhotoPanel extends StatelessWidget {
  const _PhotoPanel({
    required this.args,
    required this.state,
    required this.onTake,
    required this.onSkip,
  });

  final DayCaptureArgs args;
  final DayCaptureState state;
  final VoidCallback onTake;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final photo = state.photo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          'capture.photo_label'.getString(context),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: FeColors.ink2,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(context.radii.sheet),
            ),
            child: photo != null
                ? Image.memory(photo.bytes, fit: BoxFit.contain) // contain: the burned-in stamp sits on the bottom edge
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          state.photoSkipped ? LucideIcons.cameraOff : LucideIcons.camera,
                          size: 36,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: AppText.bodySmall(
                            state.photoSkipped
                                ? 'capture.photo_skipped'.getString(context)
                                : (args.isStart ? 'attend.photo_prompt_in' : 'attend.photo_prompt_out').getString(context),
                            align: TextAlign.center,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: state.takingPhoto || state.saving ? null : onTake,
            icon: state.takingPhoto
                ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.camera, size: 16),
            label: AppText(
              (photo == null ? 'capture.take_photo' : 'capture.retake').getString(context),
            ),
          ),
        ),
        if (photo == null && !state.photoSkipped)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: state.takingPhoto || state.saving ? null : onSkip,
              child: AppText.bodySmall('capture.skip_photo'.getString(context), color: FeColors.ink2),
            ),
          ),
      ],
    );
  }
}

class _LocationPanel extends StatelessWidget {
  const _LocationPanel({required this.state, required this.onRetry});

  final DayCaptureState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final fix = state.fix;

    final (IconData icon, Color color, String title, String? detail) = state.finding
        ? (LucideIcons.locateFixed, FeColors.ink2, 'capture.finding_location'.getString(context), null)
        : switch (fix?.kind ?? FixKind.none) {
            FixKind.gps => (
              LucideIcons.mapPinCheck,
              FeColors.success,
              'capture.location_ok'.getString(context),
              fix?.accuracyM == null
                  ? null
                  : 'capture.location_accuracy'
                        .getString(context)
                        .replaceAll('{m}', fix!.accuracyM!.round().toString()),
            ),
            FixKind.lastKnown => (
              LucideIcons.mapPin,
              FeColors.warning,
              'capture.location_stale'.getString(context),
              null,
            ),
            FixKind.none => (
              LucideIcons.mapPinOff,
              FeColors.danger,
              'capture.location_none'.getString(context),
              null,
            ),
          };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FeColors.page,
        borderRadius: BorderRadius.circular(context.radii.lg),
        border: Border.all(color: FeColors.line),
      ),
      child: Row(
        children: [
          state.finding
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodySmall(title, weight: FontWeight.w700),
                if (detail != null) AppText.caption(detail, color: FeColors.ink2),
              ],
            ),
          ),
          if (!state.finding && (fix == null || fix.kind != FixKind.gps))
            TextButton(
              onPressed: onRetry,
              child: AppText.bodySmall('capture.location_retry'.getString(context)),
            ),
        ],
      ),
    );
  }
}

class _ReasonPanel extends StatelessWidget {
  const _ReasonPanel({
    required this.selectedKey,
    required this.controller,
    required this.onPick,
    required this.onTyped,
  });

  final String? selectedKey;
  final TextEditingController controller;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onTyped;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          'capture.reason_label'.getString(context),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: FeColors.ink2,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final key in kNoFixReasonKeys)
              ChoiceChip(
                label: AppText.bodySmall('capture.reason_$key'.getString(context)),
                selected: selectedKey == key,
                onSelected: (_) => onPick(key),
              ),
          ],
        ),
        if (selectedKey == 'other') ...[
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLength: 200,
            onChanged: onTyped,
            decoration: InputDecoration(hintText: 'capture.reason_hint'.getString(context)),
          ),
        ],
      ],
    );
  }
}
