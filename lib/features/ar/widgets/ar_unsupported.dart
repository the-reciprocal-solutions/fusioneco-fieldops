import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/router.dart';
import '../../../state/ar_prefs_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../ar_ui.dart';
import 'ar_chrome.dart';

/// Tier C (docs/ar-bim-overlay.md §6.7): no AR on this device, or the AR
/// engine isn't in this build yet. Never a crash, never a blank view:
/// "Show on floor plan" (the floor plan screen already pins assets), and a
/// Demo mode that walks every AR flow with a sample building.
class ArUnsupportedView extends ConsumerWidget {
  const ArUnsupportedView({
    super.key,
    required this.reason,
    this.floorId,
    this.assetId,
    this.assetName,
    this.onDemo,
    this.errorKey,
    this.onRetry,
  });

  /// `engine-not-installed`, `unsupported`, `camera-denied`… from the engine.
  final String? reason;
  final String? floorId;
  final String? assetId;
  final String? assetName;

  /// Called after Demo mode is switched on (the caller restarts).
  final VoidCallback? onDemo;

  /// For a failed session rather than an unsupported device.
  final String? errorKey;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (titleKey, bodyKey, icon) = errorKey != null
        ? ('ar.fallback.failed_title', errorKey!, ArIcons.warning)
        : switch (reason) {
            'engine-not-installed' => ('ar.fallback.engine_title', 'ar.fallback.engine_body', ArIcons.box),
            'camera-denied' || 'camera' => ('ar.fallback.camera_title', 'ar.fallback.camera_body', ArIcons.capture),
            _ => ('ar.fallback.device_title', 'ar.fallback.device_body', ArIcons.warning),
          };
    final demo = ref.watch(arPrefsProvider.select((p) => p.demo));
    return ColoredBox(
      color: FeColors.page,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(20),
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: IconButton(
                    tooltip: 'ar.common.back'.getString(context),
                    onPressed: () => context.pop(),
                    icon: const ArDirectionalIcon(ArIcons.back, size: 22, color: FeColors.ink),
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(color: FeColors.infoSoft, borderRadius: BorderRadius.circular(26)),
                    child: Icon(icon, size: 38, color: FeColors.primary),
                  ),
                ),
                const SizedBox(height: 18),
                AppText.title(titleKey.getString(context), weight: FontWeight.w800, align: TextAlign.center),
                const SizedBox(height: 8),
                AppText.bodyMedium(bodyKey.getString(context), color: FeColors.ink2, align: TextAlign.center),
                const SizedBox(height: 22),
                // Camera refused: the switch lives in the phone's Settings.
                if (errorKey == null && (reason == 'camera-denied' || reason == 'camera')) ...[
                  ArPrimaryButton(
                    label: 'ar.fallback.open_settings'.getString(context),
                    icon: ArIcons.capture,
                    onPressed: () => openAppSettings(),
                  ),
                  const SizedBox(height: 10),
                ],
                if (onRetry != null) ...[
                  ArPrimaryButton(label: 'ar.common.retry'.getString(context), icon: ArIcons.sync, onPressed: onRetry),
                  const SizedBox(height: 10),
                ],
                if (floorId != null && floorId!.isNotEmpty)
                  ArPrimaryButton(
                    label: 'ar.fallback.floor_plan'.getString(context),
                    icon: ArIcons.plan,
                    color: onRetry == null ? FeColors.primary : FeColors.ink,
                    onPressed: () => context.pushReplacement(
                      Routes.floorPlan(floorId!, assetId: assetId ?? '', assetName: assetName),
                    ),
                  ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: FeArColors.placedBg,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: FeColors.warning.withValues(alpha: 0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(ArIcons.demo, color: FeArColors.placedFg, size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: AppText.titleSmall('ar.fallback.demo_title'.getString(context), weight: FontWeight.w800, color: FeArColors.placedFg)),
                          Switch(
                            value: demo,
                            activeThumbColor: FeColors.warning,
                            onChanged: (v) async {
                              await ref.read(arPrefsProvider.notifier).setDemo(v);
                              if (v) onDemo?.call();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      AppText.bodySmall('ar.fallback.demo_body'.getString(context), color: FeArColors.placedFg),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
