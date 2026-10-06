import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// App-wide "tap outside the text field closes the keyboard" (owner,
/// 2026-10-06: "globally, closing the keyboard by tapping outside it should be
/// the default behaviour"). Mounted once in `MaterialApp.builder`.
///
/// How: Flutter already detects a tap outside a focused field
/// (`TextFieldTapRegion`) and asks the nearest [Actions] what to do through
/// [EditableTextTapOutsideIntent] / [EditableTextTapUpOutsideIntent]; on
/// phones the stock answer is "nothing". This overrides both, so:
///
/// - the selection toolbar, handles and magnifier are part of the field's tap
///   region — selecting text never closes the keyboard;
/// - it acts on tap *up*, and only for a tap (moved less than [kTouchSlop]):
///   a scroll never closes it here (scroll views do that on drag —
///   [ScrollViewKeyboardDismissBehavior.onDrag], set app-wide in app.dart);
/// - a tap that lands on a control (a button, a chip, a list row, another
///   field) is left alone: the control still gets its tap and decides —
///   the conversation composer's send button keeps the keyboard up so you
///   can keep typing, its "hide keyboard" button closes it. Only taps on
///   blank space close the keyboard.
///
/// A field with its own `onTapOutside` / `onTapUpOutside` keeps its own
/// behaviour (Flutter calls those instead of the intents).
class KeyboardDismissOnTapOutside extends StatefulWidget {
  const KeyboardDismissOnTapOutside({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardDismissOnTapOutside> createState() => _KeyboardDismissOnTapOutsideState();
}

class _KeyboardDismissOnTapOutsideState extends State<KeyboardDismissOnTapOutside> {
  PointerDownEvent? _down;
  FocusNode? _node;

  Object? _onDown(EditableTextTapOutsideIntent intent) {
    _down = intent.pointerDownEvent;
    _node = intent.focusNode;
    return null;
  }

  Object? _onUp(EditableTextTapUpOutsideIntent intent) {
    final down = _down;
    final node = _node;
    _down = null;
    _node = null;
    if (down == null || node == null || node != intent.focusNode || !node.hasFocus) return null;
    final up = intent.pointerUpEvent;
    if ((up.position - down.position).distance > kTouchSlop) return null;
    if (hitsTapTarget(up.position, viewId: up.viewId)) return null;
    node.unfocus();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        EditableTextTapOutsideIntent: CallbackAction<EditableTextTapOutsideIntent>(onInvoke: _onDown),
        EditableTextTapUpOutsideIntent: CallbackAction<EditableTextTapUpOutsideIntent>(onInvoke: _onUp),
      },
      child: widget.child,
    );
  }
}

/// Whether [position] lands on something that handles a tap itself — a
/// button, chip, list row (`GestureDetector`/`InkWell` with `onTap`) or a
/// text field. Read from the render tree's tap semantics, which every
/// tappable Material/Widgets control carries; a scroll view's own gesture
/// handler has no `onTap`, so blank space inside a list still counts as
/// blank.
bool hitsTapTarget(Offset position, {int viewId = 0}) {
  final result = HitTestResult();
  try {
    WidgetsBinding.instance.hitTestInView(result, position, viewId);
  } catch (_) {
    return false;
  }
  for (final entry in result.path) {
    final target = entry.target;
    // GestureDetector / RawGestureDetector with an onTap.
    if (target is RenderSemanticsGestureHandler && target.onTap != null) return true;
    // InkWell (every Material button, chip, ListTile) announces its tap
    // through a Semantics(onTap:) and keeps its GestureDetector out of
    // semantics; buttons also carry `button: true`.
    if (target is SemanticsAnnotationsMixin &&
        (target.properties.onTap != null || target.properties.button == true)) {
      return true;
    }
    if (target is RenderEditable) return true;
  }
  return false;
}
