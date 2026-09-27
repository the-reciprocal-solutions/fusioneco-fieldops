import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../../../core/capture/capture_services.dart';
import '../../../domain/ar_handoff.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';

/// "From AR" on the verification and snag forms (P-006): what the AR
/// workspace measured, shown before the technician fills the rest in — the
/// element and its GlobalId, the location check against the model, and how
/// well the model was aligned when it was taken. Read-only: the form's own
/// fields stay the technician's.
class ArHandoffCard extends StatelessWidget {
  const ArHandoffCard({super.key, required this.handoff, this.showLocationCheck = true});

  final ArHandoff handoff;

  /// The verification form shows the location check; a snag doesn't have one.
  final bool showLocationCheck;

  @override
  Widget build(BuildContext context) {
    final h = handoff;
    final (Color bg, Color fg, IconData icon, String headline) = switch (h.check) {
      'consistent' => (FeColors.successSoft, FeArColors.lockedFg, ArIcons.check, _checkText(context, h, ok: true)),
      'offset' => (FeColors.warningSoft, FeArColors.placedFg, ArIcons.warning, _checkText(context, h, ok: false)),
      _ => (FeArColors.manualBg, FeArColors.manualFg, ArIcons.info, 'ar.handoff.unchecked'.getString(context)),
    };
    final alignment = h.quality == null
        ? null
        : arTr(context, 'ar.handoff.alignment', [
            'ar.handoff.quality.${h.quality}'.getString(context),
            h.maxResidualMm == null ? '–' : '±${h.maxResidualMm} mm',
          ]);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FeColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(ArIcons.box, size: 16, color: FeColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: AppText.label('ar.handoff.title'.getString(context), color: FeColors.primary, weight: FontWeight.w800),
              ),
            ],
          ),
          if (h.elementName != null || h.globalId != null) ...[
            const SizedBox(height: 8),
            if (h.elementName != null) AppText.titleSmall(h.elementName!, weight: FontWeight.w700),
            if (h.globalId != null)
              AppText.caption(arTr(context, 'ar.handoff.global_id', [h.globalId!]), color: FeColors.ink2),
          ],
          if (showLocationCheck) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 8),
                  Expanded(child: AppText.bodySmall(headline, color: fg, weight: FontWeight.w600)),
                ],
              ),
            ),
            if (h.tagMatches != null) ...[
              const SizedBox(height: 6),
              AppText.caption(
                (h.tagMatches! ? 'ar.handoff.tag_matches' : 'ar.handoff.tag_differs').getString(context),
                color: h.tagMatches! ? FeArColors.lockedFg : FeColors.danger,
                weight: FontWeight.w600,
              ),
            ],
          ],
          if (alignment != null) ...[
            const SizedBox(height: 6),
            AppText.caption(alignment, color: FeColors.ink2),
          ],
          if (h.photoPath != null) ...[
            const SizedBox(height: 2),
            AppText.caption('ar.handoff.photo_attached'.getString(context), color: FeColors.ink2),
          ],
        ],
      ),
    );
  }

  static String _checkText(BuildContext context, ArHandoff h, {required bool ok}) {
    final off = h.offsetM;
    final tol = h.toleranceM;
    if (off == null) return 'ar.handoff.unchecked'.getString(context);
    final tolText = tol == null ? '–' : arCentimetres(context, tol);
    return ok
        ? arTr(context, 'ar.handoff.consistent', [arCentimetres(context, off), tolText])
        : arTr(context, 'ar.handoff.offset', [arMetres(context, off), tolText]);
  }
}

/// The AR capture as a form photo, or null when there is none (or the file
/// is gone: captures live in the app's temp space). Named `ar-…` so the
/// form can tell it is already attached after a draft restore.
Future<CapturedPhoto?> arHandoffPhoto(ArHandoff? h) async {
  final path = h?.photoPath;
  if (path == null) return null;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final name = path.split(Platform.pathSeparator).last;
    return CapturedPhoto(bytes: await file.readAsBytes(), fileName: name.startsWith('ar-') ? name : 'ar-$name');
  } catch (_) {
    return null;
  }
}
