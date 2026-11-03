import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mtls_proxy/mtls_proxy.dart';

/// Test fixtures created by `test/fixtures/generate.sh`.
abstract final class Fixtures {
  static const password = 'secret';

  static Uint8List bytes(String name) =>
      File('test/fixtures/$name').readAsBytesSync();

  static String text(String name) =>
      File('test/fixtures/$name').readAsStringSync();

  static ClientCertificate client({
    String file = 'client.p12',
    bool withCa = true,
  }) => ClientCertificate(
    pkcs12: bytes(file),
    password: password,
    caPem: withCa ? bytes('ca.pem') : null,
  );
}

typedef Handler = Future<void> Function(HttpRequest request);

/// An HTTPS server on 127.0.0.1 that refuses the TLS handshake unless the
/// client presents a certificate signed by the `clientCa` fixture, like a
/// reverse proxy
/// configured for mandatory mTLS.
class MtlsTestServer {
  MtlsTestServer._(this._server, this._http);

  static Future<MtlsTestServer> start({
    String certificate = 'server.pem',
    String key = 'server.key',
    String clientCa = 'ca.pem',
    bool requireClientCertificate = true,
  }) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(Fixtures.bytes(certificate))
      ..usePrivateKeyBytes(Fixtures.bytes(key))
      ..setTrustedCertificatesBytes(Fixtures.bytes(clientCa))
      ..setClientAuthoritiesBytes(Fixtures.bytes(clientCa));
    final socket = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
      requireClientCertificate: requireClientCertificate,
    );
    final http = HttpServer.listenOn(_ServerSocketAdapter(socket))
      ..autoCompress = false;
    final server = MtlsTestServer._(socket, http);
    http.listen(server._dispatch);
    return server;
  }

  final SecureServerSocket _server;
  final HttpServer _http;

  /// Handlers by path; unknown paths answer 404.
  final handlers = <String, Handler>{};

  /// Every request that reached a handler, in order.
  final requests = <HttpRequest>[];

  /// Subject of the client certificate of the latest request.
  String? lastClientSubject;

  int get port => _server.port;

  String get url => 'https://127.0.0.1:$port';

  Uri uri(String pathAndQuery) => Uri.parse('$url$pathAndQuery');

  Future<void> _dispatch(HttpRequest request) async {
    requests.add(request);
    lastClientSubject = request.certificate?.subject;
    final handler = handlers[request.uri.path];
    if (handler == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    await handler(request);
  }

  Future<void> close() async {
    await _http.close(force: true);
    await _server.close();
  }
}

/// [HttpServer.listenOn] wants a [ServerSocket]; a [SecureServerSocket]
/// provides the same stream of connected sockets.
class _ServerSocketAdapter extends Stream<Socket> implements ServerSocket {
  _ServerSocketAdapter(this._inner);

  final SecureServerSocket _inner;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  @override
  Future<ServerSocket> close() async {
    await _inner.close();
    return this;
  }
}

/// Trust built from fixture PEMs instead of fingerprints.
class FixtureTrust implements ServerTrust {
  FixtureTrust({this.pinnedPem, this.allowUntrusted = false});

  final String? pinnedPem;
  final bool allowUntrusted;

  static String _normalize(String pem) => pem.replaceAll(RegExp(r'\s'), '');

  @override
  bool isPinned(String host, int port) => pinnedPem != null;

  @override
  bool matchesPin(X509Certificate certificate, String host, int port) =>
      _normalize(certificate.pem) == _normalize(pinnedPem!);

  @override
  bool allowsUntrusted(X509Certificate certificate, String host, int port) =>
      allowUntrusted;
}

/// A plain client for talking to the proxy, as a native player would.
Future<HttpClientResponse> send(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  List<int>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request
    ..followRedirects = false
    // dart:io asks for gzip by default; a native player usually does not.
    ..headers.removeAll(HttpHeaders.acceptEncodingHeader);
  headers.forEach(request.headers.set);
  if (body != null) request.add(body);
  return request.close();
}

Future<String> readText(HttpClientResponse response) =>
    response.transform(const SystemEncoding().decoder).join();
