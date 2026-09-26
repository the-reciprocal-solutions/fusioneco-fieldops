import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../state/ar_catalog_controller.dart';
import '../../../state/ar_session_controller.dart';
import '../../../state/ar_setup_controller.dart';
import '../../../state/ar_workspace_controller.dart';
import '../../../state/providers.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/tech_popup.dart';
import '../ar_ui.dart';
import '../widgets/ar_chrome.dart';
import 'ar_discipline_legend.dart';

/// GAMMA's flat 13-item menu, regrouped (§2.9): **Position** (re-align,
/// save a board here, fine-tune) · **View** (floor plan, gridlines, torch,
/// save view) · **Project** (sync, share, change floor or models). Layers
/// is its own panel: models, what to show, phase, colour-by, opacity and
/// floors. iPad shows both side by side in a 760 px panel; the phone shows
/// one full-height sheet with a Menu | Layers switch.

class ArMenuPanelTablet extends StatelessWidget {
  const ArMenuPanelTablet({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: GestureDetector(onTap: onClose, child: const ColoredBox(color: Colors.black26))),
        PositionedDirectional(
          end: 20,
          top: 20,
          bottom: 20,
          width: 760,
          child: Material(
            color: FeColors.panel,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _PanelColumn(
                    title: 'ar.menu.title'.getString(context),
                    onClose: null,
                    child: _MenuList(onDone: onClose),
                  ),
                ),
                const VerticalDivider(width: 1, color: FeColors.line),
                Expanded(
                  child: _PanelColumn(
                    title: 'ar.layers.title'.getString(context),
                    onClose: onClose,
                    child: const _LayersList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ArMenuPanelPhone extends StatefulWidget {
  const ArMenuPanelPhone({super.key, required this.onClose, required this.initialTab});
  final VoidCallback onClose;
  final ArPanel initialTab;

  @override
  State<ArMenuPanelPhone> createState() => _ArMenuPanelPhoneState();
}

class _ArMenuPanelPhoneState extends State<ArMenuPanelPhone> {
  late bool _layers = widget.initialTab == ArPanel.layers;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 8;
    return Stack(
      children: [
        Positioned.fill(child: GestureDetector(onTap: widget.onClose, child: const ColoredBox(color: Colors.black38))),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          top: top,
          child: Material(
            color: FeColors.panel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(value: false, label: AppText.label('ar.menu.title'.getString(context))),
                            ButtonSegment(value: true, label: AppText.label('ar.layers.title'.getString(context))),
                          ],
                          selected: {_layers},
                          showSelectedIcon: false,
                          onSelectionChanged: (v) => setState(() => _layers = v.first),
                        ),
                      ),
                      IconButton(
                        tooltip: 'ar.common.close'.getString(context),
                        icon: const Icon(ArIcons.close),
                        onPressed: widget.onClose,
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + MediaQuery.paddingOf(context).bottom),
                    child: _layers ? const _LayersList() : _MenuList(onDone: widget.onClose),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PanelColumn extends StatelessWidget {
  const _PanelColumn({required this.title, required this.child, this.onClose});
  final String title;
  final Widget child;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
          child: Row(
            children: [
              Expanded(child: AppText.title(title, weight: FontWeight.w800)),
              if (onClose != null)
                IconButton(
                  tooltip: 'ar.common.close'.getString(context),
                  icon: const Icon(ArIcons.close),
                  onPressed: onClose,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                ),
            ],
          ),
        ),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: child)),
      ],
    );
  }
}

// ------------------------------------------------------------------- menu

