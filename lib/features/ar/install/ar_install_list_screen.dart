import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../domain/snag.dart' show SnagBuilding;
import '../../../state/ar_catalog_controller.dart';
import '../../../state/ar_demo_gateway.dart';
import '../../../state/ar_install_controller.dart';
import '../../../state/ar_permissions.dart';
import '../../../state/snag_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/common.dart';
import '../../../widgets/fe_header.dart';
import '../../../widgets/motion.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import '../widgets/ar_entry_widgets.dart' show ArInstallNotEnabled;
import '../widgets/ar_mini_plan.dart';

/// `/ar/install?floorId=` — I1 Install run: the floor's boards still to go
/// up, in walking order, like a route: n of N, time left, the plan with the
/// walking order (done ✓, next pulsing, pending grey), and a big **Next**
/// card. The push link `/technician/ar/install?floorId=` lands here.
class ArInstallListScreen extends ConsumerStatefulWidget {
  const ArInstallListScreen({super.key, this.floorId});

  final String? floorId;

  @override
  ConsumerState<ArInstallListScreen> createState() => _ArInstallListScreenState();
}

class _ArInstallListScreenState extends ConsumerState<ArInstallListScreen> {
  String? _floorId;
  String? _buildingId;

  @override
  void initState() {
    super.initState();
    _floorId = widget.floorId;
  }

