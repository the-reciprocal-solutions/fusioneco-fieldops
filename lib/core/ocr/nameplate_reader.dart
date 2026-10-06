import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'nameplate_ocr.dart';

/// Runs on-device text recognition against a captured nameplate photo. The
/// heavy lifting — deciding what counts as manufacturer/model/serial — lives
/// in the testable [extractNameplateFields]; this class is just the camera
/// photo → recognized text plumbing.
class NameplateReader {
  final _recognizer = TextRecognizer();

  Future<NameplateFields> read(String imagePath) async {
    final input = InputImage.fromFilePath(imagePath);
    final recognized = await _recognizer.processImage(input);
    final lines = [
      for (final block in recognized.blocks)
        for (final line in block.lines)
          OcrLine(
            line.text,
            left: line.boundingBox.left,
            top: line.boundingBox.top,
            right: line.boundingBox.right,
            bottom: line.boundingBox.bottom,
          ),
    ];
    return extractNameplateFields(linesInReadingOrder(lines));
  }

  void dispose() => _recognizer.close();
}
