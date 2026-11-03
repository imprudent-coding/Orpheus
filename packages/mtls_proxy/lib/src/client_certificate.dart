import 'package:flutter/foundation.dart';

/// A PKCS#12 client certificate with its password and, optionally, the PEM of
/// a private CA that signed the server's certificate.
///
/// The secret material never appears in [toString], so it cannot leak into a
/// log line or an error message by accident.
@immutable
class ClientCertificate {
  ClientCertificate({
    required Uint8List pkcs12,
    required this.password,
    Uint8List? caPem,
  }) : pkcs12 = Uint8List.fromList(pkcs12),
       caPem = caPem == null ? null : Uint8List.fromList(caPem);

  /// Raw PKCS#12 (.p12 / .pfx) bytes.
  final Uint8List pkcs12;

  final String password;

  /// PEM bundle of a private CA to trust for this connection's servers.
  final Uint8List? caPem;

  ClientCertificate withCaPem(Uint8List? caPem) =>
      ClientCertificate(pkcs12: pkcs12, password: password, caPem: caPem);

  @override
  bool operator ==(Object other) =>
      other is ClientCertificate &&
      listEquals(other.pkcs12, pkcs12) &&
      other.password == password &&
      listEquals(other.caPem, caPem);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(pkcs12),
    password,
    caPem == null ? null : Object.hashAll(caPem!),
  );

  @override
  String toString() =>
      'ClientCertificate(${pkcs12.length} bytes, '
      'password: <redacted>, ca: ${caPem == null ? 'none' : 'set'})';
}

/// What the user is shown about a client certificate.
@immutable
class CertificateDetails {
  const CertificateDetails({
    required this.subject,
    required this.issuer,
    required this.validFrom,
    required this.validTo,
  });

  /// Days before expiry from which the UI warns.
  static const expiryWarning = Duration(days: 30);

  /// Distinguished name, in the `/CN=.../O=...` form dart:io reports.
  final String subject;
  final String issuer;
  final DateTime validFrom;
  final DateTime validTo;

  String get commonName => commonNameOf(subject) ?? subject;

  String get issuerCommonName => commonNameOf(issuer) ?? issuer;

  bool isExpiredAt(DateTime now) => !now.toUtc().isBefore(validTo.toUtc());

  bool isNotYetValidAt(DateTime now) => now.toUtc().isBefore(validFrom.toUtc());

  /// True when the certificate expires within [expiryWarning] of [now] but has
  /// not expired yet.
  bool expiresSoonAt(DateTime now) =>
      !isExpiredAt(now) &&
      validTo.toUtc().difference(now.toUtc()) <= expiryWarning;

  bool get isExpired => isExpiredAt(DateTime.now());

  bool get expiresSoon => expiresSoonAt(DateTime.now());

  /// Reads the common name out of a `/CN=a/O=b` or `CN=a, O=b` string.
  static String? commonNameOf(String distinguishedName) {
    final match = RegExp(
      r'(?:^|[/,]\s*)CN=([^/,]+)',
    ).firstMatch(distinguishedName);
    return match?.group(1)?.trim();
  }

  @override
  bool operator ==(Object other) =>
      other is CertificateDetails &&
      other.subject == subject &&
      other.issuer == issuer &&
      other.validFrom == validFrom &&
      other.validTo == validTo;

  @override
  int get hashCode => Object.hash(subject, issuer, validFrom, validTo);

  @override
  String toString() =>
      'CertificateDetails($commonName, issuer: $issuerCommonName, '
      'valid to: ${validTo.toIso8601String()})';
}

enum CertificateImportError {
  /// The password does not open the PKCS#12 file.
  wrongPassword,

  /// The bytes are not a PKCS#12 file, or it is damaged.
  invalidFile,

  /// The file opens but holds no usable certificate and private key pair.
  missingKeyOrCertificate,

  /// The CA file is not a PEM certificate bundle.
  invalidCa,
}

class CertificateImportException implements Exception {
  const CertificateImportException(this.error, this.message);

  final CertificateImportError error;

  /// A sentence the UI can show as is.
  final String message;

  @override
  String toString() => 'CertificateImportException(${error.name}): $message';
}
