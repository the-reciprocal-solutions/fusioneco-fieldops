import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/widgets/keyboard_dismiss.dart';

/// Owner, 2026-10-06: tapping outside a text field closes the keyboard,
/// app-wide. Buttons, text selection and the chat composer must keep working.
void main() {
  late int pressed;
  late FocusNode node;

  Future<void> pump(WidgetTester tester, {Widget? extra}) async {
    pressed = 0;
    node = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        ),
        builder: (context, child) => KeyboardDismissOnTapOutside(child: child!),
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 40),
              TextField(key: const ValueKey('field'), focusNode: node),
              const SizedBox(height: 200, key: ValueKey('blank')),
              ElevatedButton(onPressed: () => pressed++, child: const Text('Send')),
              ?extra,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> focusField(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pump();
    expect(node.hasFocus, isTrue);
  }

  testWidgets('a tap on blank space closes the keyboard', (tester) async {
    await pump(tester);
    await focusField(tester);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('blank'))));
    await tester.pump();
    expect(node.hasFocus, isFalse);
  });

  testWidgets('a button still gets its tap and the keyboard stays (composer send)', (tester) async {
    await pump(tester);
    await focusField(tester);
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(pressed, 1);
    expect(node.hasFocus, isTrue);
  });

  testWidgets('a drag on blank space is not a tap', (tester) async {
    await pump(tester);
    await focusField(tester);
    await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('blank'))), const Offset(0, 80));
    await tester.pump();
    expect(node.hasFocus, isTrue);
  });

  testWidgets('tapping inside the field (placing the cursor) keeps it open', (tester) async {
    await pump(tester);
    await focusField(tester);
    await tester.enterText(find.byKey(const ValueKey('field')), 'hello world');
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(node.hasFocus, isTrue);
  });

  testWidgets('another field takes focus instead of just closing', (tester) async {
    final other = FocusNode();
    await pump(tester, extra: TextField(key: const ValueKey('other'), focusNode: other));
    await focusField(tester);
    await tester.tap(find.byKey(const ValueKey('other')));
    await tester.pump();
    expect(other.hasFocus, isTrue);
  });

  testWidgets('dragging a list closes the keyboard (onDrag, app-wide)', (tester) async {
    final listNode = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        ),
        builder: (context, child) => KeyboardDismissOnTapOutside(child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              TextField(key: const ValueKey('lf'), focusNode: listNode),
              for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('row $i')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('lf')));
    await tester.pump();
    expect(listNode.hasFocus, isTrue);
    await tester.drag(find.text('row 3'), const Offset(0, -200));
    await tester.pump();
    expect(listNode.hasFocus, isFalse);
  });
}
