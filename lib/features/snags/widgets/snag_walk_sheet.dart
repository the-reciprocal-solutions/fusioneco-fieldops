import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:record/record.dart';

import '../../../domain/snag.dart';
import '../../../domain/snag_ai.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/voice_waveform.dart';
import 'snag_visuals.dart';

/// Walk mode's details sheet (redesign 2026-10-06, owner iPhone test: "the
/// start walk option is overwhelming … the UI is fully blocked with no frame
/// displayed"). The old compose card stacked every control over the photo.
/// Now the photo keeps the screen and the details live in a draggable bottom
/// sheet with three resting heights:
///
/// - **peek** — handle, the AI line and Save & next: drag down to see the
///   whole frame (the photo is laid out above this height, so nothing of it
///   is hidden at peek). Discard is the ✕ in the top bar;
/// - **collapsed** (where it opens) — plus trade and severity, the two fields
///   every snag needs;
/// - **full** — "More details": issue type, title, mark-up, voice note.
///
/// Save & next is pinned to the sheet's foot at every height, so the quick
/// "shoot → trade → severity → save" loop never needs a drag.
@immutable
class SnagWalkSheetSizes {
  const SnagWalkSheetSizes({required this.peek, required this.collapsed, required this.max});

  /// Fractions of the available height.
  final double peek;
  final double collapsed;
  final double max;

  /// Heights in logical pixels the sheet needs at each resting point.
  static const peekPx = 156.0;
  static const collapsedPx = 312.0;

  /// Pure, so a 320×568 iPhone SE with the keyboard up (≈ 300 pt left) is
  /// unit-tested: sizes always satisfy peek < collapsed < max ≤ 1, as
  /// [DraggableScrollableSheet] asserts.
  factory SnagWalkSheetSizes.forHeight(double height) {
    final h = height <= 0 ? 1.0 : height;
    const max = 0.94;
    final peek = (peekPx / h).clamp(0.12, 0.6).toDouble();
    final collapsed = (collapsedPx / h).clamp(peek + 0.04, max - 0.02).toDouble();
    return SnagWalkSheetSizes(peek: peek, collapsed: collapsed, max: max);
  }

  List<double> get snaps => [peek, collapsed, max];
}

class SnagWalkComposeSheet extends StatefulWidget {
  const SnagWalkComposeSheet({
    super.key,
    required this.sizes,
    required this.controller,
    required this.aiRunning,
    required this.ai,
    required this.onApplyAllAi,
    required this.onRetryAi,
    required this.trade,
    required this.tradeOrder,
    required this.onTrade,
    required this.priority,
    required this.onPriority,
    required this.issueType,
    required this.onIssueType,
    required this.title,
    required this.saving,
    required this.onSave,
    required this.onMarkUp,
    required this.onVoice,
    required this.onSuggest,
    this.description,
    this.recording = false,
    this.voiceAdded = false,
    this.amplitude,
    this.suggesting = false,
    this.suggested = false,
    this.transcript,
  });

  final SnagWalkSheetSizes sizes;
  final DraggableScrollableController controller;

  final bool aiRunning;
  final SnagAiResult? ai;
  final VoidCallback onApplyAllAi;
  final VoidCallback onRetryAi;

  final String trade;
  final List<String> tradeOrder;
  final ValueChanged<String> onTrade;
  final SnagPriority priority;
  final ValueChanged<SnagPriority> onPriority;
  final String issueType;
  final ValueChanged<String> onIssueType;
  final TextEditingController title;
  final String? description;

  final bool saving;
  final VoidCallback onSave;

  final VoidCallback onMarkUp;
  final VoidCallback onVoice;
  final VoidCallback onSuggest;
  final bool recording;
  final bool voiceAdded;
  final Stream<Amplitude>? amplitude;
  final bool suggesting;
  final bool suggested;
  final String? transcript;

  @override
  State<SnagWalkComposeSheet> createState() => _SnagWalkComposeSheetState();
}

class _SnagWalkComposeSheetState extends State<SnagWalkComposeSheet> {
  var _more = false;
  final _titleFocus = FocusNode();