class _MenuList extends ConsumerWidget {
  const _MenuList({required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(arSessionProvider);
    final ws = ref.watch(arWorkspaceProvider);
    final setup = ref.read(arSetupProvider.notifier);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final queued = ref.watch(pendingMutationCountProvider).valueOrNull ?? 0;
    final floor = s.floor;

    void run(VoidCallback f) {
      onDone();
      f();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArEyebrow('ar.menu.position'.getString(context)),
        _MenuRow(icon: ArIcons.realign, label: 'ar.menu.realign'.getString(context), onTap: () => run(() => setup.reAlign())),
        _MenuRow(icon: ArIcons.board, label: 'ar.menu.save_board'.getString(context), onTap: () => run(setup.saveBoardFromWork)),
        _MenuRow(icon: ArIcons.fineTune, label: 'ar.menu.fine_tune'.getString(context), onTap: () => run(setup.fineTuneFromWork)),
        const SizedBox(height: 14),
        ArEyebrow('ar.menu.view'.getString(context)),
        _MenuRow(
          icon: ArIcons.plan,
          label: 'ar.menu.floor_plan'.getString(context),
          selected: ws.planInCorner,
          onTap: ctrl.togglePlanInCorner,
        ),
        _MenuRow(
          icon: ArIcons.grid,
          label: 'ar.menu.gridlines'.getString(context),
          selected: s.gridVisible,
          onTap: () => ref.read(arSessionProvider.notifier).setGridVisible(!s.gridVisible),
        ),
        _MenuRow(icon: ArIcons.torch, label: 'ar.menu.torch'.getString(context), sub: 'ar.menu.soon'.getString(context)),
        _MenuRow(icon: ArIcons.saveView, label: 'ar.menu.save_view'.getString(context), sub: 'ar.menu.soon'.getString(context)),
        const SizedBox(height: 14),
        ArEyebrow('ar.menu.project'.getString(context)),
        _MenuRow(
          icon: ArIcons.sync,
          label: queued > 0 ? arTr(context, 'ar.menu.sync_queued', [queued]) : 'ar.menu.sync'.getString(context),
          onTap: () async {
            await ref.read(syncClientProvider).flushQueue();
            if (context.mounted) showTechPopup(context, message: 'ar.menu.synced'.getString(context));
          },
        ),
        _MenuRow(icon: ArIcons.share, label: 'ar.menu.share'.getString(context), sub: 'ar.menu.soon'.getString(context)),
        _MenuRow(
          icon: ArIcons.changeFloor,
          label: 'ar.menu.change'.getString(context),
          onTap: floor == null
              ? null
              : () => context.pushReplacement(Routes.arModels(buildingId: floor.buildingId, floorId: floor.floorId)),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.onTap, this.sub, this.selected = false});
  final IconData icon;
  final String label;
  final String? sub;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: selected ? FeColors.primary : FeArColors.manualBg,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 18, color: selected ? Colors.white : FeColors.ink),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.bodyMedium(label, weight: FontWeight.w600),
                    if (sub != null) AppText.caption(sub!, color: FeColors.ink2),
                  ],
                ),
              ),
              if (selected) const Icon(ArIcons.check, size: 18, color: FeColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- layers

class _LayersList extends ConsumerWidget {
  const _LayersList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(arSessionProvider);
    final ws = ref.watch(arWorkspaceProvider);
    final ctrl = ref.read(arWorkspaceProvider.notifier);
    final l = ws.layers;
    final floor = s.floor;
    final floors = floor == null ? null : ref.watch(arFloorsProvider(floor.buildingId)).valueOrNull;

    bool on(String lineage, String name) {
      final n = '$lineage $name'.toLowerCase();
      if (n.contains('struct')) return l.structure;
      if (n.contains('arch')) return l.architecture;
      return l.mep;
    }

    void toggle(String lineage, String name) {
      final n = '$lineage $name'.toLowerCase();
      if (n.contains('struct')) {
        ctrl.setLayers(l.copyWith(structure: !l.structure));
      } else if (n.contains('arch')) {
        ctrl.setLayers(l.copyWith(architecture: !l.architecture));
      } else {
        ctrl.setLayers(l.copyWith(mep: !l.mep));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ArEyebrow('ar.layers.models'.getString(context)),
        for (final b in floor?.builds ?? const [])
          _SwitchRow(label: b.modelName, sub: b.version == null ? null : 'v${b.version}', value: on(b.lineage, b.modelName), onChanged: (_) => toggle(b.lineage, b.modelName)),
        if (floor != null)
          TextButton.icon(
            onPressed: () => context.pushReplacement(Routes.arModels(buildingId: floor.buildingId, floorId: floor.floorId)),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), alignment: AlignmentDirectional.centerStart),
            icon: const Icon(ArIcons.plus, size: 16),
            label: AppText.label('ar.layers.add_model'.getString(context), color: FeColors.primary, weight: FontWeight.w700),
          ),
        // The legend's filters, as switches: one state, two controls. Walls
        // and Structure here are the same switches as the models above.
        if (ref.read(arWorkspaceProvider.notifier).disciplineCounts().isNotEmpty) ...[
          const SizedBox(height: 12),
          ArEyebrow('ar.legend.title'.getString(context)),
          const ArDisciplineSwitches(),
        ],
        const SizedBox(height: 12),
        ArEyebrow('ar.layers.show'.getString(context)),
        _SwitchRow(label: 'ar.layers.pipes'.getString(context), value: l.pipes, onChanged: (v) => ctrl.setLayers(l.copyWith(pipes: v))),
        _SwitchRow(label: 'ar.layers.ducts'.getString(context), value: l.ducts, onChanged: (v) => ctrl.setLayers(l.copyWith(ducts: v))),
        _SwitchRow(label: 'ar.layers.equipment'.getString(context), value: l.equipment, onChanged: (v) => ctrl.setLayers(l.copyWith(equipment: v))),
        _SwitchRow(label: 'ar.layers.trays'.getString(context), value: l.cableTrays, onChanged: (v) => ctrl.setLayers(l.copyWith(cableTrays: v))),
        const SizedBox(height: 12),
        ArEyebrow('ar.layers.phase'.getString(context)),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(label: 'ar.layers.phase_existing'.getString(context), selected: true),
            _Chip(label: 'ar.layers.phase_new'.getString(context), selected: true),
            _Chip(label: 'ar.layers.phase_demolition'.getString(context), selected: false),
          ],
        ),
        const SizedBox(height: 4),
        AppText.caption('ar.layers.phase_note'.getString(context), color: FeColors.ink2),
        const SizedBox(height: 12),
        ArEyebrow('ar.layers.colour_by'.getString(context)),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in ArColourBy.values)
              _Chip(
                label: 'ar.layers.colour.${c.name}'.getString(context),
                selected: l.colourBy == c,
                onTap: () {
                  ctrl.setLayers(l.copyWith(colourBy: c));
                  if (c == ArColourBy.progress) ctrl.loadProgress();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        ArEyebrow(arTr(context, 'ar.layers.opacity', ['${(l.opacity * 100).round()}'])),
        Slider(value: l.opacity, min: 0.1, max: 1, activeColor: FeColors.primary, onChanged: ctrl.setOpacity),
        if (floors != null && floors.isNotEmpty) ...[
          const SizedBox(height: 8),
          ArEyebrow('ar.layers.floors'.getString(context)),
          for (final f in floors)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: f.floorId == floor?.floorId
                  ? null
                  : () => context.pushReplacement(Routes.arModels(buildingId: floor!.buildingId, floorId: f.floorId)),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Icon(ArIcons.building, size: 16, color: f.floorId == floor?.floorId ? FeColors.primary : FeColors.ink2),
                    const SizedBox(width: 10),
                    Expanded(
                      child: AppText.bodyMedium(
                        f.name,
                        weight: f.floorId == floor?.floorId ? FontWeight.w800 : FontWeight.w500,
                        color: f.floorId == floor?.floorId ? FeColors.primary : FeColors.ink,
                      ),
                    ),
                    if (f.floorId == floor?.floorId) const Icon(ArIcons.check, size: 16, color: FeColors.primary),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.value, required this.onChanged, this.sub});
  final String label;
  final String? sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodyMedium(label, weight: FontWeight.w600),
                if (sub != null) AppText.caption(sub!, color: FeColors.ink2),
              ],
            ),
          ),
          Switch(value: value, activeThumbColor: FeColors.primary, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? FeColors.primary : FeArColors.manualBg,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: AppText.bodySmall(label, color: selected ? Colors.white : FeColors.ink, weight: FontWeight.w600),
        ),
      ),
    );
  }
}
