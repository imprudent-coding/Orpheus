import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mtls_proxy/src/client_certificate.dart';

/// Validates PKCS#12 files with the platform TLS stack and reads what the user
/// needs to see about them.
///
/// dart:io can load a PKCS#12 file into a [SecurityContext] but cannot read
/// the certificate out of it. So the inspector uses the file as the identity
/// of a throwaway TLS server on the loopback interface, connects to it, and
/// reads the certificate the "server" presents. This parses the file with the
/// same code the real connection uses, so a file that inspects fine also
/// works for the real handshake.
abstract final class CertificateInspector {
  static const _handshakeTimeout = Duration(seconds: 10);

  /// Throws [CertificateImportException] when [pkcs12] cannot be used with
  /// [password].
  static Future<CertificateDetails> inspect(
    Uint8List pkcs12,
    String password,
  ) async {
    if (pkcs12.isEmpty || pkcs12.first != 0x30) {
      // PKCS#12 is DER: it always starts with a SEQUENCE tag.
      throw const CertificateImportException(
        CertificateImportError.invalidFile,
        'This is not a PKCS#12 (.p12 or .pfx) file.',
      );
    }
    final context = identityContext(pkcs12, password);

    SecureServerSocket? server;
    SecureSocket? client;
    try {
      server =
          (await SecureServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
            context,
          ))..listen(
            (socket) => socket.listen(
              (_) {},
              onError: (Object _) {},
              onDone: socket.destroy,
            ),
            onError: (Object _) {},
          );
      X509Certificate? presented;
      client = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        // Only our own throwaway server is on the other end; every
        // certificate is "bad" here because nothing about it is verified.
        onBadCertificate: (certificate) {
          presented = certificate;
          return true;
        },
        timeout: _handshakeTimeout,
      );
      final certificate = client.peerCertificate ?? presented;
      if (certificate == null) {
        throw const CertificateImportException(
          CertificateImportError.missingKeyOrCertificate,
          'The file holds no certificate.',
        );
      }
      return CertificateDetails(
        subject: certificate.subject,
        issuer: certificate.issuer,
        validFrom: certificate.startValidity.toUtc(),
        validTo: certificate.endValidity.toUtc(),
      );
    } on CertificateImportException {
      rethrow;
    } on Object {
      // A handshake fails when the private key does not match the
      // certificate, or the file holds only one of them.
      throw const CertificateImportException(
        CertificateImportError.missingKeyOrCertificate,
        'The file does not hold a matching certificate and private key.',
      );
    } finally {
      client?.destroy();
      await server?.close();
    }
  }

  /// Builds a context that presents [pkcs12] as its identity, translating
  /// BoringSSL errors into [CertificateImportException]s.
  static SecurityContext identityContext(
    Uint8List pkcs12,
    String password, {
    bool withTrustedRoots = false,
  }) {
    final context = SecurityContext(withTrustedRoots: withTrustedRoots);
    try {
      context
        ..useCertificateChainBytes(pkcs12, password: password)
        ..usePrivateKeyBytes(pkcs12, password: password);
    } on TlsException catch (error) {
      throw _classify(error);
      // usePrivateKeyBytes reports a file without a key as an ArgumentError.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      throw const CertificateImportException(
        CertificateImportError.missingKeyOrCertificate,
        'The file does not hold a private key.',
      );
    }
    return context;
  }

  /// Throws [CertificateImportException] unless [pem] is a PEM certificate
  /// bundle that can be used as trusted roots.
  static void validateCaPem(Uint8List pem) {
    final text = String.fromCharCodes(pem);
    if (!text.contains('-----BEGIN CERTIFICATE-----')) {
      throw const CertificateImportException(
        CertificateImportError.invalidCa,
        'The CA file must be a PEM certificate (BEGIN CERTIFICATE).',
      );
    }
    try {
      SecurityContext().setTrustedCertificatesBytes(pem);
    } on Object {
      throw const CertificateImportException(
        CertificateImportError.invalidCa,
        'The CA file could not be read as a certificate.',
      );
    }
  }

  static CertificateImportException _classify(TlsException error) {
    final detail = '${error.message} ${error.osError?.message ?? ''}'
        .toUpperCase();
    if (detail.contains('INCORRECT_PASSWORD') ||
        detail.contains('BAD_DECRYPT') ||
        detail.contains('MAC_VERIFY')) {
      return const CertificateImportException(
        CertificateImportError.wrongPassword,
        'The password is wrong for this certificate file.',
      );
    }
    if (detail.contains('NO_CERTIFICATE') ||
        detail.contains('NO_PRIVATE_KEY') ||
        detail.contains('KEY_VALUES_MISMATCH')) {
      return const CertificateImportException(
        CertificateImportError.missingKeyOrCertificate,
        'The file does not hold a matching certificate and private key.',
      );
    }
    return const CertificateImportException(
      CertificateImportError.invalidFile,
      'The certificate file is damaged or is not a PKCS#12 file.',
    );
  }
}
