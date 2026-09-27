/// The AR context a workspace hand-off carries into the field-verification
/// form and the snag form (PENDING P-006, docs/ar-bim-overlay.md §8).
///
/// Only strings cross the router (CLAUDE.md), so it travels as `ar*` query
/// parameters ([toQuery] / [fromQuery]) and becomes the `arContext` JSON
/// block of §8 on submit ([toArContext]). Pure, so the round trip is tested
/// (test/ar_handoff_test.dart).
///
/// The server stores unknown body keys nowhere today (the verify endpoint
/// ignores them), so `arContext` is sent now and kept by the server once
/// AR-24 lands there; the AR photo also rides as an ordinary verification or
/// snag photo, which is stored today.
class ArHandoff {
  const ArHandoff({
    this.check = 'unchecked',
    this.offsetM,
    this.toleranceM,
    this.tagMatches,
    this.buildId,
    this.globalId,
    this.featureId,
    this.elementName,
    this.fitMethod,
    this.maxResidualMm,
    this.quality,
    this.mappingConfirmed,
    this.photoPath,
    this.cameraTile,
    this.cameraDirTile,
  });

  /// `consistent | offset | unchecked` (Verify's location check).
  final String check;
  final double? offsetM;
  final double? toleranceM;
  final bool? tagMatches;
  final String? buildId;
  final String? globalId;
  final int? featureId;

  /// What the model calls the element ("CHW supply 150"), for the form.
  final String? elementName;

  /// `positions | corners | …` (AlignmentFit.method).
  final String? fitMethod;
  final int? maxResidualMm;

  /// `none | placed | locked | …` (AlignmentQuality.name).
  final String? quality;
  final bool? mappingConfirmed;

  /// The AR capture (camera + model) on this phone.
  final String? photoPath;

  /// Where the camera stood and looked, in the tile frame (an AR viewpoint,
  /// §8's BCF note).
  final List<double>? cameraTile;
  final List<double>? cameraDirTile;

  bool get hasContext => globalId != null || photoPath != null || quality != null;

  bool get measured => offsetM != null;

  static const _p = 'ar';

  Map<String, String> toQuery() => {
    '${_p}Check': check,
    if (offsetM != null) '${_p}OffsetM': offsetM!.toStringAsFixed(2),
    if (toleranceM != null) '${_p}ToleranceM': toleranceM!.toStringAsFixed(2),
    if (tagMatches != null) '${_p}TagMatches': tagMatches! ? '1' : '0',
    '${_p}BuildId': ?buildId,
    '${_p}GlobalId': ?globalId,
    if (featureId != null) '${_p}FeatureId': '$featureId',
    '${_p}Element': ?elementName,
    '${_p}FitMethod': ?fitMethod,
    if (maxResidualMm != null) '${_p}MaxResidualMm': '$maxResidualMm',
    '${_p}Quality': ?quality,
    if (mappingConfirmed != null) '${_p}Mapping': mappingConfirmed! ? '1' : '0',
    '${_p}Photo': ?photoPath,
    if (cameraTile != null) '${_p}Cam': _vec(cameraTile!),
    if (cameraDirTile != null) '${_p}CamDir': _vec(cameraDirTile!),
  };

  /// Null when the route carries no AR context at all (the form was opened
  /// from a scan, a route pack, …).
  static ArHandoff? fromQuery(Map<String, String> q) {
    String? s(String k) {
      final v = q['$_p$k']?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    bool? flag(String k) => switch (s(k)) {
      '1' || 'true' => true,
      '0' || 'false' => false,
      _ => null,
    };
    final h = ArHandoff(
      check: s('Check') ?? 'unchecked',
      offsetM: double.tryParse(s('OffsetM') ?? ''),
      toleranceM: double.tryParse(s('ToleranceM') ?? ''),
      tagMatches: flag('TagMatches'),
      buildId: s('BuildId'),
      globalId: s('GlobalId'),
      featureId: int.tryParse(s('FeatureId') ?? ''),
      elementName: s('Element'),
      fitMethod: s('FitMethod'),
      maxResidualMm: int.tryParse(s('MaxResidualMm') ?? ''),
      quality: s('Quality'),
      mappingConfirmed: flag('Mapping'),
      photoPath: s('Photo'),
      cameraTile: _parseVec(s('Cam')),
      cameraDirTile: _parseVec(s('CamDir')),
    );
    return h.hasContext || h.check != 'unchecked' ? h : null;
  }

  /// The §8 `arContext` block. Only what is known is sent.
  Map<String, dynamic> toArContext() => {
    'buildId': ?buildId,
    'globalId': ?globalId,
    'featureId': ?featureId,
    'fitMethod': ?fitMethod,
    'maxResidualMm': ?maxResidualMm,
    'quality': ?quality,
    'cameraTile': ?cameraTile,
    'cameraDirTile': ?cameraDirTile,
    'locationCheck': {
      'result': check,
      'offsetM': ?offsetM,
      'toleranceM': ?toleranceM,
      'tagMatches': ?tagMatches,
    },
    'mappingConfirmed': ?mappingConfirmed,
    'source': 'fieldops-ar',
  };

  /// A one-line, human summary for a snag's location text ("Model element
  /// CHW supply 150 · GlobalId 2O2Fr… · AR placed ±11 mm"), used where the
  /// form has no structured field for it yet.
  String summaryLine({String elementWord = 'Model element', String aligned = 'AR'}) {
    final parts = <String>[
      if (elementName != null) '$elementWord $elementName',
      if (globalId != null) 'GlobalId $globalId',
      if (quality != null) '$aligned $quality${maxResidualMm == null ? '' : ' ±$maxResidualMm mm'}',
    ];
    return parts.join(' · ');
  }

  static String _vec(List<double> v) => v.map((x) => x.toStringAsFixed(3)).join(',');

  static List<double>? _parseVec(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(',').map((x) => double.tryParse(x.trim())).toList();
    if (parts.length != 3 || parts.any((x) => x == null)) return null;
    return [for (final x in parts) x!];
  }
}
