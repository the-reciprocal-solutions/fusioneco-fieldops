import '../../domain/capture.dart';

/// Pure rules for the start / end of day capture (selfie + position). No
/// database, no network, no clock reads, no plugins: unit-tested on their own
/// (test/capture_rules_test.dart).
///
/// Principle: the app NEVER stops a technician because evidence is weak. Weak
/// evidence (no GPS, far from the home site) is recorded and flagged by the
/// server for a supervisor. The only thing the app asks for is a short reason
/// when there is no position at all.

/// A short reason is asked for only when there is no position at all: the
/// supervisor then sees why ("Basement, no signal"). A stale or inaccurate
/// fix never asks for one.
bool reasonRequired(CaptureFix fix) => fix.kind == FixKind.none;

/// The quick-pick reasons shown when there is no position, as stable keys
/// (the labels are in the en/ar i18n files). `other` opens a text field.
const kNoFixReasonKeys = <String>['basement', 'gps_off', 'indoors', 'other'];

/// What is stored (and shown to supervisors on the web) for each quick pick,
/// always in English so the review screen reads the same whatever language the
/// technician's phone uses. `other` has no fixed text: the typed one is used.
const kNoFixReasonText = <String, String>{
  'basement': 'Basement or plant room, no signal',
  'gps_off': 'Location is switched off',
  'indoors': 'Indoors, GPS cannot see the sky',
};

/// The text burned into the corner of the start / end of day photo, so the
/// picture carries its own evidence when someone looks at it later. Pure.
List<String> stampLines({
  required bool isStart,
  required DateTime at,
  required String label,
  required CaptureFix fix,
}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final t = at.toLocal();
  final when = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  final where = fix.hasCoords
      ? '${fix.lat!.toStringAsFixed(5)}, ${fix.lng!.toStringAsFixed(5)}'
          '${fix.accuracyM != null ? ' (±${fix.accuracyM!.round()} m)' : ''}'
          '${fix.kind == FixKind.lastKnown ? ' last known' : ''}'
      : 'No GPS fix';
  return [
    '${isStart ? 'START OF DAY' : 'END OF DAY'}  $when',
    label,
    where,
  ];
}
