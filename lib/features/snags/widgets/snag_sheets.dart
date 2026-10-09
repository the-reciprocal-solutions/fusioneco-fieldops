import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/snag/snag_rules.dart';
import '../../../domain/snag.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/app_text.dart';
import '../../../widgets/common.dart';
import 'snag_visuals.dart';

Future<T?> _sheet<T>(BuildContext context, Widget child, {bool tall = false}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: FeColors.panel,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: tall
        ? SizedBox(height: MediaQuery.sizeOf(context).height * 0.82, child: child)
        : child,
  ),
);

class _Grabber extends StatelessWidget {
  const _Grabber();
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.only(top: 10, bottom: 12),
      width: 40,
      height: 4,
      decoration: BoxDecoration(color: FeColors.line, borderRadius: BorderRadius.circular(999)),
    ),
  );
}

// ---------------------------------------------------------------------------
// Room picker (floor › room)
// ---------------------------------------------------------------------------

class PickedRoom {
  const PickedRoom(this.floor, this.space);
  final SnagFloor floor;
  final SnagSpace? space;
}

/// Floor tabs across the top, rooms below, a search box that spans floors.
/// Swept rooms carry a tick (clear) or their snag count, so the surveyor sees
/// at a glance what is left on this floor.
Future<PickedRoom?> showRoomPicker(
  BuildContext context, {
  required SnagLocationTree tree,
  SnagSurvey? survey,
  String? initialFloorId,
  bool allowFloorOnly = false,
}) => _sheet<PickedRoom>(
  context,
  _RoomPicker(tree: tree, survey: survey, initialFloorId: initialFloorId, allowFloorOnly: allowFloorOnly),
  tall: true,
);

class _RoomPicker extends StatefulWidget {
  const _RoomPicker({required this.tree, this.survey, this.initialFloorId, required this.allowFloorOnly});
  final SnagLocationTree tree;
  final SnagSurvey? survey;
  final String? initialFloorId;
  final bool allowFloorOnly;

  @override
  State<_RoomPicker> createState() => _RoomPickerState();
}

