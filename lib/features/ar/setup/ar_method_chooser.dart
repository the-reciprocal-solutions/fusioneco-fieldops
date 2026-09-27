import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/ar_prefs_controller.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_setup_controller.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/motion.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';

/// TabMethod / PhMethod (AR-54): how to place the model. The fastest option
/// for where the user is comes first with a "Best here" tag; options that
/// can't work here stay visible but disabled, each saying why, so nobody
/// wonders where GNSS went. "Remember my choice for Level 3" replaces
/// GAMMA's "Ask every time".
class ArMethodChooser extends ConsumerWidget {
  const ArMethodChooser({super.key, required this.tablet});

  final bool tablet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(arSetupProvider);
    final session = ref.watch(arSessionProvider);
    final floor = session.floor;
    final boardsHere = floor?.activeMarkers.length ?? 0;
    final corners = floor?.corners.length ?? 0;
    final grid = floor?.gridLines.isNotEmpty ?? false;
    final ctrl = ref.read(arSetupProvider.notifier);
    final recommended = setup.recommended;
    final floorName = floor?.floorName ?? '';
    final where = session.args?.spaceName ?? floorName;
    final sunlight = ref.watch(arPrefsProvider.select((p) => p.sunlight));

    final options = <_MethodOption>[
      _MethodOption(
        method: ArPlaceMethod.board,
        icon: ArIcons.board,
        title: 'ar.method.board'.getString(context),
        subtitle: boardsHere > 0
            ? arTr(context, 'ar.method.board_sub', [boardsHere])
            : 'ar.method.board_none'.getString(context),
        enabled: true,
      ),
      _MethodOption(
        method: ArPlaceMethod.corners,
        icon: ArIcons.corner,
        title: 'ar.method.corners'.getString(context),
        subtitle: corners > 0 ? 'ar.method.corners_sub'.getString(context) : 'ar.method.corners_none'.getString(context),
        enabled: corners > 0,
      ),
      _MethodOption(
        method: ArPlaceMethod.grid,
        icon: ArIcons.gridCrossing,
        title: 'ar.method.grid'.getString(context),
        subtitle: grid ? 'ar.method.grid_sub'.getString(context) : 'ar.method.grid_none'.getString(context),
        enabled: grid && corners > 0,
      ),
      _MethodOption(
        method: ArPlaceMethod.resume,
        icon: ArIcons.resume,
        title: 'ar.method.resume'.getString(context),
        subtitle: 'ar.method.resume_sub'.getString(context),
        enabled: false,
      ),
      _MethodOption(
        method: ArPlaceMethod.gnss,
        icon: ArIcons.gnss,
        title: 'ar.method.gnss'.getString(context),
        subtitle: 'ar.method.gnss_sub'.getString(context),
        enabled: false,
      ),
    ]..sort((a, b) {
        if (a.method == recommended) return -1;
        if (b.method == recommended) return 1;
        if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
        return 0;
      });

    return ArCard(
      padding: EdgeInsets.all(tablet ? 22 : 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: AppText.title('ar.method.title'.getString(context), weight: FontWeight.w800)),
              // Sunlight mode before the first scan: on a bright site the
              // setup chips are the first thing that washes out.
              IconButton(
                tooltip: 'ar.menu.sunlight'.getString(context),
                isSelected: sunlight,
                onPressed: () => ref.read(arPrefsProvider.notifier).setSunlight(!sunlight),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                style: IconButton.styleFrom(
                  backgroundColor: sunlight ? FeColors.primary : FeArColors.manualBg,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: Icon(ArIcons.sunlight, size: 20, color: sunlight ? Colors.white : FeColors.ink),
              ),
            ],
          ),
          const SizedBox(height: 4),
          AppText.bodySmall(
            where.isEmpty ? 'ar.method.subtitle_generic'.getString(context) : arTr(context, 'ar.method.subtitle', [where]),
            color: FeColors.ink2,
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < options.length; i++) ...[
            StaggeredEntrance(
              index: i,
              child: _MethodTile(
                option: options[i],
                recommended: options[i].method == recommended && options[i].enabled,
                onTap: options[i].enabled ? () => ctrl.chooseMethod(options[i].method) : null,
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => ctrl.toggleRemember(!setup.rememberChoice),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      height: 40,
                      child: Checkbox(
                        value: setup.rememberChoice,
                        activeColor: FeColors.primary,
                        onChanged: (v) => ctrl.toggleRemember(v ?? false),
                      ),
                    ),
                    Expanded(
                      child: AppText.bodyMedium(
                        arTr(context, 'ar.method.remember', [floorName]),
                        weight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (kDebugMode && !session.demo) const _DebugRecordingRow(),
        ],
      ),
    );
  }
}

