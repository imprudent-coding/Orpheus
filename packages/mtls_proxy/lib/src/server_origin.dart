import 'package:flutter/foundation.dart';

/// The TLS endpoint (host and port) a client certificate belongs to.
///
/// Only `https` and `wss` URLs have an origin here: a client certificate
/// means nothing without TLS.
@immutable
class ServerOrigin {
  ServerOrigin(String host, this.port) : host = host.toLowerCase();

  static ServerOrigin? of(Uri uri) {
    if (uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'wss') return null;
    return ServerOrigin(uri.host, uri.hasPort ? uri.port : 443);
  }

  static ServerOrigin? parse(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri == null ? null : of(uri);
  }

  final String host;
  final int port;

  /// `host[:port]`, with IPv6 hosts in brackets and the default port left out.
  String get authority {
    final name = host.contains(':') ? '[$host]' : host;
    return port == 443 ? name : '$name:$port';
  }

  bool matches(String host, int port) =>
      this.port == port && this.host == host.toLowerCase();

  @override
  bool operator ==(Object other) =>
      other is ServerOrigin && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'ServerOrigin($authority)';
}
