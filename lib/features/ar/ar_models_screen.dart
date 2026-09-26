import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../domain/snag.dart' show SnagBuilding;
import '../../state/ar_catalog_controller.dart';
import '../../state/ar_demo_gateway.dart';
import '../../state/ar_downloads_controller.dart';
import '../../state/ar_prefs_controller.dart';
import '../../state/ar_view_models.dart';
import '../../state/snag_controller.dart';
import '../../theme/fe_ar_colors.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/motion.dart';
import 'ar_ui.dart';
import 'widgets/ar_chrome.dart';
import 'widgets/ar_mini_plan.dart';

/// `/ar` (TabModels / PhModels): building → floor → **tick the models to
/// show together**, with what is already on this device, what an update
/// costs, and a plain reason when a model can't be used. From an asset or a
/// work order the floor is found for the user; from the dashboard they pick
/// a building and floor once.
class ArModelsScreen extends ConsumerStatefulWidget {
  const ArModelsScreen({super.key, this.buildingId, this.floorId, this.assetId, this.workOrderId});

  final String? buildingId;
  final String? floorId;
  final String? assetId;
  final String? workOrderId;

  @override
  ConsumerState<ArModelsScreen> createState() => _ArModelsScreenState();
}

class _ArModelsScreenState extends ConsumerState<ArModelsScreen> {
  String? _buildingId;
  String? _floorId;
  Set<String>? _ticked;
  var _search = '';

  @override
  void initState() {
    super.initState();
    _buildingId = widget.buildingId;
    _floorId = widget.floorId;
  }

  ArEntryArgs get _entryArgs => (buildingId: _buildingId, floorId: _floorId, assetId: widget.assetId);

  Set<String> _defaultTicks(ArFloorSummary f) {
    final usable = f.models.where((m) => m.usable).toList();
    final preferred = usable.where((m) => m.discipline == 'architecture' || m.discipline == 'mep').map((m) => m.lineage).toSet();
    return preferred.isNotEmpty ? preferred : usable.map((m) => m.lineage).toSet();
  }

  void _open(ArEntry entry, ArFloorSummary floor) {
    final ticks = _ticked ?? _defaultTicks(floor);
    context.push(Routes.arSession(
      floorId: floor.floorId,
      assetId: entry.assetId,
      workOrderId: widget.workOrderId,
      models: ticks.toList(),
      space: entry.spaceName,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final demo = ref.watch(arPrefsProvider.select((p) => p.demo));
    final entryAsync = ref.watch(arEntryProvider(_entryArgs));
    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: 'ar.models.header'.getString(context),
        actions: [
          IconButton(
            tooltip: 'ar.models.scan_board'.getString(context),
            icon: const Icon(ArIcons.board),
            onPressed: () => context.push(Routes.scan),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: entryAsync.when(
          loading: () => const Center(child: TechSpinner()),
          error: (_, _) => _Problem(
            titleKey: 'ar.entry.floor_unavailable',
            bodyKey: 'ar.error.offline',
            onRetry: () => ref.invalidate(arEntryProvider(_entryArgs)),
          ),
          data: (entry) {
            if (entry.errorKey != null && entry.buildingId == null) {
              return _Problem(
                titleKey: entry.errorKey!,
                bodyKey: 'ar.entry.pick_instead',
                action: 'ar.entry.pick_building'.getString(context),
                onAction: () => setState(() {
                  _buildingId = null;
                  _floorId = null;
                }),
                showDemo: !demo,
              );
            }
            final buildingId = entry.buildingId ?? _buildingId;
            if (buildingId == null) {
              return _BuildingPicker(
                onPick: (b) => setState(() => _buildingId = b.id),
                showDemo: !demo,
              );
            }
            return _FloorsView(
              buildingId: buildingId,
              buildingName: entry.buildingName,
              selectedFloorId: entry.floorId ?? _floorId,
              ticked: _ticked,
              search: _search,
              onSearch: (v) => setState(() => _search = v),
              onFloor: (f) => setState(() {
                _floorId = f.floorId;
                _ticked = null;
              }),
              onToggle: (floor, lineage) => setState(() {
                final t = {...(_ticked ?? _defaultTicks(floor))};
                if (!t.remove(lineage)) t.add(lineage);
                _ticked = t;
              }),
              defaultTicks: _defaultTicks,
              onOpen: (floor) => _open(entry, floor),
            );
          },
        ),
      ),
    );
  }
}

class _Problem extends ConsumerWidget {
  const _Problem({
    required this.titleKey,
    required this.bodyKey,
    this.onRetry,
    this.action,
    this.onAction,
    this.showDemo = true,
  });

  final String titleKey;
  final String bodyKey;
  final VoidCallback? onRetry;
  final String? action;
  final VoidCallback? onAction;
  final bool showDemo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TechEmptyState(icon: ArIcons.warning, title: titleKey.getString(context), subtitle: bodyKey.getString(context)),
        const SizedBox(height: 16),
        if (onRetry != null) ArPrimaryButton(label: 'ar.common.retry'.getString(context), onPressed: onRetry, icon: ArIcons.sync),
        if (action != null) ...[
          const SizedBox(height: 10),
          ArPrimaryButton(label: action!, onPressed: onAction),
        ],
        if (showDemo) ...[
          const SizedBox(height: 10),
          const _DemoOffer(),
        ],
      ],
    );
  }
}

