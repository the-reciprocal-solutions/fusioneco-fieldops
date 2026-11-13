import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../widgets/app_text.dart';

typedef PickedPhoto = ({Uint8List bytes, String name});

/// Asks camera or gallery, then returns the photo, or null when cancelled.
/// Overridden in tests (no platform channel there).
final photoPickerProvider = Provider<Future<PickedPhoto?> Function(BuildContext context)>((ref) => pickPhoto);

Future<PickedPhoto?> pickPhoto(BuildContext context, {double maxWidth = 1600}) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(leading: const Icon(LucideIcons.camera), title: AppText('photo.camera'.getString(ctx)), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
          ListTile(leading: const Icon(LucideIcons.image), title: AppText('photo.gallery'.getString(ctx)), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
        ],
      ),
    ),
  );
  if (source == null) return null;
  // Same size as FieldOps' snag photos: plenty for evidence, small to upload.
  final x = await ImagePicker().pickImage(source: source, maxWidth: maxWidth, maxHeight: maxWidth, imageQuality: 80);
  if (x == null) return null;
  return (bytes: await x.readAsBytes(), name: x.name);
}
