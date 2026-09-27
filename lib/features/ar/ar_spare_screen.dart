import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/ar/marker_code.dart';
import '../../state/ar_permissions.dart';
import '../../theme/fe_ar_colors.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/fe_header.dart';
import 'ar_ui.dart';
import 'widgets/ar_chrome.dart';
import 'widgets/ar_entry_widgets.dart' show ArInstallNotEnabled;

/// `/ar/spare/:code` — a blank spare board scanned outside AR (I4Spare).
/// A board's position comes from the lock, so the way to make it a marker
/// is: open AR on its floor, place the model, then scan it — the session
/// offers "New board, not saved yet" by itself. This screen says so in
/// three steps and opens the right place.
class ArSpareScreen extends ConsumerWidget {
  const ArSpareScreen({super.key, required this.code, this.floorId});

  final String code;
  final String? floorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Turning a spare into a marker is an install action (P-007).
    if (!ref.watch(arInstallAllowedProvider)) {
      return Scaffold(
        backgroundColor: FeColors.page,
        appBar: FeHeader(title: 'ar.spare.header'.getString(context)),
        body: const SafeArea(top: false, child: ArInstallNotEnabled()),
      );
    }
    final canonical = MarkerCode.normalize(code) ?? code.toUpperCase();
    final label = MarkerCode.spareLabel(canonical);
    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'ar.spare.header'.getString(context)),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(child: _BoardIcon(label: label)),
                const SizedBox(height: 18),
                ArEyebrow('ar.spare.eyebrow'.getString(context)),
                const SizedBox(height: 2),
                AppText.headlineSmall(label, weight: FontWeight.w800),
                AppText.bodySmall(MarkerCode.display(canonical), color: FeColors.ink2),
                const SizedBox(height: 10),
                AppText.bodyMedium('ar.spare.body'.getString(context), color: FeColors.ink2),
                const SizedBox(height: 16),
                for (var i = 1; i <= 3; i++) _StepRow(n: i, text: 'ar.spare.step$i'.getString(context)),
                const SizedBox(height: 12),
                ArHintRow(text: 'ar.spare.derived'.getString(context), icon: ArIcons.info),
                const SizedBox(height: 20),
                ArPrimaryButton(
                  label: (floorId == null ? 'ar.spare.pick_floor' : 'ar.spare.open_ar').getString(context),
                  icon: ArIcons.box,
                  onPressed: () => context.pushReplacement(
                    floorId == null ? Routes.arModels() : Routes.arSession(floorId: floorId!),
                  ),
                ),
                const SizedBox(height: 8),
                ArSecondaryButton(label: 'ar.common.not_now'.getString(context), onPressed: () => context.pop()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BoardIcon extends StatelessWidget {
  const _BoardIcon({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      height: 160,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FeArColors.boardPaper,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: Column(
        children: [
          AppText.caption(label, weight: FontWeight.w800, color: FeArColors.boardInk),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: FeArColors.boardInk, width: 6)),
              child: const Center(child: Icon(ArIcons.board, size: 40, color: FeArColors.boardInk)),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: FeColors.infoSoft, shape: BoxShape.circle),
            child: AppText.caption('$n', color: FeColors.primary, weight: FontWeight.w800),
          ),
          const SizedBox(width: 12),
          Expanded(child: AppText.bodyMedium(text)),
        ],
      ),
    );
  }
}