class _DemoOffer extends ConsumerWidget {
  const _DemoOffer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      onPressed: () => ref.read(arPrefsProvider.notifier).setDemo(true),
      style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      icon: const Icon(ArIcons.demo, size: 16, color: FeArColors.placedFg),
      label: AppText.label('ar.models.try_demo'.getString(context), color: FeArColors.placedFg, weight: FontWeight.w700),
    );
  }
}

/// No building known (dashboard entry): the buildings this technician can
/// see, from the same list the Snag Assistant uses.
class _BuildingPicker extends ConsumerWidget {
  const _BuildingPicker({required this.onPick, required this.showDemo});
  final ValueChanged<SnagBuilding> onPick;
  final bool showDemo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gateway = ref.watch(arGatewayProvider);
    if (gateway.isDemo) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _BuildingTile(
            building: const SnagBuilding(id: DemoArGateway.buildingId, name: DemoArGateway.buildingName),
            onTap: () => onPick(const SnagBuilding(id: DemoArGateway.buildingId, name: DemoArGateway.buildingName)),
          ),
        ],
      );
    }
    final buildings = ref.watch(snagBuildingsProvider);
    return buildings.when(
      loading: () => const Center(child: TechSpinner()),
      error: (_, _) => _Problem(
        titleKey: 'ar.models.buildings_error',
        bodyKey: 'ar.error.offline',
        onRetry: () => ref.invalidate(snagBuildingsProvider),
        showDemo: showDemo,
      ),
      data: (list) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppText.titleMedium('ar.models.pick_building'.getString(context), weight: FontWeight.w800),
          const SizedBox(height: 4),
          AppText.bodySmall('ar.models.pick_building_sub'.getString(context), color: FeColors.ink2),
          const SizedBox(height: 12),
          if (list.isEmpty)
            TechEmptyState(icon: ArIcons.building, title: 'ar.models.no_buildings'.getString(context))
          else
            for (var i = 0; i < list.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: StaggeredEntrance(index: i, child: _BuildingTile(building: list[i], onTap: () => onPick(list[i]))),
              ),
          if (showDemo) const _DemoOffer(),
        ],
      ),
    );
  }
}

class _BuildingTile extends StatelessWidget {
  const _BuildingTile({required this.building, required this.onTap});
  final SnagBuilding building;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TechCard(
      onTap: onTap,
      child: Row(
        children: [
          const IconBadgeBox(icon: ArIcons.building),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.titleSmall(building.name, weight: FontWeight.w700),
                if (building.location != null) AppText.bodySmall(building.location!, color: FeColors.ink2),
              ],
            ),
          ),
          const ArDirectionalIcon(ArIcons.next, color: FeColors.ink2),
        ],
      ),
    );
  }
}

