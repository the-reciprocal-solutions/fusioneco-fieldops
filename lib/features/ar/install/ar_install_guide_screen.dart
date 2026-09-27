import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/ar/marker_code.dart';
import '../../../state/ar_catalog_controller.dart';
import '../../../state/ar_permissions.dart';
import '../../../state/ar_view_models.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/common.dart';
import '../../../widgets/fe_header.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import '../widgets/ar_entry_widgets.dart' show ArInstallNotEnabled;
import '../widgets/ar_mini_plan.dart';

/// `/ar/install/:code` — I2 Find the spot: where the board goes, shown on
/// the model around it with the ghost board, the nearby equipment named,
/// and three plain steps. "It's up · scan it" opens the camera for the
/// self-check (I3), which measures everything.
class ArInstallGuideScreen extends ConsumerWidget {
  const ArInstallGuideScreen({super.key, required this.code, this.floorId});

  final String code;
  final String? floorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canonical = MarkerCode.normalize(code) ?? code;
    final floorId = this.floorId;
    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'ar.guide.header'.getString(context)),
      body: SafeArea(
        top: false,
        child: !ref.watch(arInstallAllowedProvider)
            ? const ArInstallNotEnabled()
            : floorId == null
            ? _NoFloor(code: canonical)
            : ref.watch(arInstallFloorProvider(floorId)).when(
                  loading: () => const Center(child: TechSpinner()),
                  error: (_, _) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: TechEmptyState(icon: ArIcons.warning, title: 'ar.install.load_error'.getString(context), subtitle: 'ar.error.offline'.getString(context)),
                  ),
                  data: (floor) {
                    final m = floor.markerByCode(canonical);
                    if (m == null) return _NoFloor(code: canonical);
                    return _Guide(marker: m, floor: floor, plan: ref.watch(arFloorPlanProvider(floorId)).valueOrNull);
                  },
                ),
      ),
    );
  }
}

/// The floor pack for the guide (markers + plan context).
final arInstallFloorProvider = FutureProvider.autoDispose.family<ArFloorContext, String>(
  (ref, floorId) => ref.watch(arGatewayProvider).floorContext(floorId),
);

class _NoFloor extends StatelessWidget {
  const _NoFloor({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TechEmptyState(
          icon: ArIcons.board,
          title: arTr(context, 'ar.guide.unknown', [MarkerCode.display(code)]),
          subtitle: 'ar.guide.unknown_body'.getString(context),
        ),
        const SizedBox(height: 12),
        ArPrimaryButton(label: 'ar.install.header'.getString(context), onPressed: () => context.pushReplacement(Routes.arInstall())),
      ],
    );
  }
}

class _Guide extends StatelessWidget {
  const _Guide({required this.marker, required this.floor, required this.plan});
  final ArMarkerInfo marker;
  final ArFloorContext floor;
  final ArPlan? plan;

  @override
  Widget build(BuildContext context) {
    final m = marker;
    final space = plan?.spaceAt(m.posTile.x, m.posTile.z)?.name ?? _spaceFrom(m.locationText);
    final wallKey = arWallKey(m.normalTile.x, m.normalTile.z);
    final nearby = _nearestEquipment(m);
    final height = m.heightAboveFloorM ?? (m.posTile.y - floor.floorDatumY - floor.floorFinishOffsetM);
    final steps = <String>[
      space == null ? 'ar.guide.step1_plain'.getString(context) : arTr(context, 'ar.guide.step1', [space]),
      nearby == null
          ? arTr(context, 'ar.guide.step2', [wallKey.getString(context)])
          : arTr(context, 'ar.guide.step2_near', [wallKey.getString(context), nearby.$1, arMetres(context, nearby.$2)]),
      m.installNote == null
          ? arTr(context, 'ar.guide.step3', [arMetres(context, height)])
          : arTr(context, 'ar.guide.step3_note', [m.installNote!, arMetres(context, height)]),
    ];
    final planCard = TechCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.titleSmall('ar.guide.model_view'.getString(context), weight: FontWeight.w800),
          AppText.caption('ar.guide.model_view_sub'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 8),
          SizedBox(
            height: 240,
            child: ArMiniPlan(
              plan: plan,
              markers: floor.markers.where((x) => x.code != m.code).toList(),
              ghost: m.posTile,
              focus: m.posTile.xz,
              focusRadiusM: 5,
            ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, c) {
        final tablet = arIsTablet(c);
        final details = ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AppText.headlineSmall(m.label, weight: FontWeight.w800),
            AppText.bodyMedium([if (space != null) space, wallKey.getString(context)].join(' · '), color: FeColors.ink2),
            const SizedBox(height: 14),
            if (!tablet) ...[planCard, const SizedBox(height: 14)],
            for (var i = 0; i < steps.length; i++) _Step(n: i + 1, text: steps[i]),
            const SizedBox(height: 18),
            ArPrimaryButton(
              label: 'ar.guide.scan_it'.getString(context),
              icon: ArIcons.board,
              onPressed: () => context.push(Routes.arSession(floorId: floor.floorId, install: m.code, method: 'board')),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => _cantPlace(context),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: AppText.label('ar.guide.cant'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
            ),
          ],
        );
        if (!tablet) return details;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: details),
            Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 16, 16, 16), child: SingleChildScrollView(child: planCard))),
          ],
        );
      },
    );
  }

  String? _spaceFrom(String? location) {
    if (location == null) return null;
    final i = location.indexOf('·');
    return (i < 0 ? location : location.substring(0, i)).trim();
  }

  (String, double)? _nearestEquipment(ArMarkerInfo m) {
    final p = plan;
    if (p == null) return null;
    (String, double)? best;
    for (final e in p.equipment) {
      if (e.polygon.isEmpty) continue;
      var cx = 0.0, cz = 0.0;
      for (final v in e.polygon) {
        cx += v.x;
        cz += v.y;
      }
      cx /= e.polygon.length;
      cz /= e.polygon.length;
      final dx = cx - m.posTile.x;
      final dz = cz - m.posTile.z;
      final d = math.sqrt(dx * dx + dz * dz);
      // Only equipment within 6 m helps someone find a wall spot.
      if (d < 6 && (best == null || d < best.$2)) best = (e.name, d);
    }
    return best;
  }

  void _cantPlace(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: FeColors.panel,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppText.titleMedium('ar.guide.cant_title'.getString(context), weight: FontWeight.w800),
              const SizedBox(height: 8),
              AppText.bodyMedium('ar.guide.cant_body'.getString(context), color: FeColors.ink2),
              const SizedBox(height: 16),
              ArPrimaryButton(label: 'ar.common.done'.getString(context), onPressed: () => Navigator.of(context).pop()),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: FeColors.primary, shape: BoxShape.circle),
            child: AppText.caption('$n', color: Colors.white, weight: FontWeight.w800),
          ),
          const SizedBox(width: 12),
          Expanded(child: AppText.bodyMedium(text)),
        ],
      ),
    );
  }
}
