import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ocr/nameplate_ocr.dart';

void main() {
  group('nameplate field extraction', () {
    test('labelled fields on the same line as their value', () {
      final fields = extractNameplateFields('''
Acme Chillers Ltd
Model: XC-4000
S/N: 27673571
''');

      expect(fields.manufacturer, 'Acme Chillers Ltd');
      expect(fields.model, 'XC-4000');
      expect(fields.serial, '27673571');
    });

    test('a label sitting alone on its own line takes the next line as the value', () {
      final fields = extractNameplateFields('''
Acme Chillers Ltd
MODEL NO
XC-4000
SERIAL NUMBER
27673571
''');

      expect(fields.model, 'XC-4000');
      expect(fields.serial, '27673571');
    });

    test('with no explicit manufacturer label, the first line is the guess', () {
      final fields = extractNameplateFields('Acme Chillers Ltd\nModel: XC-4000');

      expect(fields.manufacturer, 'Acme Chillers Ltd');
    });

    test('an explicit manufacturer label overrides the first-line guess', () {
      final fields = extractNameplateFields('''
XC-4000 Series
Manufactured by: Acme Chillers Ltd
''');

      expect(fields.manufacturer, 'Acme Chillers Ltd');
    });

    test('different label spellings all resolve to the same field', () {
      expect(extractNameplateFields('Ser No: ABC1').serial, 'ABC1');
      expect(extractNameplateFields('SERIAL: ABC2').serial, 'ABC2');
      expect(extractNameplateFields('MDL: ABC3').model, 'ABC3');
      expect(extractNameplateFields('MFR: ABC4').manufacturer, 'ABC4');
    });

    test('blank OCR output leaves every field null', () {
      final fields = extractNameplateFields('');

      expect(fields.isEmpty, isTrue);
      expect(fields.manufacturer, isNull);
      expect(fields.model, isNull);
      expect(fields.serial, isNull);
    });

    test('a value is never guessed from a line that is itself another label', () {
      // "Serial Number" with nothing after it, immediately followed by
      // another label line rather than an actual value — must not borrow
      // "Model:" as the serial.
      final fields = extractNameplateFields('Serial Number\nModel: XC-4000');

      expect(fields.serial, isNull);
      expect(fields.model, 'XC-4000');
    });
  });

  group('two-column nameplate (label | value)', () {
    // How ML Kit actually returned a label-left/value-right plate on device:
    // the whole label column first, then the whole value column. Read as-is,
    // "SERIAL NO" sat alone and borrowed "VOLTAGE" as the serial.
    OcrLine line(String text, double left, double top) =>
        OcrLine(text, left: left, top: top, right: left + 150, bottom: top + 30);
    final columnOrder = [
      line('MANUFACTURER', 20, 10),
      line('MODEL', 20, 50),
      line('SERIAL NO', 20, 90),
      line('VOLTAGE', 20, 130),
      line('CARRIER', 220, 12),
      line('30XA-252', 220, 52),
      line('SNCHILLER228', 220, 88),
      line('400V 3PH 50HZ', 220, 131),
    ];

    test('rows are rebuilt left to right before parsing', () {
      expect(
        linesInReadingOrder(columnOrder),
        'MANUFACTURER CARRIER\nMODEL 30XA-252\nSERIAL NO SNCHILLER228\nVOLTAGE 400V 3PH 50HZ',
      );
    });

    test('each label gets the value beside it, not the label below it', () {
      final fields = extractNameplateFields(linesInReadingOrder(columnOrder));

      expect(fields.manufacturer, 'CARRIER');
      expect(fields.model, '30XA-252');
      expect(fields.serial, 'SNCHILLER228');
    });

    test('a stacked label-above-value plate still reads as separate rows', () {
      final stacked = [
        line('SERIAL NUMBER', 20, 10),
        line('27673571', 20, 50),
      ];

      expect(linesInReadingOrder(stacked), 'SERIAL NUMBER\n27673571');
      expect(extractNameplateFields(linesInReadingOrder(stacked)).serial, '27673571');
    });
  });
}