/// A 44 px rounded icon box for list rows.
class IconBadgeBox extends StatelessWidget {
  const IconBadgeBox({super.key, required this.icon, this.color = FeColors.primary});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
    child: Icon(icon, color: color, size: 20),
  );
}

class _FloorsView extends ConsumerWidget {
  const _FloorsView({
    required this.buildingId,
    required this.buildingName,
    required this.selectedFloorId,
    required this.ticked,
    required this.search,
    required this.onSearch,
    required this.onFloor,
    required this.onToggle,
    required this.defaultTicks,
    required this.onOpen,
  });

  final String buildingId;
  final String? buildingName;
  final String? selectedFloorId;
  final Set<String>? ticked;
  final String search;
  final ValueChanged<String> onSearch;
  final ValueChanged<ArFloorSummary> onFloor;
  final void Function(ArFloorSummary floor, String lineage) onToggle;
  final Set<String> Function(ArFloorSummary) defaultTicks;
  final ValueChanged<ArFloorSummary> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floorsAsync = ref.watch(arFloorsProvider(buildingId));
    return floorsAsync.when(
      loading: () => const Center(child: TechSpinner()),
      error: (_, _) => _Problem(
        titleKey: 'ar.models.floors_error',
        bodyKey: 'ar.error.offline',
        onRetry: () => ref.invalidate(arFloorsProvider(buildingId)),
      ),
      data: (floors) {
        if (floors.isEmpty) {
          return const _Problem(titleKey: 'ar.models.no_floors', bodyKey: 'ar.models.no_floors_body');
        }
        ArFloorSummary? floor;
        for (final f in floors) {
          if (f.floorId == selectedFloorId) floor = f;
        }
        return LayoutBuilder(
          builder: (context, c) {
            final tablet = arIsTablet(c);
            final list = _ModelsList(
              buildingName: buildingName,
              floors: floors,
              floor: floor,
              ticked: floor == null ? const {} : (ticked ?? defaultTicks(floor)),
              search: search,
              onSearch: onSearch,
              onFloor: onFloor,
              onToggle: onToggle,
              tablet: tablet,
            );
            final footer = floor == null ? null : _OpenFooter(floor: floor, ticked: ticked ?? defaultTicks(floor), onOpen: onOpen, tablet: tablet);
            if (!tablet || floor == null) {
              return Column(
                children: [
                  Expanded(child: list),
                  ?footer,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 11,
                  child: Column(children: [Expanded(child: list), footer!]),
                ),
                Expanded(flex: 9, child: _Preview(floor: floor)),
              ],
            );
          },
        );
      },
    );
  }
}

class _ModelsList extends ConsumerWidget {
  const _ModelsList({
    required this.buildingName,
    required this.floors,
    required this.floor,
    required this.ticked,
    required this.search,
    required this.onSearch,
    required this.onFloor,
    required this.onToggle,
    required this.tablet,
  });