/// Debug builds only: record this room with ARCore Recording & Playback, or
/// replay a recording instead of the camera, so one room can be re-run at a
/// desk (docs/ar-recording-playback.md). Never in a release build.
class _DebugRecordingRow extends ConsumerWidget {
  const _DebugRecordingRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(arSessionProvider);
    final ctrl = ref.read(arSessionProvider.notifier);
    final recording = s.recordingPath != null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.caption('ar.debug.title'.getString(context), color: FeColors.ink2, weight: FontWeight.w700),
          const SizedBox(height: 6),
          Row(
            children: [
              if (s.capabilities?.recording ?? false)
                Expanded(
                  child: ArSecondaryButton(
                    label: (recording ? 'ar.debug.stop' : 'ar.debug.record').getString(context),
                    icon: recording ? ArIcons.close : ArIcons.capture,
                    onPressed: s.playbackPath != null
                        ? null
                        : (recording ? ctrl.debugStopRecording : ctrl.debugStartRecording),
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: ArSecondaryButton(
                  label: (s.playbackPath == null ? 'ar.debug.replay' : 'ar.debug.live').getString(context),
                  icon: s.playbackPath == null ? ArIcons.resume : ArIcons.capture,
                  onPressed: recording
                      ? null
                      : () => s.playbackPath == null ? _pick(context, ctrl) : ctrl.debugReplay(null),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, ArSessionController ctrl) async {
    final files = await ArSessionController.listRecordings();
    if (!context.mounted) return;
    final path = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: AppText.titleMedium('ar.debug.replay'.getString(context), weight: FontWeight.w800),
        children: [
          if (files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: AppText.bodySmall('ar.debug.none'.getString(context), color: FeColors.ink2),
            ),
          for (final f in files)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(f.path),
              child: AppText.bodyMedium(f.path.split('/').last),
            ),
        ],
      ),
    );
    if (path != null) await ctrl.debugReplay(path);
  }
}

class _MethodOption {
  const _MethodOption({
    required this.method,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
  });
  final ArPlaceMethod method;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({required this.option, required this.recommended, required this.onTap});

  final _MethodOption option;
  final bool recommended;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final border = recommended ? FeColors.primary : FeColors.line;
    return Semantics(
      button: true,
      enabled: enabled,
      label: option.title,
      child: PressableScale(
        enabled: enabled,
        child: Material(
          color: recommended ? FeColors.infoSoft : FeColors.panel,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border, width: recommended ? 2 : 1),
              ),
              child: Opacity(
                opacity: enabled ? 1 : 0.5,
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: recommended ? FeColors.primary : FeArColors.manualBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(option.icon, size: 20, color: recommended ? Colors.white : FeColors.ink),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(child: AppText.titleSmall(option.title, weight: FontWeight.w700)),
                              if (recommended) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(color: FeColors.primary, borderRadius: BorderRadius.circular(99)),
                                  child: AppText.caption('ar.method.best_here'.getString(context), color: Colors.white, weight: FontWeight.w700),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          AppText.bodySmall(option.subtitle, color: FeColors.ink2),
                        ],
                      ),
                    ),
                    if (enabled) const ArDirectionalIcon(ArIcons.next, size: 18, color: FeColors.ink2),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
