import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

void main() {
  group('looksLikeClientCertificateRequired', () {
    test('- recognises TLS alerts about a missing or rejected certificate', () {
      for (final message in [
        'TLSV1_ALERT_CERTIFICATE_REQUIRED(tls_record.cc:592)',
        'SSLV3_ALERT_BAD_CERTIFICATE(tls_record.cc:594)',
        'TLSV1_ALERT_UNKNOWN_CA',
        'SSLV3_ALERT_HANDSHAKE_FAILURE',
      ]) {
        expect(
          looksLikeClientCertificateRequired(
            HandshakeException('Handshake error', OSError(message)),
          ),
          isTrue,
          reason: message,
        );
      }
    });

    test('- recognises the nginx "no required SSL certificate" page', () {
      expect(
        looksLikeClientCertificateRequired(
          null,
          statusCode: 400,
          body: '<h1>400 Bad Request</h1>No required SSL certificate was sent',
        ),
        isTrue,
      );
    });

    test('- ignores unrelated failures', () {
      expect(looksLikeClientCertificateRequired(null), isFalse);
      expect(
        looksLikeClientCertificateRequired(
          const SocketException('Connection refused'),
        ),
        isFalse,
      );
      expect(
        looksLikeClientCertificateRequired(
          const HandshakeException(
            'Handshake error',
            OSError('CERTIFICATE_VERIFY_FAILED: self signed'),
          ),
        ),
        isFalse,
      );
      expect(
        looksLikeClientCertificateRequired(null, statusCode: 400, body: 'x'),
        isFalse,
      );
    });
  });

  test('- the probe ignores non-HTTPS addresses', () async {
    expect(
      await ClientCertificateProbe.requiresCertificate(
        Uri.parse('http://127.0.0.1:1/'),
      ),
      isFalse,
    );
  });
}
