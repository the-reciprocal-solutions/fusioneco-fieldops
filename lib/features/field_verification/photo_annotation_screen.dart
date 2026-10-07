import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:image/image.dart' as img;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/capture/capture_services.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/fe_header.dart';

enum _Tool { freehand, circle, arrow }

class _Stroke {
  _Stroke(this.tool, this.color);
  final _Tool tool;
  final Color color;
  final List<Offset> points = [];
}

/// FR-3.5 — the annotated photo at the PHOTO's resolution, as JPEG.
///
/// Marks are drawn on a view [drawnAt] pixels wide; they are replayed onto
/// the full-size [photo] through one canvas scale, so each lands where it was
/// drawn and keeps its size relative to the photo. This replaced capturing
/// the on-screen view, which saved a ~720px PNG of a 1600px capture under its
/// `.jpg` name — evidence quietly downgraded and mislabelled.
Future<Uint8List> flattenAnnotatedPhoto(
  ui.Image photo,
  Size drawnAt,
  void Function(Canvas canvas, Size drawnAt) paintMarks,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawImage(photo, Offset.zero, Paint());
  canvas.scale(photo.width / drawnAt.width, photo.height / drawnAt.height);
  paintMarks(canvas, drawnAt);
  final flat = await recorder.endRecording().toImage(photo.width, photo.height);
  final rgba = await flat.toByteData(format: ui.ImageByteFormat.rawRgba);
  final pixels = img.Image.fromBytes(
    width: flat.width,
    height: flat.height,
    bytes: rgba!.buffer,
    numChannels: 4,
  );
  // Same quality as every other capture path (`downscaleJpeg`).
  return Uint8List.fromList(img.encodeJpg(pixels, quality: 80));
}

/// The annotated photo is always JPEG, so its name must say so — the upload's
/// content type is read from the extension.
String annotatedFileName(String original) {
  final dot = original.lastIndexOf('.');
  final base = dot > 0 ? original.substring(0, dot) : original;
  return '$base.jpg';
}

/// FR-3.5 — draw an arrow, circle, or freehand mark over a captured photo
/// before it's queued: "the crack is here" survives as a mark on the photo
/// itself, worth more than a sentence in the notes field.
///
/// Renders the photo at its exact aspect ratio (decoded via
/// `instantiateImageCodec`, the same approach FR-2.8's floor plan viewer
/// uses) so the drawing surface has no letterboxed dead zone — every pixel
/// the technician can draw on is a pixel of the photo. Saving replays the
/// same strokes onto the full-size photo ([flattenAnnotatedPhoto]).
class PhotoAnnotationScreen extends StatefulWidget {
  const PhotoAnnotationScreen({super.key, required this.photo});

  final CapturedPhoto photo;

  @override
  State<PhotoAnnotationScreen> createState() => _PhotoAnnotationScreenState();
}

class _PhotoAnnotationScreenState extends State<PhotoAnnotationScreen> {
  static const _palette = [
    Color(0xFFFF3B30), // red
    Color(0xFFFFCC00), // yellow
    Color(0xFFFFFFFF), // white
  ];

