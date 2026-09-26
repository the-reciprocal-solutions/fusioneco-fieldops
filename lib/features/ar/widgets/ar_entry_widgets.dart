import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../state/ar_demo_gateway.dart';
import '../../../state/ar_prefs_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/motion.dart';
import '../ar_ui.dart';

/// Doors into AR from the rest of the app. Each screen only knows where the
/// door is; what's behind it (floor lookup, models, placing the model) is
/// the AR screens' job.

/// "Show in AR" on an asset or a work order (§1.1 Locate). Opens the models
/// picker scoped to the asset's floor; the asset becomes the Locate target.
class ShowInArButton extends StatelessWidget {
  const ShowInArButton({super.key, this.assetId, this.floorId, this.workOrderId, this.compact = false});

  final String? assetId;
  final String? floorId;
  final String? workOrderId;

  /// The order screen's small pill style instead of a full-width button.
  final bool compact;

  void _open(BuildContext context) =>
      context.push(Routes.arModels(assetId: assetId, floorId: floorId, workOrderId: workOrderId));

  @override
  Widget build(BuildContext context) {
    final label = 'ar.entry.show_in_ar'.getString(context);
    if (compact) {
      return PressableScale(
        child: Material(
          color: FeColors.ink,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _open(context),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(ArIcons.box, size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Flexible(child: AppText.label(label, color: Colors.white, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _open(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: FeColors.ink,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        icon: const Icon(ArIcons.box, size: 16),
        label: AppText.label(label, color: Colors.white, weight: FontWeight.w700),
      ),
    );
  }
}

/// The dashboard's door into AR: "Show the model where you stand". One tap
/// to scan a board, one to pick a floor, and the install run when there is
/// one. Demo mode is announced here too, so nobody forgets it's on.
class ArDashboardCard extends ConsumerWidget {
  const ArDashboardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(arPrefsProvider.select((p) => p.demo));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [FeColors.primary, FeColors.primaryLight],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: FeElevation.tinted(FeColors.primary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
                child: const Icon(ArIcons.box, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.titleMedium('ar.dashboard.title'.getString(context), color: Colors.white, weight: FontWeight.w800),
                    const SizedBox(height: 2),
                    AppText.bodySmall(
                      (demo ? 'ar.dashboard.sub_demo' : 'ar.dashboard.sub').getString(context),
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Demo is switched here as well as on the AR-unavailable screen:
              // a checked-in technician goes straight to their site's floors
              // and would otherwise never see the building list's Demo offer.
              _DemoToggle(on: demo, onChanged: (v) => ref.read(arPrefsProvider.notifier).setDemo(v)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _CardAction(
                  icon: ArIcons.board,
                  label: 'ar.dashboard.scan'.getString(context),
                  // Demo mode has no real board to point at: open the sample
                  // board's scan sheet as if it had just been read.
                  onTap: () => context.push(demo ? Routes.arMarker(DemoArGateway.focusCode) : Routes.scan),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CardAction(
                  icon: ArIcons.building,
                  label: 'ar.dashboard.floor'.getString(context),
                  onTap: () => context.push(Routes.arModels()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CardAction(
                  icon: ArIcons.install,
                  label: 'ar.dashboard.install'.getString(context),
                  onTap: () => context.push(Routes.arInstall()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DemoToggle extends StatelessWidget {
  const _DemoToggle({required this.on, required this.onChanged});
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: on ? Colors.white : Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onChanged(!on),
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ArIcons.demo, size: 14, color: on ? FeColors.primary : Colors.white),
              const SizedBox(width: 6),
              AppText.caption(
                'ar.dashboard.demo'.getString(context),
                color: on ? FeColors.primary : Colors.white,
                weight: FontWeight.w800,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      child: Material(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(height: 4),
                AppText.caption(label, color: Colors.white, weight: FontWeight.w700, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
