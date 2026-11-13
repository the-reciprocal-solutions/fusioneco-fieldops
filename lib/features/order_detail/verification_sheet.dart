import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/capture/capture_services.dart';
import '../../state/checklist_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../theme/app_font.dart';

/// What the technician captured before a session may start or end.
class VerificationResult {
  const VerificationResult({this.photo, this.location});

  final CapturedPhoto? photo;
  final CapturedLocation? location;
}

enum VerificationMode { start, end }

/// Gate in front of a timer session. Nothing is sent until every required
/// piece is captured — the button stays locked otherwise.
class VerificationSheet extends ConsumerStatefulWidget {
  const VerificationSheet({
    super.key,
    required this.mode,
    required this.requireFaceCapture,
    required this.requireLocation,
  });

  final VerificationMode mode;
  final bool requireFaceCapture;
  final bool requireLocation;

  @override
  ConsumerState<VerificationSheet> createState() => _VerificationSheetState();
}

class _VerificationSheetState extends ConsumerState<VerificationSheet> {
  CapturedPhoto? _photo;
  CapturedLocation? _location;
  String? _locationError;
  bool _locating = false;

  bool get _ready =>
      (!widget.requireFaceCapture || _photo != null) &&
      (!widget.requireLocation || _location != null);

  @override
  void initState() {
    super.initState();
    // The web starts acquiring a fix as soon as the dialog opens, so the
    // technician is not left waiting after taking the photo.
    if (widget.requireLocation) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
    }
  }

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final location = await ref.read(locationCaptureProvider).current();
      if (!mounted) return;
      setState(() => _location = location);
    } on CaptureFailure catch (e) {
      if (!mounted) return;
      setState(() => _locationError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _locationError =
            'order_detail.location_error_generic'.getString(context),
      );
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _capture({required bool fromGallery}) async {
    final capture = ref.read(photoCaptureProvider);
    final photo = fromGallery
        ? await capture.pickFromGallery()
        : await capture.takeFacePhoto();
    if (photo == null || !mounted) return;
    setState(() => _photo = photo);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 32,
                  width: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: FeColors.primary,
                    borderRadius: BorderRadius.circular(context.radii.lg),
                  ),
                  child: const Icon(LucideIcons.circleCheck,
                      size: 18, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppText.titleMedium(
                    widget.mode == VerificationMode.end
                        ? 'order_detail.session_end_verification'.getString(context)
                        : 'order_detail.identity_verification'.getString(context),
                    weight: FontWeight.w800,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.x, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.requireFaceCapture) ...[
              _PhotoPanel(
                photo: _photo,
                onRetake: () => _capture(fromGallery: false),
                onPick: () => _capture(fromGallery: true),
                onClear: () => setState(() => _photo = null),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.requireLocation) ...[
              _LocationPanel(
                location: _location,
                locating: _locating,
                error: _locationError,
                onRetry: _locate,
              ),
              const SizedBox(height: 16),
            ],
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _ready
                    ? () => Navigator.of(context).pop(
                          VerificationResult(photo: _photo, location: _location),
                        )
                    : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                child: AppText(
                  widget.mode == VerificationMode.end
                      ? 'order_detail.end_session_now'.getString(context)
                      : 'order_detail.start_task_now'.getString(context),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            if (!_ready) ...[
              const SizedBox(height: 12),
              AppText.caption(
                'order_detail.unlock_task_controls'.getString(context),
                align: TextAlign.center,
                color: FeColors.ink2,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PhotoPanel extends StatelessWidget {
  const _PhotoPanel({
    required this.photo,
    required this.onRetake,
    required this.onPick,
    required this.onClear,
  });

  final CapturedPhoto? photo;
  final VoidCallback onRetake;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          'order_detail.verification_photo_label'.getString(context),
          style: theme.textTheme.labelSmall?.copyWith(
            color: FeColors.ink2,
            fontWeight: FontWeight.w700,
            letterSpacing: context.letterSpacingFor(1.5),
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
            child: photo == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.camera,
                            size: 36, color: Colors.white.withValues(alpha: 0.6)),
                        const SizedBox(height: 12),
                        AppText.bodySmall(
                          'order_detail.verification_photo_prompt'.getString(context),
                          align: TextAlign.center,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ],
                    ),
                  )
                : Image.memory(photo!.bytes, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: onRetake,
                icon: const Icon(LucideIcons.camera, size: 16),
                label: AppText(
                  photo == null
                      ? 'order_detail.take_photo'.getString(context)
                      : 'order_detail.retake'.getString(context),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (photo == null)
              OutlinedButton.icon(
                onPressed: onPick,
                icon: const Icon(LucideIcons.upload, size: 16),
                label: AppText('common.upload'.getString(context)),
              )
            else
              OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(LucideIcons.trash2, size: 16),
                label: AppText('common.clear'.getString(context)),
              ),
          ],
        ),
      ],
    );
  }
}

class _LocationPanel extends StatelessWidget {
  const _LocationPanel({
    required this.location,
    required this.locating,
    required this.error,
    required this.onRetry,
  });

  final CapturedLocation? location;
  final bool locating;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (location != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: FeColors.successSoft,
          borderRadius: BorderRadius.circular(context.radii.sheet),
          border: Border.all(color: FeColors.success),
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.mapPin, size: 20, color: FeColors.success),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    'order_detail.location_recorded_label'.getString(context),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: FeColors.success,
                      fontWeight: FontWeight.w800,
                      letterSpacing: context.letterSpacingFor(1.5),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // The place name when the device resolved one, with the
                  // coordinates under it — the name is what a person reads
                  // back, the numbers are what the record is actually made of.
                  if (location!.placeLabel != null) ...[
                    AppText.bodySmall(
                      location!.placeLabel!,
                      color: FeColors.success,
                      weight: FontWeight.w700,
                    ),
                    const SizedBox(height: 2),
                  ],
                  AppText(
                    '${location!.latitude.toStringAsFixed(4)}, '
                    '${location!.longitude.toStringAsFixed(4)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: FeColors.success,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: error == null ? FeColors.page : FeColors.dangerSoft,
        borderRadius: BorderRadius.circular(context.radii.sheet),
        border: Border.all(
          color: error == null ? FeColors.line : FeColors.danger,
        ),
      ),
      child: Row(
        children: [
          if (locating)
            const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              error == null ? LucideIcons.mapPin : LucideIcons.triangleAlert,
              size: 20,
              color: error == null ? FeColors.ink2 : FeColors.danger,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: AppText.bodySmall(
              locating
                  ? 'order_detail.getting_location'.getString(context)
                  : error ?? 'order_detail.location_not_captured'.getString(context),
              color: error == null ? FeColors.ink2 : FeColors.danger,
            ),
          ),
          if (!locating)
            TextButton(
              onPressed: onRetry,
              child: AppText('common.retry'.getString(context)),
            ),
        ],
      ),
    );
  }
}
