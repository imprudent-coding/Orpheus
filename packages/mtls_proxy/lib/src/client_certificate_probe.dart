import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mtls_proxy/src/server_trust.dart';

/// Finds out whether an HTTPS server turns clients away for lacking a client
/// certificate, to explain a failed sign-in.
///
/// With TLS 1.3 the client finishes its side of the handshake before the
/// server checks the certificate, so a refusal often surfaces as nothing more
/// than a reset connection. The probe completes a handshake without a
/// certificate, sends a minimal request, and reports a refusal when the server
/// answers with a certificate alert, or drops the connection instead of
/// answering. It never sends a client certificate or credentials.
abstract final class ClientCertificateProbe {
  static Future<bool> requiresCertificate(
    Uri uri, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!uri.isScheme('https') || uri.host.isEmpty) return false;
    final port = uri.hasPort ? uri.port : 443;
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        uri.host,
        port,
        // Only the server's reaction matters here, not its identity.
        onBadCertificate: (_) => true,
        timeout: timeout,
      );
      final host = port == 443 ? uri.host : '${uri.host}:$port';
      socket.write(
        'HEAD / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      final reply = await socket
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      if (reply.isEmpty) return true;
      final status = int.tryParse(reply.split(' ').elementAtOrNull(1) ?? '');
      return looksLikeClientCertificateRequired(
        null,
        statusCode: status,
        body: reply,
      );
    } on TimeoutException {
      return false;
    } on SocketException catch (error) {
      // Refused or unreachable before TLS started says nothing about
      // certificates; a reset after the handshake does.
      return socket != null || looksLikeClientCertificateRequired(error);
    } on Object catch (error) {
      return looksLikeClientCertificateRequired(error);
    } finally {
      socket?.destroy();
    }
  }
}
