import 'dart:io';

import 'package:mtls_proxy/src/certificate_inspector.dart';
import 'package:mtls_proxy/src/client_certificate.dart';
import 'package:mtls_proxy/src/server_origin.dart';

/// How server certificates are judged beyond normal chain verification. The
/// app implements this on top of its own certificate trust (user-trusted
/// self-signed certificates and pinned fingerprints), so a server that uses
/// both a client certificate and a self-signed or pinned server certificate
/// works through the proxy too.
abstract interface class ServerTrust {
  /// Whether [host]:[port] is pinned. A pinned host is checked against its pin
  /// only, never against the trusted roots.
  bool isPinned(String host, int port);

  bool matchesPin(X509Certificate certificate, String host, int port);

  /// Called when an unpinned server's certificate fails chain verification.
  bool allowsUntrusted(X509Certificate certificate, String host, int port);
}

/// Normal verification only: no pins, nothing untrusted accepted.
class StrictServerTrust implements ServerTrust {
  const StrictServerTrust();

  @override
  bool isPinned(String host, int port) => false;

  @override
  bool matchesPin(X509Certificate certificate, String host, int port) => false;

  @override
  bool allowsUntrusted(X509Certificate certificate, String host, int port) =>
      false;
}

/// The two TLS contexts of one connection: both present the client
/// certificate; one verifies the server against the system roots plus the
/// connection's private CA, the other trusts nothing so that a pinned server
/// is judged by its pin alone.
class ConnectionSecurity {
  ConnectionSecurity(ClientCertificate certificate)
    : verifying = _build(certificate, verify: true),
      pinning = _build(certificate, verify: false);

  final SecurityContext verifying;
  final SecurityContext pinning;

  SecurityContext contextFor({required bool pinned}) =>
      pinned ? pinning : verifying;

  static SecurityContext _build(
    ClientCertificate certificate, {
    required bool verify,
  }) {
    final context = CertificateInspector.identityContext(
      certificate.pkcs12,
      certificate.password,
      withTrustedRoots: verify,
    );
    final ca = certificate.caPem;
    if (verify && ca != null) context.setTrustedCertificatesBytes(ca);
    return context;
  }
}

/// Opens a TLS connection to [origin] that presents the client certificate in
/// [security] and judges the server certificate with [trust].
Future<ConnectionTask<Socket>> startSecureConnection(
  ServerOrigin origin,
  ConnectionSecurity security,
  ServerTrust trust,
) {
  final pinned = trust.isPinned(origin.host, origin.port);
  return SecureSocket.startConnect(
    origin.host,
    origin.port,
    context: security.contextFor(pinned: pinned),
    onBadCertificate: (certificate) => pinned
        ? trust.matchesPin(certificate, origin.host, origin.port)
        : trust.allowsUntrusted(certificate, origin.host, origin.port),
  );
}

/// Whether [error] is a TLS failure that a (valid) client certificate would
/// fix: the server asked for a certificate and got none, or rejected the one
/// it got. Pass the inner error of an HTTP client exception, or an HTTP
/// [statusCode] and [body] for servers (such as nginx) that report a missing
/// certificate with an HTTP 400 page instead of a TLS alert.
bool looksLikeClientCertificateRequired(
  Object? error, {
  int? statusCode,
  String? body,
}) {
  if (statusCode == 400 && body != null) {
    final text = body.toLowerCase();
    if (text.contains('ssl certificate') &&
        (text.contains('no required') || text.contains('required ssl'))) {
      return true;
    }
  }
  if (error == null) return false;
  final text = error.toString().toUpperCase();
  return text.contains('CERTIFICATE_REQUIRED') ||
      text.contains('ALERT_BAD_CERTIFICATE') ||
      text.contains('ALERT_UNKNOWN_CA') ||
      text.contains('ALERT_CERTIFICATE_UNKNOWN') ||
      text.contains('ALERT_HANDSHAKE_FAILURE') ||
      text.contains('PEER DID NOT RETURN A CERTIFICATE');
}
