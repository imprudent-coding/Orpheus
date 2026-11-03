import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mtls_proxy/src/access_token.dart';
import 'package:mtls_proxy/src/server_origin.dart';
import 'package:mtls_proxy/src/server_trust.dart';

/// One configured upstream: requests under `/<token>/<id>/` go to [origin]
/// with [security]'s client certificate.
@immutable
class ProxyRoute {
  const ProxyRoute({
    required this.id,
    required this.origin,
    required this.security,
  });

  final String id;
  final ServerOrigin origin;
  final ConnectionSecurity security;
}

/// Where the proxy looks up its routes. Implemented by `MtlsProxy`.
abstract interface class ProxyRoutes {
  ProxyRoute? routeById(String id);

  ProxyRoute? routeForOrigin(ServerOrigin origin);
}

@immutable
class ProxyOptions {
  const ProxyOptions({
    this.maxInvalidRequests = 30,
    this.invalidRequestWindow = const Duration(seconds: 10),
    this.cooldown = const Duration(seconds: 10),
    this.upstreamConnectTimeout = const Duration(seconds: 15),
    this.healthCheckInterval = const Duration(seconds: 5),
    this.healthCheckTimeout = const Duration(seconds: 2),
    this.playlistLimit = 2 * 1024 * 1024,
  });

  /// Invalid-token requests tolerated within [invalidRequestWindow] before
  /// the proxy refuses new connections for [cooldown].
  final int maxInvalidRequests;
  final Duration invalidRequestWindow;
  final Duration cooldown;
  final Duration upstreamConnectTimeout;

  /// [MtlsProxyServer.ensureRunning] probes the server at most this often.
  final Duration healthCheckInterval;
  final Duration healthCheckTimeout;

  /// HLS playlists up to this size are rewritten; larger ones pass through.
  final int playlistLimit;
}

/// A plain-HTTP reverse proxy on 127.0.0.1 that forwards to mTLS servers.
///
/// Every request must start with `/<token>/<route>/`. The token is compared in
/// constant time; a request without it gets 403, and too many of those within
/// a short window close the listener to new connections for a cooldown.
/// Nothing that is logged contains the token, a URL or a header value.
class MtlsProxyServer {
  MtlsProxyServer({
    required ProxyRoutes routes,
    ServerTrust trust = const StrictServerTrust(),
    this.options = const ProxyOptions(),
    AccessToken? token,
    void Function(String message)? log,
    DateTime Function()? clock,
  }) : _routes = routes,
       _trust = trust,
       token = token ?? AccessToken.generate(),
       _log = log ?? _noLog,
       _guard = AccessGuard(
         maxFailures: options.maxInvalidRequests,
         window: options.invalidRequestWindow,
         cooldown: options.cooldown,
         clock: clock,
       );

  static void _noLog(String _) {}

  /// Path segment answered with 204 by a running server, for health checks.
  static const healthRoute = '_health';

