import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';

import 'app_text.dart';

/// Asks for a line of text (a note, a reason). Null = cancelled.
///
/// The dialog owns its controller: disposing it in the caller right after
/// `showDialog` returns crashed ("TextEditingController was used after being
/// disposed") because the closing animation still builds the field.
Future<String?> promptText(BuildContext context, {required String title, String? hint}) =>
    showDialog<String>(context: context, builder: (_) => _TextPrompt(title: title, hint: hint));

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({required this.title, this.hint});
  final String title;
  final String? hint;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: AppText.title(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 2000,
          decoration: InputDecoration(hintText: widget.hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: AppText('common.cancel'.getString(context))),
          TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: AppText('common.save'.getString(context))),
        ],
      );
}
