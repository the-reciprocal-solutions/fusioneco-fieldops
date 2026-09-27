import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/ar_prefs_controller.dart';
import '../../theme/fe_ar_colors.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import 'ar_ui.dart';
import 'widgets/ar_chrome.dart';

/// First-time tips (product feedback 2026-09-27: "make controls easier"):
/// three cards on the first AR session — sweep the walls, snap two corners,
/// then check the outlines and use the legend and Drill check. Shown once
/// per phone (`ar_prefs` `coach:v1`), skippable at any card, and replayable
/// from Menu → "Show tips". Entering straight into the workspace (a resumed
/// placement) starts at the third card: the first two are about placing.
class ArCoachOverlay extends ConsumerStatefulWidget {
  const ArCoachOverlay({super.key, this.startAtWork = false, this.maxWidth = 440});

  final bool startAtWork;
  final double maxWidth;

  @override
  ConsumerState<ArCoachOverlay> createState() => _ArCoachOverlayState();
}

class ArCoachStep {
  const ArCoachStep(this.icon, this.titleKey, this.bodyKey);
  final IconData icon;
  final String titleKey;
  final String bodyKey;
}

const kArCoachSteps = <ArCoachStep>[
  ArCoachStep(ArIcons.corner, 'ar.coach.sweep_title', 'ar.coach.sweep_body'),
  ArCoachStep(ArIcons.reSnap, 'ar.coach.snap_title', 'ar.coach.snap_body'),
  ArCoachStep(ArIcons.legend, 'ar.coach.check_title', 'ar.coach.check_body'),
];

class _ArCoachOverlayState extends ConsumerState<ArCoachOverlay> {
  late var _i = widget.startAtWork ? kArCoachSteps.length - 1 : 0;

  void _done() {
    ArHaptics.snap();
    ref.read(arPrefsProvider.notifier).setCoachSeen(true);
  }

  @override
  Widget build(BuildContext context) {
    final step = kArCoachSteps[_i];
    final last = _i == kArCoachSteps.length - 1;
    final bottom = MediaQuery.paddingOf(context).bottom + 16;
    return Stack(
      children: [
        // Blocks the view behind while the tip is up; a tap outside skips.
        Positioned.fill(child: GestureDetector(onTap: _done, child: const ColoredBox(color: Colors.black38))),
        Positioned(
          left: 16,
          right: 16,
          bottom: bottom,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: ArCard(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: FeArColors.manualBg, borderRadius: BorderRadius.circular(13)),
                          child: Icon(step.icon, color: FeColors.primary, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText.caption(
                                arTr(context, 'ar.coach.step', [_i + 1, kArCoachSteps.length]),
                                color: FeColors.ink2,
                                weight: FontWeight.w700,
                              ),
                              AppText.titleMedium(step.titleKey.getString(context), weight: FontWeight.w800),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AppText.bodyMedium(step.bodyKey.getString(context), color: FeColors.ink2),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        ArStepDots(count: kArCoachSteps.length, index: _i),
                        const Spacer(),
                        TextButton(
                          onPressed: _done,
                          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                          child: AppText.label('ar.coach.skip'.getString(context), color: FeColors.ink2, weight: FontWeight.w700),
                        ),
                        const SizedBox(width: 6),
                        FilledButton(
                          onPressed: last ? _done : () => setState(() => _i++),
                          style: FilledButton.styleFrom(
                            backgroundColor: FeColors.primary,
                            minimumSize: const Size(96, 48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: AppText.label(
                            (last ? 'ar.coach.done' : 'ar.coach.next').getString(context),
                            color: Colors.white,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