class _RoomPickerState extends State<_RoomPicker> {
  late int _floor;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final i = widget.tree.floors.indexWhere((f) => f.id == widget.initialFloorId);
    _floor = i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final floors = widget.tree.floors;
    if (floors.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Grabber(),
          Padding(
            padding: const EdgeInsets.all(24),
            child: TechEmptyState(
              icon: LucideIcons.building2,
              title: 'snags.no_floors'.getString(context),
            ),
          ),
        ],
      );
    }
    final q = _query.trim().toLowerCase();
    final rooms = <(SnagFloor, SnagSpace)>[
      if (q.isEmpty)
        for (final s in floors[_floor].spaces) (floors[_floor], s)
      else
        for (final f in floors)
          for (final s in f.spaces)
            if (s.name.toLowerCase().contains(q) || (s.ref ?? '').toLowerCase().contains(q)) (f, s),
    ];
    return Column(
      children: [
        const _Grabber(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: AppText.titleMedium('snags.pick_room'.getString(context))),
              AppText.caption(widget.tree.name, color: FeColors.ink2),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'snags.search_rooms'.getString(context),
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              isDense: true,
              filled: true,
              fillColor: FeColors.page,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (q.isEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: floors.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final f = floors[i];
                final selected = i == _floor;
                final swept = widget.survey == null
                    ? 0
                    : f.spaces.where((s) => widget.survey!.sweepFor(s.id) != null).length;
                return ChoiceChip(
                  selected: selected,
                  onSelected: (_) => setState(() => _floor = i),
                  label: Text(
                    widget.survey == null ? f.name : '${f.name} · $swept/${f.spaces.length}',
                  ),
                  showCheckmark: false,
                  selectedColor: FeColors.primary,
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : FeColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (widget.allowFloorOnly && q.isEmpty)
          ListTile(
            leading: const Icon(LucideIcons.layers, color: FeColors.primary),
            title: AppText.bodyMedium(
              snagTr(context, 'snags.whole_floor', [floors[_floor].name]),
              weight: FontWeight.w700,
            ),
            onTap: () => Navigator.of(context).pop(PickedRoom(floors[_floor], null)),
          ),
        Expanded(
          child: rooms.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: AppText.bodySmall('snags.no_rooms'.getString(context), align: TextAlign.center),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                  itemCount: rooms.length,
                  itemBuilder: (context, i) {
                    final (f, s) = rooms[i];
                    final sweep = widget.survey?.sweepFor(s.id);
                    return ListTile(
                      leading: IconBadge(
                        icon: sweep == null
                            ? LucideIcons.doorClosed
                            : (sweep.clear ? LucideIcons.check : LucideIcons.triangleAlert),
                        style: FeBadgeStyleFor.of(
                          sweep == null ? FeColors.ink2 : (sweep.clear ? FeColors.success : FeColors.warning),
                        ),
                        size: 36,
                        iconSize: 16,
                      ),
                      title: AppText.bodyMedium(s.name, weight: FontWeight.w700),
                      subtitle: AppText.bodySmall(
                        [if (q.isNotEmpty) f.name, ?s.zone, ?s.ref].join(' · '),
                      ),
                      trailing: sweep == null
                          ? null
                          : AppText.caption(
                              sweep.clear
                                  ? 'snags.room_clear'.getString(context)
                                  : snagTr(context, 'snags.room_n_snags', [sweep.snagCount]),
                              color: sweep.clear ? FeColors.success : FeColors.warning,
                              weight: FontWeight.w700,
                            ),
                      onTap: () => Navigator.of(context).pop(PickedRoom(f, s)),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Soft badge colours from any hue (the kit's [FeAccents] only has fixed ones).
abstract final class FeBadgeStyleFor {
  static FeBadgeStyle of(Color hue) =>
      FeBadgeStyle(background: hue.withValues(alpha: 0.12), foreground: hue);
}

// ---------------------------------------------------------------------------
// Duplicate guard (UC-3)
// ---------------------------------------------------------------------------

// DuplicateChoice / DuplicateDecision live in core/snag/snag_rules.dart (pure,
// shared with SnagRepository.saveShot).

/// "Looks like this might already be raised." The inspector's photo sits
/// beside each candidate's, because a photo comparison is how people
/// actually decide. Dismissing the sheet counts as "Different".
Future<DuplicateDecision> showDuplicateSheet(
  BuildContext context, {
  required List<DuplicateCandidate> candidates,
  required Widget draftPhoto,
}) async {
  final r = await _sheet<DuplicateDecision>(
    context,
    _DuplicateSheet(candidates: candidates, draftPhoto: draftPhoto),
  );
  return r ?? const DuplicateDecision(DuplicateChoice.different);
}

class _DuplicateSheet extends StatelessWidget {
  const _DuplicateSheet({required this.candidates, required this.draftPhoto});
  final List<DuplicateCandidate> candidates;
  final Widget draftPhoto;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grabber(),
            Row(
              children: [
                const Icon(LucideIcons.copy, color: FeColors.warning, size: 20),
                const SizedBox(width: 8),
                Expanded(child: AppText.titleMedium('snags.dup_title'.getString(context))),
              ],
            ),
            const SizedBox(height: 4),
            AppText.bodySmall('snags.dup_subtitle'.getString(context)),
            const SizedBox(height: 14),
            for (final c in candidates) ...[
              TechCard(
                padding: const EdgeInsets.all(10),
                borderColor: FeColors.line,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: ClipRRect(borderRadius: BorderRadius.circular(12), child: draftPhoto),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(LucideIcons.equal, color: FeColors.ink2, size: 18),
                        ),
                        Expanded(
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: SnagPhoto(evidence: c.snag.coverPhoto, radius: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    AppText.titleSmall(c.snag.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    AppText.bodySmall(
                      [
                        c.snag.displayRef,
                        ?c.snag.locationLabel,
                        if (c.snag.raisedByName != null)
                          '${c.snag.raisedByName} · ${DateFormat.MMMd().format(c.snag.createdAt)}',
                      ].join(' · '),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final r in c.reasons)
                          TechChip(
                            label: 'snags.dup_reason.$r'.getString(context),
                            style: SnagVisuals.chip(FeColors.info),
                            uppercase: false,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // A snag the server has never seen can't take a "+1" yet.
                    if (!c.snag.localOnly)
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(DuplicateDecision(DuplicateChoice.sameIssue, c.snag)),
                        icon: const Icon(LucideIcons.plus, size: 16),
                        label: Text('snags.dup_same'.getString(context)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(const DuplicateDecision(DuplicateChoice.different)),
              child: Text('snags.dup_different'.getString(context)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reason picker (reject / reopen)
// ---------------------------------------------------------------------------

/// Reason chips plus an optional note. The chips are the common outcomes of
/// a re-inspection, so most rejections need no typing at all.
Future<String?> showReasonSheet(BuildContext context, {required String title}) =>
    _sheet<String>(context, _ReasonSheet(title: title));

class _ReasonSheet extends StatefulWidget {
  const _ReasonSheet({required this.title});
  final String title;
  @override
  State<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends State<_ReasonSheet> {
  static const _keys = ['not_fixed', 'partial', 'new_damage', 'poor_finish', 'wrong_location'];
  String? _chip;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String? get _reason {
    final parts = [
      if (_chip != null) 'snags.reason.$_chip'.getString(context),
      if (_note.text.trim().isNotEmpty) _note.text.trim(),
    ];
    return parts.isEmpty ? null : parts.join(' — ');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grabber(),
            AppText.titleMedium(widget.title),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in _keys)
                  ChoiceChip(
                    selected: _chip == k,
                    onSelected: (_) => setState(() => _chip = _chip == k ? null : k),
                    label: Text('snags.reason.$k'.getString(context)),
                    showCheckmark: false,
                    selectedColor: FeColors.danger,
                    labelStyle: TextStyle(
                      color: _chip == k ? Colors.white : FeColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'snags.reason_note_hint'.getString(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: FeColors.danger, minimumSize: const Size.fromHeight(48)),
              onPressed: _reason == null ? null : () => Navigator.of(context).pop(_reason),
              child: Text('snags.confirm'.getString(context)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Start a survey / walk
// ---------------------------------------------------------------------------

class SurveySetup {
  const SurveySetup(this.name, this.context);
  final String name;
  final SnagContext context;
}

Future<SurveySetup?> showStartSurveySheet(BuildContext context, {required String buildingName}) =>
    _sheet<SurveySetup>(context, _StartSurveySheet(buildingName: buildingName));

class _StartSurveySheet extends StatefulWidget {
  const _StartSurveySheet({required this.buildingName});
  final String buildingName;
  @override
  State<_StartSurveySheet> createState() => _StartSurveySheetState();
}

class _StartSurveySheetState extends State<_StartSurveySheet> {
  SnagContext _context = SnagContext.fmTakeover;
  late final TextEditingController _name;
  var _nameTouched = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_nameTouched) _name.text = _defaultName();
  }

  String _defaultName() =>
      '${widget.buildingName} · ${SnagVisuals.contextLabel(context, _context)} · ${DateFormat.MMMd().format(DateTime.now())}';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grabber(),
            AppText.titleMedium('snags.start_walk'.getString(context)),
            const SizedBox(height: 4),
            AppText.bodySmall('snags.start_walk_hint'.getString(context)),
            const SizedBox(height: 14),
            for (final c in SnagContext.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TechCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  tint: c == _context ? FeColors.infoSoft : null,
                  borderColor: c == _context ? FeColors.primary : FeColors.line,
                  onTap: () => setState(() {
                    _context = c;
                    if (!_nameTouched) _name.text = _defaultName();
                  }),
                  child: Row(
                    children: [
                      Icon(SnagVisuals.contextIcon(c), color: c == _context ? FeColors.primary : FeColors.ink2),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AppText.bodyMedium(SnagVisuals.contextLabel(context, c), weight: FontWeight.w700),
                            AppText.bodySmall('snags.context_hint.${c.wire}'.getString(context)),
                          ],
                        ),
                      ),
                      if (c == _context) const Icon(LucideIcons.circleCheck, color: FeColors.primary, size: 20),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
            TextField(
              controller: _name,
              onChanged: (_) => _nameTouched = true,
              decoration: InputDecoration(
                labelText: 'snags.survey_name'.getString(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: () {
                final name = _name.text.trim();
                Navigator.of(context).pop(SurveySetup(name.isEmpty ? _defaultName() : name, _context));
              },
              icon: const Icon(LucideIcons.camera, size: 18),
              label: Text('snags.start_walk'.getString(context)),
            ),
          ],
        ),
      ),
    );
  }
}