  static const _hopByHop = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'proxy-connection',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };

  static const _webSocketHandshake = {
    'sec-websocket-key',
    'sec-websocket-version',
    'sec-websocket-extensions',
    'sec-websocket-accept',
    'sec-websocket-protocol',
  };

  static final _uriAttribute = RegExp('URI="([^"]*)"');

  final ProxyRoutes _routes;
  ServerTrust _trust;
  final ProxyOptions options;
  final AccessToken token;
  final void Function(String message) _log;
  final AccessGuard _guard;

  HttpServer? _server;
  _GatedServerSocket? _socket;
  Future<void>? _starting;
  HttpClient? _client;
  int? _lastPort;
  DateTime? _lastHealthy;

  // The trust is only consulted by the upstream connection factory.
  // ignore: avoid_setters_without_getters
  set trust(ServerTrust trust) {
    _trust = trust;
    resetUpstreamConnections();
  }

  bool get isRunning => _server != null;

  /// The listening port, or null while stopped.
  int? get port {
    try {
      return _server?.port;
    } on HttpException {
      // A server the OS (or a test) closed underneath us has no port.
      return null;
    }
  }

  /// The proxy URL for [upstream] when it belongs to a route and the server is
  /// running. Resolve at use time; the port can change after a restart and
  /// the token changes at every launch, so never persist the result.
  Uri? proxyUriFor(Uri upstream) {
    final port = this.port;
    final origin = ServerOrigin.of(upstream);
    if (port == null || origin == null) return null;
    final route = _routes.routeForOrigin(origin);
    if (route == null) return null;
    final scheme = upstream.scheme.toLowerCase() == 'wss' ? 'ws' : 'http';
    final path = upstream.path.isEmpty ? '/' : upstream.path;
    final query = upstream.hasQuery ? '?${upstream.query}' : '';
    return Uri.parse(
      '$scheme://${InternetAddress.loopbackIPv4.address}:$port'
      '/${token.value}/${route.id}$path$query',
    );
  }

  /// Starts the server unless it is running. Tries the previous port first so
  /// URLs a player already holds keep working after a restart.
  Future<void> start() {
    if (_server != null) return Future.value();
    return _starting ??= _bind().whenComplete(() => _starting = null);
  }

  /// Makes sure the server is running and answering, restarting it when it
  /// died (for example after iOS suspended the app). Probes at most every
  /// [ProxyOptions.healthCheckInterval] unless [force] is set.
  Future<void> ensureRunning({bool force = false}) async {
    if (_server == null) {
      await start();
      return;
    }
    final checked = _lastHealthy;
    if (!force &&
        checked != null &&
        DateTime.now().difference(checked) < options.healthCheckInterval) {
      return;
    }
    if (await _answersHealthCheck()) {
      _lastHealthy = DateTime.now();
      return;
    }
    _log('proxy: not answering, restarting');
    await _shutdown();
    await start();
  }

  /// Closes the pooled upstream connections, for example after a certificate
  /// was replaced, so the next request handshakes with the new one.
  void resetUpstreamConnections() {
    _client?.close(force: true);
    _client = null;
  }

  Future<void> close() async {
    await _shutdown();
    resetUpstreamConnections();
  }

  /// Kills the listener the way the OS might, without telling the server.
  @visibleForTesting
  Future<void> simulateDeath() async {
    await _server?.close(force: true);
    await _socket?.close();
  }

  Future<void> _bind() async {
    ServerSocket raw;
    final previous = _lastPort;
    try {
      raw = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        previous ?? 0,
      );
    } on SocketException {
      if (previous == null) rethrow;
      raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    final socket = _GatedServerSocket(raw, () => _guard.isBlocked);
    final server = HttpServer.listenOn(socket)
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 30);
    server.defaultResponseHeaders.clear();
    _server = server;
    _socket = socket;
    _lastPort = server.port;
    _lastHealthy = DateTime.now();
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) => _markDead(server),
      onDone: () => _markDead(server),
    );
    _log('proxy: listening on loopback');
  }

  void _markDead(HttpServer server) {
    if (!identical(_server, server)) return;
    _log('proxy: listener closed');
    _server = null;
    unawaited(_socket?.close());
    _socket = null;
  }

  Future<void> _shutdown() async {
    final server = _server;
    final socket = _socket;
    _server = null;
    _socket = null;
    await server?.close(force: true);
    await socket?.close();
  }

  Future<bool> _answersHealthCheck() async {
    final port = this.port;
    if (port == null) return false;
    final client = HttpClient()
      ..connectionTimeout = options.healthCheckTimeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client
          .get(
            InternetAddress.loopbackIPv4.address,
            port,
            '/${token.value}/$healthRoute',
          )
          .timeout(options.healthCheckTimeout);
      final response = await request.close().timeout(
        options.healthCheckTimeout,
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.noContent;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (_guard.isBlocked) {
      await _reject(request, HttpStatus.forbidden);
      return;
    }

    final path = request.uri.path;
    final tokenEnd = path.indexOf('/', 1);
    final presented = path.length < 2
        ? ''
        : path.substring(1, tokenEnd < 0 ? path.length : tokenEnd);
    if (!token.accepts(presented)) {
      _guard.recordFailure();
      _log('proxy: rejected a request without a valid token');
      await _reject(request, HttpStatus.forbidden);
      return;
    }

    final rest = tokenEnd < 0 ? '' : path.substring(tokenEnd + 1);
    final routeEnd = rest.indexOf('/');
    final routeId = routeEnd < 0 ? rest : rest.substring(0, routeEnd);
    final upstreamPath = routeEnd < 0 ? '/' : rest.substring(routeEnd);

    if (routeId == healthRoute) {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close().catchError((Object _) {});
      return;
    }
    final route = _routes.routeById(routeId);
    if (route == null) {
      await _reject(request, HttpStatus.notFound);
      return;
    }

    final query = request.uri.hasQuery ? '?${request.uri.query}' : '';
    final upstream = Uri.parse(
      'https://${route.origin.authority}$upstreamPath$query',
    );

    if (WebSocketTransformer.isUpgradeRequest(request)) {
      await _bridgeWebSocket(request, route, upstream);
    } else {
      await _forward(request, route, upstream);
    }
  }

  HttpClient _upstream() {
    final existing = _client;
    if (existing != null) return existing;
    // A client of our own, unaffected by the app's HttpOverrides: the
    // connection factory below decides which certificate to present.
    final client =
        HttpOverrides.runWithHttpOverrides(
            HttpClient.new,
            _PlainHttpOverrides(),
          )
          ..autoUncompress = false
          ..connectionTimeout = options.upstreamConnectTimeout
          ..idleTimeout = const Duration(seconds: 15)
          ..findProxy = ((_) => 'DIRECT')
          ..connectionFactory = _connectUpstream;
    return _client = client;
  }

  Future<ConnectionTask<Socket>> _connectUpstream(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) {
    final origin = ServerOrigin.of(uri);
    final route = origin == null ? null : _routes.routeForOrigin(origin);
    if (origin == null || route == null) {
      return Future.error(
        const SocketException('mtls_proxy: no route for this host'),
      );
    }
    return startSecureConnection(origin, route.security, _trust);
  }

  Future<void> _forward(
    HttpRequest request,
    ProxyRoute route,
    Uri upstream,
  ) async {
    final response = request.response..bufferOutput = false;
    HttpClientResponse? reply;
    try {
      final outgoing = await _upstream().openUrl(request.method, upstream);
      outgoing
        ..followRedirects = false
        ..persistentConnection = true
        ..bufferOutput = false;
      outgoing.headers
        ..removeAll(HttpHeaders.acceptEncodingHeader)
        ..removeAll(HttpHeaders.userAgentHeader);
      _copyHeaders(request.headers, outgoing.headers, skip: const {'host'});
      final length = request.headers.contentLength;
      if (request.headers.chunkedTransferEncoding) {
        outgoing.headers.chunkedTransferEncoding = true;
      } else {
        outgoing.contentLength = length < 0 ? 0 : length;
      }
      await outgoing.addStream(request);
      reply = await outgoing.close();
    } on Object catch (error) {
      _log(
        'proxy: ${request.method} route ${route.id} failed upstream '
        '(${error.runtimeType})',
      );
      await _reject(request, HttpStatus.badGateway);
      return;
    }

    try {
      response
        ..statusCode = reply.statusCode
        ..reasonPhrase = reply.reasonPhrase;
      _copyHeaders(
        reply.headers,
        response.headers,
        skip: const {HttpHeaders.contentLengthHeader},
      );
      final location = reply.headers.value(HttpHeaders.locationHeader);
      if (location != null) {
        response.headers.set(
          HttpHeaders.locationHeader,
          _rewriteLocation(location, upstream),
        );
      }

      if (_isRewritablePlaylist(reply, upstream)) {
        await _servePlaylist(reply, response, upstream);
        return;
      }
      if (reply.contentLength >= 0) {
        response.contentLength = reply.contentLength;
      }
      await response.addStream(reply);
      await response.close();
    } on Object {
      // The player went away mid-stream: drop the upstream connection too.
      await _abort(reply);
      try {
        await response.close();
      } on Object {
        return;
      }
    }
  }

  void _copyHeaders(
    HttpHeaders from,
    HttpHeaders to, {
    Set<String> skip = const {},
  }) {
    final connectionTokens = <String>{
      for (final value
          in from[HttpHeaders.connectionHeader] ?? const <String>[])
        for (final part in value.split(','))
          if (part.trim().isNotEmpty) part.trim().toLowerCase(),
    };
    from.forEach((name, values) {
      final key = name.toLowerCase();
      if (_hopByHop.contains(key) ||
          connectionTokens.contains(key) ||
          skip.contains(key)) {
        return;
      }
      to.removeAll(name);
      for (final value in values) {
        to.add(name, value, preserveHeaderCase: true);
      }
    });
  }

  /// Points a redirect to a configured server back through the proxy. A
  /// redirect to any other host, or a relative one, is left alone.
  String _rewriteLocation(String location, Uri upstream) {
    final target = Uri.tryParse(location);
    if (target == null || (!target.hasScheme && !target.hasAuthority)) {
      return location;
    }
    final absolute = target.hasScheme
        ? target
        : target.replace(scheme: upstream.scheme);
    return proxyUriFor(absolute)?.toString() ?? location;
  }

  bool _isRewritablePlaylist(HttpClientResponse reply, Uri upstream) {
    if (reply.headers.value(HttpHeaders.contentEncodingHeader) != null) {
      return false;
    }
    final length = reply.contentLength;
    if (length > options.playlistLimit) return false;
    final mime = reply.headers.contentType?.mimeType.toLowerCase() ?? '';
    return mime.contains('mpegurl') ||
        upstream.path.toLowerCase().endsWith('.m3u8');
  }

  /// Rewrites absolute URLs in an HLS playlist that point at a configured
  /// server. Relative URLs already resolve through the proxy.
  Future<void> _servePlaylist(
    HttpClientResponse reply,
    HttpResponse response,
    Uri upstream,
  ) async {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in reply) {
      buffer.add(chunk);
      if (buffer.length > options.playlistLimit) {
        throw const HttpException('playlist too large');
      }
    }
    final body = utf8.decode(buffer.takeBytes(), allowMalformed: true);

    String proxify(String reference) {
      final target = Uri.tryParse(reference.trim());
      if (target == null || !target.hasScheme) return reference;
      return proxyUriFor(target)?.toString() ?? reference;
    }

    final out = StringBuffer();
    for (final line in const LineSplitter().convert(body)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.writeln(line);
      } else if (trimmed.startsWith('#')) {
        out.writeln(
          line.replaceAllMapped(
            _uriAttribute,
            (match) => 'URI="${proxify(match.group(1)!)}"',
          ),
        );
      } else {
        out.writeln(proxify(trimmed));
      }
    }
    final bytes = utf8.encode(out.toString());
    response
      ..contentLength = bytes.length
      ..add(bytes);
    await response.close();
  }

  Future<void> _bridgeWebSocket(
    HttpRequest request,
    ProxyRoute route,
    Uri upstream,
  ) async {
    final protocols = [
      for (final value
          in request.headers['sec-websocket-protocol'] ?? const <String>[])
        for (final part in value.split(','))
          if (part.trim().isNotEmpty) part.trim(),
    ];
    final headers = <String, dynamic>{};
    request.headers.forEach((name, values) {
      final key = name.toLowerCase();
      if (_hopByHop.contains(key) ||
          _webSocketHandshake.contains(key) ||
          key == 'host') {
        return;
      }
      headers[name] = values.length == 1 ? values.single : values;
    });

    WebSocket upstreamSocket;
    try {
      upstreamSocket = await WebSocket.connect(
        upstream.replace(scheme: 'wss').toString(),
        protocols: protocols.isEmpty ? null : protocols,
        headers: headers,
        compression: CompressionOptions.compressionOff,
        customClient: _upstream(),
      );
    } on Object catch (error) {
      _log(
        'proxy: websocket on route ${route.id} failed upstream '
        '(${error.runtimeType})',
      );
      await _reject(request, HttpStatus.badGateway);
      return;
    }

    WebSocket downstream;
    try {
      downstream = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: protocols.isEmpty
            ? null
            : (offered) => upstreamSocket.protocol ?? offered.first,
        compression: CompressionOptions.compressionOff,
      );
    } on Object {
      await upstreamSocket.close(WebSocketStatus.goingAway);
      return;
    }

    downstream.listen(
      upstreamSocket.add,
      onDone: () => unawaited(
        upstreamSocket.close(downstream.closeCode, downstream.closeReason),
      ),
      onError: (Object _) =>
          unawaited(upstreamSocket.close(WebSocketStatus.goingAway)),
      cancelOnError: true,
    );
    upstreamSocket.listen(
      downstream.add,
      onDone: () => unawaited(
        downstream.close(upstreamSocket.closeCode, upstreamSocket.closeReason),
      ),
      onError: (Object _) =>
          unawaited(downstream.close(WebSocketStatus.goingAway)),
      cancelOnError: true,
    );
  }

  Future<void> _reject(HttpRequest request, int status) async {
    try {
      // Read and discard any body so the connection stays usable.
      await request.drain<void>().catchError((Object _) {});
      request.response
        ..statusCode = status
        ..persistentConnection = false
        ..headers.contentType = ContentType.text
        ..write(status == HttpStatus.forbidden ? 'Forbidden' : 'Unavailable');
      await request.response.close();
    } on Object {
      return;
    }
  }

  Future<void> _abort(HttpClientResponse? reply) async {
    if (reply == null) return;
    try {
      (await reply.detachSocket()).destroy();
    } on Object {
      return;
    }
  }
}

/// Plain dart:io behaviour, regardless of the app's global overrides.
class _PlainHttpOverrides extends HttpOverrides {}

/// A [ServerSocket] that drops new connections while [_blocked] is true, which
/// is how the cooldown refuses connections instead of answering them.
class _GatedServerSocket extends Stream<Socket> implements ServerSocket {
  _GatedServerSocket(this._inner, this._blocked);

  final ServerSocket _inner;
  final bool Function() _blocked;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner
      .where((socket) {
        if (!_blocked()) return true;
        socket.destroy();
        return false;
      })
      .listen(
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