  // DraggableScrollableSheet compares snapSizes by identity and re-snaps
  // whenever the list instance changes — i.e. on every parent setState
  // (each chip tap) if a fresh literal were passed. One list per size.
  List<double>? _snaps;
  List<double> _snapSizesFor(double collapsed) {
    final cached = _snaps;
    if (cached != null && cached.single == collapsed) return cached;
    return _snaps = List.unmodifiable([collapsed]);
  }

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      // Typing a title: give the sheet the room, so the field stays above
      // the keyboard on a small phone.
      if (_titleFocus.hasFocus) _goTo(widget.sizes.max);
    });
  }

  @override
  void dispose() {
    _titleFocus.dispose();
    super.dispose();
  }

  void _goTo(double size) {
    if (!widget.controller.isAttached) return;
    widget.controller.animateTo(size, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
  }

  void _toggleMore() {
    setState(() => _more = !_more);
    if (_more) _goTo(widget.sizes.max);
  }

  @override
  Widget build(BuildContext context) {
    final sizes = widget.sizes;
    final ai = widget.ai;
    return DraggableScrollableSheet(
      controller: widget.controller,
      initialChildSize: sizes.collapsed,
      minChildSize: sizes.peek,
      maxChildSize: sizes.max,
      snap: true,
      snapSizes: _snapSizesFor(sizes.collapsed),
      builder: (context, scroll) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: FeColors.ink.withValues(alpha: 0.96),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: const Border(top: BorderSide(color: Colors.white12)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16)],
          ),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  children: [
                    _Handle(onTap: () => _goTo(
                      (widget.controller.isAttached ? widget.controller.size : sizes.collapsed) > sizes.peek + 0.01
                          ? sizes.peek
                          : sizes.collapsed,
                    )),
                    // Only once the technician asked for a photo check (2026-10-10).
                    if (widget.aiRunning || ai != null) ...[
                      SnagWalkAiStrip(
                        running: widget.aiRunning,
                        result: ai,
                        onApplyAll: widget.onApplyAllAi,
                        onRetry: widget.onRetryAi,
                      ),
                      const SizedBox(height: 10),
                    ],
                    TradeChipRail(
                      value: widget.trade,
                      dark: true,
                      suggested: ai?.trade,
                      ordered: widget.tradeOrder,
                      onChanged: widget.onTrade,
                    ),
                    const SizedBox(height: 8),
                    SeveritySelector(
                      value: widget.priority,
                      dark: true,
                      suggested: ai?.priority,
                      onChanged: widget.onPriority,
                    ),
                    if (_more) ...[const SizedBox(height: 12), ..._details(context)],
                  ],
                ),
              ),
              _Footer(saving: widget.saving, onSave: widget.onSave, more: _more, onMore: _toggleMore),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _details(BuildContext context) => [
    SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: kSnagIssueTypes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final t = kSnagIssueTypes[i];
          final sel = t == widget.issueType;
          return GestureDetector(
            onTap: () => widget.onIssueType(t),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sel ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    SnagVisuals.issueLabel(context, t),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? FeColors.ink : Colors.white),
                  ),
                  if (t == widget.ai?.issueType) ...[
                    const SizedBox(width: 4),
                    Icon(LucideIcons.sparkles, size: 11, color: sel ? FeColors.ai : FeColors.aiLine),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
    const SizedBox(height: 10),
    TextField(
      controller: widget.title,
      focusNode: _titleFocus,
      style: const TextStyle(color: Colors.white),
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        hintText: 'snags.title_hint'.getString(context),
        hintStyle: const TextStyle(color: Colors.white54),
        isDense: true,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    ),
    if (widget.description != null) ...[
      const SizedBox(height: 6),
      Text(widget.description!, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
    ],
    const SizedBox(height: 10),
    Row(
      children: [
        _ToolButton(icon: LucideIcons.pencilLine, label: 'snags.mark_up'.getString(context), onTap: widget.onMarkUp),
        const SizedBox(width: 8),
        _ToolButton(
          icon: widget.recording ? LucideIcons.square : LucideIcons.mic,
          label: widget.recording
              ? 'snags.stop'.getString(context)
              : (widget.voiceAdded ? 'snags.voice_added'.getString(context) : 'snags.voice'.getString(context)),
          active: widget.recording || widget.voiceAdded,
          danger: widget.recording,
          onTap: widget.onVoice,
        ),
        const SizedBox(width: 8),
        _ToolButton(
          icon: LucideIcons.sparkles,
          label: 'snags.suggest'.getString(context),
          busy: widget.suggesting,
          active: widget.suggested,
          onTap: widget.onSuggest,
        ),
      ],
    ),
    if (widget.recording && widget.amplitude != null) ...[
      const SizedBox(height: 8),
      SizedBox(height: 28, child: VoiceWaveform(amplitudeStream: widget.amplitude!, color: FeColors.danger)),
    ],
    if (widget.transcript != null) ...[
      const SizedBox(height: 8),
      Text('“${widget.transcript}”', style: const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic)),
    ],
  ];
}

