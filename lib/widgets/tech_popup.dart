import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/fe_colors.dart';
import '../theme/theme_extensions.dart';
import 'app_text.dart';
import 'common.dart';

/// Every task-detail and checklist action (notes, photos, voice, checklist
/// toggles, session start/stop, close, invite responses) reports through this
/// one popup instead of each screen growing its own inline banner or a
/// SnackBar — a SnackBar's messenger belongs to the Scaffold underneath a
/// modal sheet, so its message renders behind the sheet and the technician
/// never sees it at all. It floats in the top-right corner over whatever is
/// on screen (rather than blocking it behind a dialog barrier) and clears
/// itself, so it reads like a normal notification banner. The Home
/// dashboard's own sync card is unrelated to this and keeps its current
/// inline treatment.
void showTechPopup(
  BuildContext context, {
  required String message,
  bool queued = false,
  bool isError = false,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _TechToast(
      message: message,
      queued: queued,
      isError: isError,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _TechToast extends StatefulWidget {
  const _TechToast({
    required this.message,
    required this.queued,
    required this.isError,
    required this.onDone,
  });

  final String message;
  final bool queued;
  final bool isError;
  final VoidCallback onDone;

  @override
  State<_TechToast> createState() => _TechToastState();
}

class _TechToastState extends State<_TechToast> {
  static const _autoDismiss = Duration(seconds: 4);
  static const _animation = Duration(milliseconds: 220);

  bool _visible = false;
  bool _dismissing = false;
  Timer? _timer;

  /// When the countdown is running, when it started — so a hold partway
  /// through can subtract what already elapsed instead of resuming a full
  /// [_autoDismiss] every time.
  DateTime? _startedAt;
  Duration _remaining = _autoDismiss;

  @override
  void initState() {
    super.initState();
    // Starts hidden and flips true one frame later so the AnimatedSlide /
    // AnimatedOpacity below actually animate in, instead of appearing
    // already at their end state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
    _schedule();
  }

  void _schedule() {
    _startedAt = DateTime.now();
    _timer = Timer(_remaining, _dismiss);
  }

  /// A finger on the toast pauses the countdown right where it is — reading
  /// it must not race its own disappearance.
  void _pause() {
    if (_timer == null) return;
    final elapsed = DateTime.now().difference(_startedAt!);
    _remaining -= elapsed;
    if (_remaining < Duration.zero) _remaining = Duration.zero;
    _timer?.cancel();
    _timer = null;
  }

  /// Lifting the finger resumes the normal countdown from whatever was left,
  /// rather than restarting the full duration or dismissing immediately.
  void _resume() {
    if (_timer != null || _dismissing) return;
    _schedule();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _timer?.cancel();
    if (!mounted) {
      widget.onDone();
      return;
    }
    setState(() => _visible = false);
    await Future.delayed(_animation);
    widget.onDone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tone = widget.isError ? FeColors.danger : FeColors.warning;
    final tint = widget.isError ? FeColors.dangerSoft : FeColors.warningSoft;
    final icon = widget.isError
        ? LucideIcons.triangleAlert
        : widget.queued
        ? LucideIcons.cloudUpload
        : LucideIcons.info;
    // Deliberately narrow — a corner notification, not a width-spanning
    // banner — with a floor so it still fits a very small screen.
    final maxWidth = MediaQuery.sizeOf(context).width - 24;
    final width = maxWidth > 240 ? 240.0 : maxWidth;

    return PositionedDirectional(
      top: MediaQuery.paddingOf(context).top + 8,
      end: 12,
      child: IgnorePointer(
        ignoring: _dismissing,
        child: AnimatedSlide(
          duration: _animation,
          curve: Curves.easeOut,
          offset: _visible ? Offset.zero : const Offset(0.15, -0.3),
          child: AnimatedOpacity(
            duration: _animation,
            opacity: _visible ? 1 : 0,
            child: GestureDetector(
              onTapDown: (_) => _pause(),
              onTapUp: (_) => _resume(),
              onTapCancel: _resume,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                child: TechCard(
                  radius: context.radii.card,
                  tint: tint,
                  borderColor: tone.withValues(alpha: 0.3),
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 18, color: tone),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AppText.bodySmall(widget.message, color: tone),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: _dismiss,
                        child: Icon(LucideIcons.x, size: 14, color: tone),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