  final _boundaryKey = GlobalKey();
  final _strokes = <_Stroke>[];
  _Tool _tool = _Tool.freehand;
  Color _color = _palette.first;
  ui.Image? _decoded;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.photo.bytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _decoded = frame.image);
  }

  void _onPanStart(DragStartDetails d) {
    setState(() => _strokes.add(_Stroke(_tool, _color)..points.add(d.localPosition)));
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final stroke = _strokes.last;
    setState(() {
      if (stroke.tool == _Tool.freehand) {
        stroke.points.add(d.localPosition);
      } else if (stroke.points.length < 2) {
        stroke.points.add(d.localPosition);
      } else {
        stroke.points[1] = d.localPosition;
      }
    });
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final drawnAt = (_boundaryKey.currentContext!.findRenderObject() as RenderBox).size;
      final bytes = await flattenAnnotatedPhoto(
        _decoded!,
        drawnAt,
        (canvas, size) => _AnnotationPainter(_strokes).paint(canvas, size),
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        CapturedPhoto(bytes: bytes, fileName: annotatedFileName(widget.photo.fileName)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decoded;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: FeHeader(
        variant: FeHeaderVariant.immersive,
        title: 'fieldVerify.annotate_title'.getString(context),
        actions: [
          IconButton(
            onPressed: _strokes.isEmpty ? null : _undo,
            icon: Icon(
              LucideIcons.undo2,
              color: _strokes.isEmpty ? Colors.white38 : Colors.white,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: decoded == null || _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : AppText.label(
                      'fieldVerify.done'.getString(context),
                      color: Colors.white,
                      weight: FontWeight.w700,
                    ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: decoded == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : AspectRatio(
                        aspectRatio: decoded.width / decoded.height,
                        child: RepaintBoundary(
                          key: _boundaryKey,
                          child: GestureDetector(
                            onPanStart: _onPanStart,
                            onPanUpdate: _onPanUpdate,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.memory(widget.photo.bytes, fit: BoxFit.fill),
                                CustomPaint(painter: _AnnotationPainter(_strokes)),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            _Toolbar(
              tool: _tool,
              color: _color,
              palette: _palette,
              onToolChanged: (t) => setState(() => _tool = t),
              onColorChanged: (c) => setState(() => _color = c),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter(this.strokes);
  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      switch (stroke.tool) {
        case _Tool.freehand:
          if (stroke.points.length < 2) continue;
          final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
          for (final p in stroke.points.skip(1)) {
            path.lineTo(p.dx, p.dy);
          }
          canvas.drawPath(path, paint);
        case _Tool.circle:
          if (stroke.points.length < 2) continue;
          canvas.drawOval(Rect.fromPoints(stroke.points[0], stroke.points[1]), paint);
        case _Tool.arrow:
          if (stroke.points.length < 2) continue;
          _drawArrow(canvas, paint, stroke.points[0], stroke.points[1]);
      }
    }
  }

  void _drawArrow(Canvas canvas, Paint paint, Offset start, Offset end) {
    canvas.drawLine(start, end, paint);
    final angle = (end - start).direction;
    const headLength = 20.0;
    const headAngle = 0.5;
    final p1 = end -
        Offset(headLength * math.cos(angle - headAngle), headLength * math.sin(angle - headAngle));
    final p2 = end -
        Offset(headLength * math.cos(angle + headAngle), headLength * math.sin(angle + headAngle));
    canvas.drawLine(end, p1, paint);
    canvas.drawLine(end, p2, paint);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => true;
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.tool,
    required this.color,
    required this.palette,
    required this.onToolChanged,
    required this.onColorChanged,
  });

  final _Tool tool;
  final Color color;
  final List<Color> palette;
  final ValueChanged<_Tool> onToolChanged;
  final ValueChanged<Color> onColorChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              _ToolButton(
                icon: LucideIcons.pencil,
                selected: tool == _Tool.freehand,
                onTap: () => onToolChanged(_Tool.freehand),
              ),
              const SizedBox(width: 10),
              _ToolButton(
                icon: LucideIcons.circle,
                selected: tool == _Tool.circle,
                onTap: () => onToolChanged(_Tool.circle),
              ),
              const SizedBox(width: 10),
              _ToolButton(
                icon: LucideIcons.arrowUpRight,
                selected: tool == _Tool.arrow,
                onTap: () => onToolChanged(_Tool.arrow),
              ),
            ],
          ),
          Row(
            children: [
              for (final c in palette) ...[
                _ColorSwatch(color: c, selected: c == color, onTap: () => onColorChanged(c)),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.selected, required this.onTap});

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? FeColors.primary : Colors.white12,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 3 : 1),
        ),
      ),
    );
  }
}
