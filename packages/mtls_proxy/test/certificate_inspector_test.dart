import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

import 'support/test_support.dart';

Matcher _importError(CertificateImportError error) =>
    isA<CertificateImportException>().having(
      (exception) => exception.error,
      'error',
      error,
    );

void main() {
  group('CertificateInspector.inspect', () {
    test('- reads CN, issuer and expiry with the right password', () async {
      final details = await CertificateInspector.inspect(
        Fixtures.bytes('client.p12'),
        Fixtures.password,
      );

      expect(details.commonName, 'orpheus-test-client');
      expect(details.issuerCommonName, 'Orpheus Test CA');
      expect(details.validTo.isAfter(DateTime.utc(2100)), isTrue);
      expect(details.isExpired, isFalse);
      expect(details.expiresSoon, isFalse);
    });

    test('- opens files with legacy PKCS#12 encryption', () async {
      final details = await CertificateInspector.inspect(
        Fixtures.bytes('client_legacy.p12'),
        Fixtures.password,
      );

      expect(details.commonName, 'orpheus-test-client');
    });

    test('- reports a wrong password as such', () {
      expect(
        CertificateInspector.inspect(Fixtures.bytes('client.p12'), 'wrong'),
        throwsA(_importError(CertificateImportError.wrongPassword)),
      );
    });

    test('- reports a corrupt file', () {
      expect(
        CertificateInspector.inspect(
          Fixtures.bytes('corrupt.p12'),
          Fixtures.password,
        ),
        throwsA(_importError(CertificateImportError.invalidFile)),
      );
    });

    test('- reports a PEM file as not being PKCS#12', () {
      expect(
        CertificateInspector.inspect(
          Fixtures.bytes('ca.pem'),
          Fixtures.password,
        ),
        throwsA(_importError(CertificateImportError.invalidFile)),
      );
    });

    test('- reports a truncated PKCS#12 file', () {
      final full = Fixtures.bytes('client.p12');
      expect(
        CertificateInspector.inspect(
          Uint8List.sublistView(full, 0, full.length ~/ 2),
          Fixtures.password,
        ),
        throwsA(_importError(CertificateImportError.invalidFile)),
      );
    });

    test('- flags an expired certificate', () async {
      final details = await CertificateInspector.inspect(
        Fixtures.bytes('client_expired.p12'),
        Fixtures.password,
      );

      expect(details.commonName, 'orpheus-expired-client');
      expect(details.validTo, DateTime.utc(2021));
      expect(details.isExpired, isTrue);
      expect(details.expiresSoon, isFalse);
    });

    test('- error messages never contain the password', () async {
      try {
        await CertificateInspector.inspect(
          Fixtures.bytes('client.p12'),
          'hunter2-password',
        );
        fail('should have thrown');
      } on CertificateImportException catch (error) {
        expect(error.toString(), isNot(contains('hunter2')));
        expect(error.message, isNot(contains('hunter2')));
      }
    });
  });

  group('CertificateDetails', () {
    final details = CertificateDetails(
      subject: '/CN=phone/O=Home',
      issuer: '/O=Home/CN=Home CA',
      validFrom: DateTime.utc(2026),
      validTo: DateTime.utc(2026, 6),
    );

    test('- warns within 30 days of expiry', () {
      expect(details.expiresSoonAt(DateTime.utc(2026, 4)), isFalse);
      expect(details.expiresSoonAt(DateTime.utc(2026, 5, 2)), isTrue);
      expect(details.isExpiredAt(DateTime.utc(2026, 5, 31)), isFalse);
      expect(details.isExpiredAt(DateTime.utc(2026, 6)), isTrue);
      expect(details.expiresSoonAt(DateTime.utc(2026, 7)), isFalse);
    });

    test('- knows a certificate that is not valid yet', () {
      expect(details.isNotYetValidAt(DateTime.utc(2025, 12)), isTrue);
      expect(details.isNotYetValidAt(DateTime.utc(2026, 2)), isFalse);
    });

    test('- reads the common name of either DN notation', () {
      expect(details.commonName, 'phone');
      expect(details.issuerCommonName, 'Home CA');
      expect(CertificateDetails.commonNameOf('CN=a b, O=x'), 'a b');
      expect(CertificateDetails.commonNameOf('/O=x'), isNull);
    });
  });

  group('validateCaPem', () {
    test('- accepts a PEM CA', () {
      expect(
        () => CertificateInspector.validateCaPem(Fixtures.bytes('ca.pem')),
        returnsNormally,
      );
    });

    test('- rejects anything else', () {
      expect(
        () => CertificateInspector.validateCaPem(Fixtures.bytes('client.p12')),
        throwsA(_importError(CertificateImportError.invalidCa)),
      );
      expect(
        () => CertificateInspector.validateCaPem(
          Uint8List.fromList(
            utf8.encode('-----BEGIN CERTIFICATE-----\nnope\n'),
          ),
        ),
        throwsA(_importError(CertificateImportError.invalidCa)),
      );
    });
  });

  test('- ClientCertificate never prints its secrets', () {
    final certificate = ClientCertificate(
      pkcs12: Fixtures.bytes('client.p12'),
      password: 'hunter2-password',
    );

    expect(certificate.toString(), isNot(contains('hunter2')));
    expect(certificate.toString(), contains('redacted'));
  });
}