  final String? buildingName;
  final List<ArFloorSummary> floors;
  final ArFloorSummary? floor;
  final Set<String> ticked;
  final String search;
  final ValueChanged<String> onSearch;
  final ValueChanged<ArFloorSummary> onFloor;
  final void Function(ArFloorSummary floor, String lineage) onToggle;
  final bool tablet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = floor;
    final q = search.trim().toLowerCase();
    final downloads = ref.watch(arDownloadsProvider);
    final models = f == null
        ? const <ArModelEntry>[]
        : f.models.where((m) => q.isEmpty || m.modelName.toLowerCase().contains(q) || m.lineage.toLowerCase().contains(q)).toList();
    final progress = f == null ? null : downloads[f.floorId];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        if (buildingName != null) ArEyebrow(buildingName!),
        const SizedBox(height: 4),
        AppText.title(
          f == null ? 'ar.models.pick_floor'.getString(context) : arTr(context, 'ar.models.floor_models', [f.name]),
          weight: FontWeight.w800,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final x in floors)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(
                    label: AppText.bodySmall(x.name, weight: FontWeight.w700, color: x.floorId == f?.floorId ? Colors.white : FeColors.ink),
                    selected: x.floorId == f?.floorId,
                    selectedColor: FeColors.primary,
                    backgroundColor: FeColors.panel,
                    showCheckmark: false,
                    onSelected: (_) => onFloor(x),
                  ),
                ),
            ],
          ),
        ),
        if (f != null) ...[
          const SizedBox(height: 12),
          TextField(
            onChanged: onSearch,
            decoration: InputDecoration(
              hintText: 'ar.models.search'.getString(context),
              prefixIcon: const Icon(ArIcons.search, size: 18),
              filled: true,
              fillColor: FeColors.panel,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: FeColors.line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: FeColors.line)),
            ),
          ),
          if (!tablet) ...[
            const SizedBox(height: 12),
            _StatsRow(floor: f),
          ],
          const SizedBox(height: 16),
          ArEyebrow('ar.models.tick'.getString(context)),
          const SizedBox(height: 8),
          if (!f.hasUsableModel)
            ArHintRow(text: 'ar.models.none_ready'.getString(context), danger: true),
          for (var i = 0; i < models.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: StaggeredEntrance(
                index: i,
                child: _ModelTile(
                  model: models[i],
                  ticked: ticked.contains(models[i].lineage),
                  tablet: tablet,
                  downloading: progress != null && !progress.done && progress.error == null,
                  onToggle: models[i].usable ? () => onToggle(f, models[i].lineage) : null,
                  onUpdate: () => ref.read(arDownloadsProvider.notifier).downloadFloor(f.floorId),
                ),
              ),
            ),
          if (progress != null && !progress.done && progress.error == null) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: progress.totalBytes == 0 ? null : progress.fraction, color: FeColors.primary, backgroundColor: FeColors.line),
            const SizedBox(height: 6),
            AppText.caption(
              arTr(context, 'ar.models.downloading', [arMegabytes(context, progress.doneBytes), arMegabytes(context, progress.totalBytes)]),
              color: FeColors.ink2,
            ),
          ] else if (progress?.error != null) ...[
            ArHintRow(text: progress!.error!.getString(context), danger: true),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(ArIcons.offline, size: 14, color: FeColors.ink2),
              const SizedBox(width: 6),
              Expanded(
                child: AppText.caption((tablet ? 'ar.models.offline_note_tablet' : 'ar.models.offline_note').getString(context), color: FeColors.ink2),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.ticked,
    required this.tablet,
    required this.downloading,
    required this.onToggle,
    required this.onUpdate,
  });

  final ArModelEntry model;
  final bool ticked;
  final bool tablet;
  final bool downloading;
  final VoidCallback? onToggle;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final usable = model.usable;
    final date = model.publishedAt == null ? null : MaterialLocalizations.of(context).formatShortMonthDay(model.publishedAt!);
    final sub = !usable
        ? (model.reason ?? 'ar.models.state.${model.state.name}'.getString(context))
        : [
            if (model.version != null) arTr(context, 'ar.models.build_v', [model.version!]),
            ?date,
            if (model.changedTiles > 0) arTr(context, 'ar.models.tiles_changed', [model.changedTiles]),
          ].join(' · ');
    Widget trailing;
    if (!usable) {
      trailing = const SizedBox.shrink();
    } else if (model.fullyOnDevice) {
      trailing = _Pill(
        text: (tablet ? 'ar.models.on_tablet' : 'ar.models.on_phone').getString(context),
        bg: FeArColors.lockedBg,
        fg: FeArColors.lockedFg,
        icon: ArIcons.onDevice,
      );
    } else if (model.updateAvailable || model.onDeviceBytes > 0) {
      trailing = _Pill(
        text: model.onDeviceBytes > 0 && model.missingBytes > 0
            ? arTr(context, 'ar.models.update', [arMegabytes(context, model.missingBytes)])
            : 'ar.models.update_plain'.getString(context),
        bg: FeColors.infoSoft,
        fg: FeColors.primary,
        icon: ArIcons.download,
        onTap: downloading ? null : onUpdate,
      );
    } else {
      trailing = _Pill(
        text: arMegabytes(context, model.bytes),
        bg: FeArColors.manualBg,
        fg: FeArColors.manualFg,
        icon: ArIcons.download,
        onTap: downloading ? null : onUpdate,
      );
    }
    return Opacity(
      opacity: usable ? 1 : 0.6,
      child: TechCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        onTap: onToggle,
        borderColor: ticked ? FeColors.primary : null,
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: Checkbox(
                value: usable && ticked,
                onChanged: onToggle == null ? null : (_) => onToggle!(),
                activeColor: FeColors.primary,
              ),
            ),
            IconBadgeBox(icon: ArIcons.discipline(model.discipline), color: usable ? FeColors.primary : FeColors.ink2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText.titleSmall(model.modelName, weight: FontWeight.w700),
                  AppText.bodySmall(sub, color: usable ? FeColors.ink2 : FeColors.danger),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.bg, required this.fg, this.icon, this.onTap});
  final String text;
  final Color bg;
  final Color fg;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 5)],
              AppText.caption(text, color: fg, weight: FontWeight.w700),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.floor});
  final ArFloorSummary floor;

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, String value) => Expanded(
      child: TechCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        radius: 14,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText.caption(label, color: FeColors.ink2),
            AppText.titleSmall(value, weight: FontWeight.w800),
          ],
        ),
      ),
    );
    return Row(
      children: [
        stat('ar.models.stat_boards'.getString(context), arTr(context, 'ar.models.n_active', [floor.markerCount])),
        const SizedBox(width: 8),
        stat('ar.models.stat_corners'.getString(context), '${floor.cornerCount}'),
        const SizedBox(width: 8),
        stat('ar.models.stat_grid'.getString(context), floor.gridSummary.isEmpty ? '—' : floor.gridSummary),
      ],
    );
  }
}

