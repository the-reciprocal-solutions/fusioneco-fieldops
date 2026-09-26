import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/permit/permit_gas.dart';
import 'package:technician_portal/domain/permit.dart';

void main() {
  group('PermitGas.evaluate — inclusive bounds', () {
    const o2 = GasLimit(gas: 'o2', label: 'Oxygen', unit: '% vol', min: 19.5, max: 23.5);
    const lel = GasLimit(gas: 'lel', label: 'LEL', unit: '% LEL', max: 10);

    test('a reading exactly on the boundary passes — inclusive, not exclusive', () {
      expect(PermitGas.evaluate(o2, 19.5).isPass, isTrue);
      expect(PermitGas.evaluate(o2, 23.5).isPass, isTrue);
      expect(PermitGas.evaluate(lel, 10).isPass, isTrue);
    });

    test('just outside either bound fails, with a message naming which bound', () {
      final low = PermitGas.evaluate(o2, 19.4);
      expect(low.isFail, isTrue);
      expect(low.message, contains('below the minimum'));

      final high = PermitGas.evaluate(o2, 23.6);
      expect(high.isFail, isTrue);
      expect(high.message, contains('above the maximum'));
    });

    test('a max-only limit has no lower bound to fail against', () {
      expect(PermitGas.evaluate(lel, 0).isPass, isTrue);
      expect(PermitGas.evaluate(lel, 10.1).isFail, isTrue);
    });

    test('a null reading is "not tested yet", never a failure', () {
      final r = PermitGas.evaluate(o2, null);
      expect(r.isUnknown, isTrue);
      expect(r.isFail, isFalse);
      expect(r.isPass, isFalse);
    });

    test('a value in the middle of the band passes cleanly', () {
      expect(PermitGas.evaluate(o2, 21).isPass, isTrue);
    });
  });

  group('PermitGas.evaluateAll and overallPass', () {
    final profile = GasProfile(
      limits: const [
        GasLimit(gas: 'o2', label: 'Oxygen', unit: '% vol', min: 19.5, max: 23.5),
        GasLimit(gas: 'lel', label: 'LEL', unit: '% LEL', max: 10),
        GasLimit(gas: 'h2s', label: 'H2S', unit: 'ppm', max: 10),
      ],
    );

    test('evaluateAll returns one verdict per gas the profile judges', () {
      final results = PermitGas.evaluateAll(profile, {'o2': 20.9, 'lel': 0});
      expect(results.keys, containsAll(['o2', 'lel', 'h2s']));
      expect(results['o2']!.isPass, isTrue);
      expect(results['lel']!.isPass, isTrue);
      // h2s was never read — unknown, not a failure.
      expect(results['h2s']!.isUnknown, isTrue);
    });

    test('overallPass requires every limit to be read AND within band', () {
      expect(PermitGas.overallPass(profile, {'o2': 20.9, 'lel': 0, 'h2s': 5}), isTrue);
      // one gas missing entirely (unknown) fails the whole test
      expect(PermitGas.overallPass(profile, {'o2': 20.9, 'lel': 0}), isFalse);
      // one gas out of band fails the whole test
      expect(PermitGas.overallPass(profile, {'o2': 20.9, 'lel': 15, 'h2s': 5}), isFalse);
    });

    test('a profile with no limits at all trivially passes — no gas requirement', () {
      expect(PermitGas.overallPass(GasProfile.empty, const {}), isTrue);
    });
  });

  group('permitCheckTokenFromScan — worksite QR', () {
    test('matches the plain path with any case and no trailing slash', () {
      expect(permitCheckTokenFromScan('https://fusioneco.app/permit-check/abcDEF123'), 'abcDEF123');
      expect(permitCheckTokenFromScan('HTTPS://fusioneco.app/PERMIT-CHECK/abcDEF123'), 'abcDEF123');
    });

    test('is case-sensitive about the token itself, even though the URL is not', () {
      // The `PERMIT-CHECK` segment above matched case-insensitively, but the
      // captured token is never upper-cased or otherwise normalised.
      final token = permitCheckTokenFromScan('HTTPS://fusioneco.app/permit-check/MixedCaseTok');
      expect(token, 'MixedCaseTok');
    });

    test('tolerates a trailing slash, a query string, or a fragment', () {
      expect(permitCheckTokenFromScan('https://fusioneco.app/permit-check/tok123/'), 'tok123');
      expect(permitCheckTokenFromScan('https://fusioneco.app/permit-check/tok123?ref=qr'), 'tok123');
      expect(permitCheckTokenFromScan('https://fusioneco.app/permit-check/tok123#top'), 'tok123');
    });

    test('the host is never checked — a printed certificate survives a domain change', () {
      expect(permitCheckTokenFromScan('http://192.168.1.5:5002/permit-check/tok123'), 'tok123');
      expect(permitCheckTokenFromScan('https://old-domain.example/permit-check/tok123'), 'tok123');
    });

    test('leading/trailing whitespace from the scanner is trimmed', () {
      expect(permitCheckTokenFromScan('  https://fusioneco.app/permit-check/tok123  '), 'tok123');
    });

    test('anything that is not a /permit-check/<token> URL falls through as null', () {
      expect(permitCheckTokenFromScan(''), isNull);
      expect(permitCheckTokenFromScan('not a url at all'), isNull);
      expect(permitCheckTokenFromScan('https://fusioneco.app/permit-check/'), isNull);
      expect(permitCheckTokenFromScan('https://fusioneco.app/other-path/tok123'), isNull);
      expect(permitCheckTokenFromScan('{"type":"Asset","id":"a1"}'), isNull);
      expect(permitCheckTokenFromScan('https://fusioneco.app/permit-check/tok/extra'), isNull);
    });
  });
}