  @override
  Widget build(BuildContext context) {
    final floorId = _floorId;
    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'ar.install.header'.getString(context)),
      body: SafeArea(
        top: false,
        child: !ref.watch(arInstallAllowedProvider)
            ? const ArInstallNotEnabled()
            : (floorId == null ? _pickFloor(context) : _RunView(floorId: floorId)),
      ),
    );
  }

  /// A push without a floor, or the dashboard: pick building then floor.
  Widget _pickFloor(BuildContext context) {
    final gateway = ref.watch(arGatewayProvider);
    final buildingId = _buildingId ?? (gateway.isDemo ? DemoArGateway.buildingId : null);
    if (buildingId == null) {
      final buildings = ref.watch(snagBuildingsProvider);
      return buildings.when(
        loading: () => const Center(child: TechSpinner()),
        error: (_, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: TechEmptyState(icon: ArIcons.warning, title: 'ar.models.buildings_error'.getString(context), subtitle: 'ar.error.offline'.getString(context)),
        ),
        data: (list) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AppText.titleMedium('ar.models.pick_building'.getString(context), weight: FontWeight.w800),
            const SizedBox(height: 12),
            for (final SnagBuilding b in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TechCard(
                  onTap: () => setState(() => _buildingId = b.id),
                  child: Row(
                    children: [
                      const Icon(ArIcons.building, color: FeColors.primary),
                      const SizedBox(width: 12),
                      Expanded(child: AppText.titleSmall(b.name, weight: FontWeight.w700)),
                      const ArDirectionalIcon(ArIcons.next, color: FeColors.ink2),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final floors = ref.watch(arFloorsProvider(buildingId));
    return floors.when(
      loading: () => const Center(child: TechSpinner()),
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: TechEmptyState(icon: ArIcons.warning, title: 'ar.models.floors_error'.getString(context), subtitle: 'ar.error.offline'.getString(context)),
      ),
      data: (list) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppText.titleMedium('ar.install.pick_floor'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 12),
          for (final f in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TechCard(
                onTap: () => setState(() => _floorId = f.floorId),
                child: Row(
                  children: [
                    const Icon(ArIcons.install, color: FeColors.primary),
                    const SizedBox(width: 12),
                    Expanded(child: AppText.titleSmall(f.name, weight: FontWeight.w700)),
                    AppText.bodySmall(arTr(context, 'ar.models.n_active', [f.markerCount]), color: FeColors.ink2),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RunView extends ConsumerWidget {
  const _RunView({required this.floorId});
  final String floorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runAsync = ref.watch(arInstallRunProvider(floorId));
    final plan = ref.watch(arFloorPlanProvider(floorId)).valueOrNull;
    return runAsync.when(
      loading: () => const Center(child: TechSpinner()),
      error: (_, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TechEmptyState(icon: ArIcons.warning, title: 'ar.install.load_error'.getString(context), subtitle: 'ar.error.offline'.getString(context)),
          const SizedBox(height: 12),
          ArPrimaryButton(label: 'ar.common.retry'.getString(context), onPressed: () => ref.invalidate(arInstallRunProvider(floorId))),
        ],
      ),
      data: (run) {
        final next = run.next;
        final stops = [
          for (final s in run.stops)
            ArPlanStop(number: s.order, pos: s.marker.posTile, done: s.done, next: next != null && s.marker.code == next.marker.code),
        ];
        final planWidget = ArMiniPlan(plan: plan, stops: stops, showSpaceNames: true);
        return LayoutBuilder(
          builder: (context, c) {
            final tablet = arIsTablet(c);
            final list = ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ArEyebrow(arTr(context, 'ar.install.where', [run.floor.buildingName, run.floor.floorName])),
                const SizedBox(height: 4),
                AppText.title(arTr(context, 'ar.install.up_count', [run.doneCount, run.total]), weight: FontWeight.w800),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: run.total == 0 ? 0 : run.doneCount / run.total,
                          minHeight: 10,
                          color: FeColors.success,
                          backgroundColor: FeColors.line,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    AppText.bodySmall(arTr(context, 'ar.install.minutes_left', [run.minutesLeft]), color: FeColors.ink2),
                  ],
                ),
                if (!tablet) ...[
                  const SizedBox(height: 14),
                  TechCard(padding: const EdgeInsets.all(8), child: SizedBox(height: 210, child: planWidget)),
                ],
                const SizedBox(height: 16),
                if (next == null)
                  TechCard(
                    tint: FeColors.successSoft,
                    child: Row(
                      children: [
                        const Icon(ArIcons.celebrate, color: FeColors.success, size: 28),
                        const SizedBox(width: 12),
                        Expanded(child: AppText.titleSmall('ar.install.all_up'.getString(context), weight: FontWeight.w800)),
                      ],
                    ),
                  )
                else
                  _NextCard(stop: next, floorId: floorId),
                const SizedBox(height: 16),
                for (var i = 0; i < run.stops.length; i++)
                  if (next == null || run.stops[i].marker.code != next.marker.code)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: StaggeredEntrance(index: i, child: _StopRow(stop: run.stops[i], floorId: floorId)),
                    ),
                const SizedBox(height: 8),
                ArSecondaryButton(label: 'ar.install.scan_any'.getString(context), icon: ArIcons.board, onPressed: () => context.push(Routes.scan)),
              ],
            );
            if (!tablet) return list;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 10, child: list),
                Expanded(
                  flex: 11,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                    child: TechCard(padding: const EdgeInsets.all(10), child: planWidget),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _NextCard extends StatelessWidget {
  const _NextCard({required this.stop, required this.floorId});
  final ArInstallStop stop;
  final String floorId;

  @override
  Widget build(BuildContext context) {
    final m = stop.marker;
    final leg = stop.legFromPreviousM;
    return TechCard(
      dark: true,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText.caption(
            leg == null ? 'ar.install.next'.getString(context) : arTr(context, 'ar.install.next_leg', [arMetres(context, leg)]),
            color: Colors.white70,
            weight: FontWeight.w800,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: FeColors.primary, shape: BoxShape.circle),
                child: AppText.titleSmall('${stop.order}', color: Colors.white, weight: FontWeight.w800),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.title(m.label, color: Colors.white, weight: FontWeight.w800),
                    AppText.bodySmall(
                      [
                        ?m.locationText,
                        if (m.heightAboveFloorM != null) arMetres(context, m.heightAboveFloorM!),
                      ].join(' · '),
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ArPrimaryButton(
            label: 'ar.install.find_spot'.getString(context),
            icon: ArIcons.pin,
            onPressed: () => context.push(Routes.arInstallGuide(m.code, floorId: floorId)),
          ),
        ],
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({required this.stop, required this.floorId});
  final ArInstallStop stop;
  final String floorId;

  @override
  Widget build(BuildContext context) {
    final m = stop.marker;
    return TechCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: stop.done ? null : () => context.push(Routes.arInstallGuide(m.code, floorId: floorId)),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: stop.done ? FeColors.success : FeColors.line, shape: BoxShape.circle),
            child: stop.done
                ? const Icon(ArIcons.check, size: 16, color: Colors.white)
                : AppText.caption('${stop.order}', color: FeColors.ink, weight: FontWeight.w800),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.titleSmall(m.label, weight: FontWeight.w700, color: stop.done ? FeColors.ink2 : FeColors.ink),
                if (m.locationText != null) AppText.bodySmall(m.locationText!, color: FeColors.ink2),
              ],
            ),
          ),
          if (!stop.done) const ArDirectionalIcon(ArIcons.next, size: 16, color: FeColors.ink2),
        ],
      ),
    );
  }
}