class _OpenFooter extends StatelessWidget {
  const _OpenFooter({required this.floor, required this.ticked, required this.onOpen, required this.tablet});
  final ArFloorSummary floor;
  final Set<String> ticked;
  final ValueChanged<ArFloorSummary> onOpen;
  final bool tablet;

  @override
  Widget build(BuildContext context) {
    final n = floor.models.where((m) => m.usable && ticked.contains(m.lineage)).length;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(
        color: FeColors.panel,
        border: Border(top: BorderSide(color: FeColors.line)),
      ),
      child: ArPrimaryButton(
        label: n == 1 ? 'ar.models.open_one'.getString(context) : arTr(context, 'ar.models.open_n', [n]),
        icon: ArIcons.box,
        onPressed: n == 0 ? null : () => onOpen(floor),
      ),
    );
  }
}

/// iPad: the floor preview (plan, federation, boards, corners, grid).
class _Preview extends ConsumerWidget {
  const _Preview({required this.floor});
  final ArFloorSummary floor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usable = floor.models.where((m) => m.usable).map((m) => m.modelName).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
      child: TechCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText.titleMedium(arTr(context, 'ar.models.preview', [floor.name]), weight: FontWeight.w800),
            const SizedBox(height: 10),
            Expanded(child: ArMiniPlan(plan: ref.watch(arFloorPlanProvider(floor.floorId)).valueOrNull, showSpaceNames: true)),
            const SizedBox(height: 12),
            if (usable.length > 1)
              ArSuccessRow(text: arTr(context, 'ar.models.federated', [usable.join(' + ')])),
            const SizedBox(height: 10),
            _PreviewRow(label: 'ar.models.stat_boards_long'.getString(context), value: arTr(context, 'ar.models.n_active', [floor.markerCount])),
            _PreviewRow(label: 'ar.models.stat_corners_long'.getString(context), value: '${floor.cornerCount}'),
            _PreviewRow(label: 'ar.models.stat_grid'.getString(context), value: floor.gridSummary.isEmpty ? '—' : floor.gridSummary),
          ],
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: AppText.bodyMedium(label, color: FeColors.ink2)),
          AppText.bodyMedium(value, weight: FontWeight.w800),
        ],
      ),
    );
  }
}