class _Handle extends StatelessWidget {
  const _Handle({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'snags.walk.drag_hint'.getString(context),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 22,
        child: Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2)),
          ),
        ),
      ),
    ),
  );
}

/// Pinned at every sheet height: "More details" (progressive disclosure,
/// always reachable — on an SE the list itself can be scrolled past it) and
/// Save & next. Discard is the ✕ in the top bar (and the back gesture).
class _Footer extends StatelessWidget {
  const _Footer({required this.saving, required this.onSave, required this.more, required this.onMore});
  final bool saving;
  final VoidCallback onSave;
  final bool more;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 12, 10),
    child: Row(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 128),
          child: TextButton.icon(
            key: const ValueKey('snag-walk-more'),
            onPressed: onMore,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(48, 50),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: Icon(more ? LucideIcons.chevronDown : LucideIcons.slidersHorizontal, size: 16),
            label: Text(
              (more ? 'snags.walk.less' : 'snags.walk.more').getString(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: FilledButton.icon(
            key: const ValueKey('snag-walk-save'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: FeColors.primaryLight,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: saving ? null : onSave,
            icon: saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(LucideIcons.check, size: 18),
            label: Text(
              'snags.save_next'.getString(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    ),
    ),
  );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.danger = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = danger ? FeColors.danger : (active ? FeColors.primaryLight : Colors.white);
    return Expanded(
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: color))
              else
                Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The walk's photo-check strip, shown only after the technician tapped
/// "Check photo" (2026-10-10 — photo analysis is optional, not the headline):
/// a quiet line while it looks, then the proposal in one line with "Apply
/// all", photo tips and a "maybe already raised" hint. Violet is the app's
/// AI-only accent. Never blocks Save & next.
class SnagWalkAiStrip extends StatelessWidget {
  const SnagWalkAiStrip({
    super.key,
    required this.running,
    required this.result,
    required this.onApplyAll,
    required this.onRetry,
  });

  final bool running;
  final SnagAiResult? result;
  final VoidCallback onApplyAll;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final ok = !running && r != null && r.status == SnagAiStatus.ok;
    final summary = !ok
        ? null
        : [
            if (r.trade != null) SnagVisuals.tradeLabel(context, r.trade!),
            if (r.priority != null) SnagVisuals.priorityLabel(context, r.priority!),
            ?r.title,
          ].join(' · ');
    final String line;
    if (running || r == null) {
      line = 'snags.ai.step_photo'.getString(context);
    } else if (r.status == SnagAiStatus.offline) {
      line = 'snags.ai.offline'.getString(context);
    } else if (r.status == SnagAiStatus.unavailable) {
      line = 'snags.ai.unavailable'.getString(context);
    } else {
      line = summary == null || summary.isEmpty ? 'snags.ai.nothing'.getString(context) : summary;
    }
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 6, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: FeColors.aiLine.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(9)),
                child: running
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(LucideIcons.sparkles, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'snags.ai.photo_title'.getString(context),
                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                    ),
                    Text(
                      line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              if (ok && r.hasSuggestions)
                FilledButton(
                  key: const ValueKey('snag-walk-apply-all'),
                  onPressed: onApplyAll,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: FeColors.ai,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: Text('snags.ai.apply_all'.getString(context), style: const TextStyle(fontWeight: FontWeight.w800)),
                )
              else if (!running && r != null)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
                  child: Text('snags.ai.retry'.getString(context)),
                ),
            ],
          ),
          if (!running && r != null)
            for (final t in r.captureTips)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(LucideIcons.lightbulb, size: 12, color: FeColors.warningSoft),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text('snags.ai.tip.$t'.getString(context), style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                    ),
                  ],
                ),
              ),
          if (!running && r != null && r.duplicates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                snagTr(context, 'snags.ai.dupe_hint', [r.duplicates.first.displayRef]),
                style: const TextStyle(color: Colors.white70, fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }
}
