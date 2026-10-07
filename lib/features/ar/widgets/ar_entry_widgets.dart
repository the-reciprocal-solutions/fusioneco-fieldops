import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../state/ar_availability.dart';
import '../../../state/ar_permissions.dart';
import '../../../state/ar_demo_gateway.dart';
import '../../../state/ar_prefs_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/common.dart';
import '../../../widgets/motion.dart';
import '../ar_ui.dart';

/// Doors into AR from the rest of the app. Each screen only knows where the
/// door is; what's behind it (floor lookup, models, placing the model) is
/// the AR screens' job.

/// "Show in AR" on an asset or a work order (§1.1 Locate). Opens the models
/// picker scoped to the asset's floor; the asset becomes the Locate target.
///
/// Draws itself ONLY where AR is enabled — the client's `isArView` flag AND a
/// published AR model for this floor / the asset's floor
/// ([arDoorAvailableProvider]). Everywhere else it is an empty box (margin
/// included), so the screen's own "View in 3D" / model-viewer buttons stay as
/// the way in. Never use it to replace those buttons.
class ShowInArButton extends ConsumerWidget {
  const ShowInArButton({
    super.key,
    this.assetId,
    this.floorId,
    this.workOrderId,
    this.compact = false,
    this.margin = EdgeInsets.zero,
  });

  final String? assetId;
  final String? floorId;
  final String? workOrderId;

  /// The order screen's small pill style instead of a full-width button.
  final bool compact;

  /// Space around the button, applied only when it is shown.
  final EdgeInsetsGeometry margin;

  void _open(BuildContext context) =>
      context.push(Routes.arModels(assetId: assetId, floorId: floorId, workOrderId: workOrderId));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(arDoorAvailableProvider((floorId: floorId, assetId: assetId))).valueOrNull ?? false;
    if (!available) return const SizedBox.shrink();
    return Padding(padding: margin, child: _button(context));
  }

  Widget _button(BuildContext context) {
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
///
/// On by default (owner, 2026-10-06): shown unless the client explicitly set
/// `isArView = false` ([arCardModeProvider]). With no published model for
/// the technician's buildings it says so in one plain line and offers the
/// built-in demo room (works with no model and no board) and "Scan an AR
/// board", instead of disappearing.
class ArDashboardCard extends ConsumerWidget {
  const ArDashboardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(arPrefsProvider.select((p) => p.demo));
    final mode = ref.watch(arCardModeProvider);
    // A switched-on demo keeps the card even for a client with AR off, so it
    // can always be switched off again.
    if (mode == ArCardMode.hidden && !demo) return const SizedBox.shrink();
    final noModels = mode == ArCardMode.noModels && !demo;
    // Installs are opt-in per client (`isArInstall`, P-007).
    final install = ref.watch(arInstallAllowedProvider);
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
                      (demo
                              ? 'ar.dashboard.sub_demo'
                              : noModels
                                  ? 'ar.dashboard.no_models'
                                  : 'ar.dashboard.sub')
                          .getString(context),
                      key: const ValueKey('ar-card-sub'),
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
              if (noModels) ...[
                // Nothing published yet: the demo room works out of the box
                // (sample building, nothing saved), and a board on site
                // still resolves once its building gets a model.
                Expanded(
                  child: _CardAction(
                    key: const ValueKey('ar-card-try-demo'),
                    icon: ArIcons.demo,
                    label: 'ar.dashboard.try_demo'.getString(context),
                    onTap: () async {
                      await ref.read(arPrefsProvider.notifier).setDemo(true);
                      if (context.mounted) context.push(Routes.arMarker(DemoArGateway.focusCode));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CardAction(
                    key: const ValueKey('ar-card-scan-board'),
                    icon: ArIcons.board,
                    label: 'ar.dashboard.scan_board'.getString(context),
                    onTap: () => context.push(Routes.scan),
                  ),
                ),
              ] else ...[
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
              ],
              if (install) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _CardAction(
                    icon: ArIcons.install,
                    label: 'ar.dashboard.install'.getString(context),
                    onTap: () => context.push(Routes.arInstall()),
                  ),
                ),
              ],
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
  const _CardAction({super.key, required this.icon, required this.label, required this.onTap});
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

/// Shown by the install screens when the account may not install boards
/// (`isArInstall` off, P-007): a push link or an old bookmark can still
/// land there, so the screen explains instead of listing.
class ArInstallNotEnabled extends StatelessWidget {
  const ArInstallNotEnabled({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TechEmptyState(
          icon: ArIcons.lock,
          title: 'ar.install.not_enabled'.getString(context),
          subtitle: 'ar.install.not_enabled_body'.getString(context),
        ),
      ],
    );
  }
}
