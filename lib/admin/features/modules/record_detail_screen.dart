import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/media/photo_picker.dart';
import '../../core/network/api_exception.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/text_prompt.dart';
import 'module_spec.dart';

/// One record of a Phase 3 module: header, facts, light actions. Opened from
/// the list with the row as [initial]; fetches the fresh record when the spec
/// has a `detailPath` (and always after an action). Pops `true` when an
/// action changed something, so the list refreshes.
class RecordDetailScreen extends ConsumerStatefulWidget {
  const RecordDetailScreen({super.key, required this.spec, required this.recordId, this.initial});

  final ModuleSpec spec;
  final String recordId;
  final Json? initial;

  @override
  ConsumerState<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends ConsumerState<RecordDetailScreen> {
  Json? _record;
  Object? _error;
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _record = widget.initial;
    _reload();
  }

  Future<void> _reload() async {
    final path = widget.spec.list?.detailPath;
    if (path == null) return;
    try {
      final rec = recordOf(await ref.read(apiClientProvider).get(path(widget.recordId)));
      // Merged over the list row: some detail endpoints (energy summary) omit
      // the fields the row already shows, such as the name.
      if (mounted && rec.isNotEmpty) setState(() => (_record = {...?_record, ...rec}, _error = null));
    } catch (e) {
      // Keep showing the list row; only an empty screen shows the error.
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(RecordAction a) async {
    String? text;
    if (a.ask != TextAsk.none) {
      text = await _askText(a);
      if (text == null) return;
      if (a.ask == TextAsk.required && text.trim().isEmpty) return;
      if (text.trim().isEmpty) text = null;
    }
    if (!mounted) return;
    final photo = a.photoRun == null ? null : await ref.read(photoPickerProvider)(context);
    if (a.photoRun != null && photo == null) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final done = '${a.label}_done'.getString(context);
    try {
      final api = ref.read(apiClientProvider);
      if (photo != null) {
        await a.photoRun!(api, _record!, text, await api.uploadFile(photo.bytes, photo.name));
      } else {
        await a.run!(api, _record!, text);
      }
      _changed = true;
      messenger.showSnackBar(SnackBar(content: AppText(done)));
      if (widget.spec.list?.detailPath != null) {
        await _reload();
      } else if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askText(RecordAction a) =>
      promptText(context, title: a.label.getString(context), hint: (a.ask == TextAsk.required ? 'module.text_required' : 'module.text_optional').getString(context));

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    final ok = uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: AppText('module.open_failed'.getString(context))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rec = _record;
    final list = widget.spec.list;
    final row = rec == null || list == null ? null : list.row(rec);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: FeHeader(title: row?.ref ?? row?.title ?? ''),
        body: rec == null
            ? (_error == null
                  ? const TechSpinner()
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: TechEmptyState(icon: LucideIcons.circleAlert, title: 'module.load_error'.getString(context), subtitle: _error is ApiFailure ? (_error as ApiFailure).message : null),
                      ),
                    ))
            : _body(context, rec, row),
      ),
    );
  }

  Widget _body(BuildContext context, Json rec, RecordRow? row) {
    final facts = (widget.spec.facts?.call(rec) ?? const []).where((f) => f.$2 != null && f.$2!.isNotEmpty).toList();
    final actions = widget.spec.actions?.call(rec) ?? const <RecordAction>[];
    final url = widget.spec.open?.call(rec);

    // RowGroup brings its own 16px side inset; the header card and buttons
    // get the same inset so every card lines up (as on the alert detail).
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (row != null)
                TechCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (row.status != null) TechChip(label: chipLabel(row.status!), style: context.chips.status(row.status)),
                          if (row.status != null && row.priority != null) const SizedBox(width: 6),
                          if (row.priority != null) TechChip(label: chipLabel(row.priority!), style: context.chips.priority(row.priority)),
                        ],
                      ),
                      if (row.status != null || row.priority != null) const SizedBox(height: 12),
                      AppText.title(row.title),
                      if (row.subtitle != null) ...[const SizedBox(height: 4), AppText.bodyMedium(row.subtitle!)],
                    ],
                  ),
                ),
              if (actions.isNotEmpty || url != null) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (url != null) _ActionButton(label: 'act.open'.getString(context), icon: LucideIcons.externalLink, primary: true, onTap: _busy ? null : () => _openUrl(url)),
                    for (final a in actions) _ActionButton(label: a.label.getString(context), icon: a.icon, primary: a.primary, danger: a.danger, onTap: _busy ? null : () => _run(a)),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 16),
          RowGroup(
            label: 'module.details'.getString(context),
            dividerIndent: 16,
            rows: [for (final (label, value) in facts) ListTile(dense: true, title: AppText.caption(label.getString(context)), subtitle: AppText.body(value!))],
          ),
        ],
        ...?widget.spec.extra?.call(context, rec),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.icon, required this.onTap, this.primary = false, this.danger = false});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final child = Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 16), const SizedBox(width: 6), AppText(label)]);
    if (primary) return ElevatedButton(onPressed: onTap, child: child);
    return OutlinedButton(
      onPressed: onTap,
      style: danger
          ? OutlinedButton.styleFrom(
              foregroundColor: FeColors.danger,
              side: const BorderSide(color: FeColors.danger),
            )
          : null,
      child: child,
    );
  }
}
