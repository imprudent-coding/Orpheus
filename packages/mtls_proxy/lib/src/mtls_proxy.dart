import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mtls_proxy/src/certificate_inspector.dart';
import 'package:mtls_proxy/src/certificate_store.dart';
import 'package:mtls_proxy/src/client_certificate.dart';
import 'package:mtls_proxy/src/proxy_server.dart';
import 'package:mtls_proxy/src/server_origin.dart';
import 'package:mtls_proxy/src/server_trust.dart';

class _Entry {
  _Entry(this.connection, this.security, {required this.persisted});

  final StoredConnection connection;
  final ConnectionSecurity security;
  final bool persisted;
  CertificateDetails? details;
}

/// Registry of the server connections that present a client certificate, and
/// the single place the app turns server URLs into something a native
/// consumer can open.
///
/// - [contextFor] gives the TLS context with the client certificate, only for
///   a host:port that belongs to a configured connection (home or remote
///   address). Every other host gets null, so the certificate is never sent
///   to a third party.
/// - [resolve] returns a loopback proxy URL for those servers and the URL
///   itself for everything else, so connections without a certificate behave
///   exactly as before.
class MtlsProxy extends ChangeNotifier implements ProxyRoutes {
  MtlsProxy({
    ServerTrust trust = const StrictServerTrust(),
    ProxyOptions options = const ProxyOptions(),
    void Function(String message)? log,
  }) : _log = log ?? _noLog {
    _server = MtlsProxyServer(
      routes: this,
      trust: trust,
      options: options,
      log: _log,
    );
  }

  static void _noLog(String _) {}

  /// The app-wide instance. Replaced only in tests.
  static MtlsProxy instance = MtlsProxy();

  /// Connection ID used while a server is being added and its real ID is not
  /// known yet. A staged certificate is kept in memory only.
  static const stagedConnectionId = '__orpheus_staged__';

  final void Function(String message) _log;
  late final MtlsProxyServer _server;
  CertificateStore? _store;
  AppLifecycleListener? _lifecycle;

  final _entries = <String, _Entry>{};
  final _attachedUrls = <String, List<String>>{};
  final _routeIds = <ServerOrigin, String>{};
  final _routesById = <String, ProxyRoute>{};
  final _routesByOrigin = <ServerOrigin, ProxyRoute>{};

  /// The browser handles client certificates itself on the web.
  bool get isSupported => !kIsWeb;

  bool get hasConnections => _entries.isNotEmpty;

  // The trust is handed to the server; nothing needs to read it back.
  // ignore: avoid_setters_without_getters
  set trust(ServerTrust trust) => _server.trust = trust;

  @visibleForTesting
  MtlsProxyServer get server => _server;

  /// Loads every stored connection and starts the proxy when at least one
  /// exists. Call before the app makes its first network request.
  Future<void> load(CertificateStore store) async {
    _store = store;
    if (!isSupported) return;
    for (final connection in await store.loadAll()) {
      try {
        _entries[connection.id] = _Entry(
          connection,
          ConnectionSecurity(connection.certificate),
          persisted: true,
        );
      } on CertificateImportException catch (error) {
        _log('mtls: skipped a stored certificate (${error.error.name})');
      }
    }
    _rebuildRoutes();
    if (_entries.isNotEmpty) await _server.start();
    notifyListeners();
  }

  /// Restarts the proxy whenever the app comes back to the foreground, so a
  /// listener the OS reclaimed while suspended is replaced transparently.
  void attachToAppLifecycle() {
    if (!isSupported || _lifecycle != null) return;
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(ensureRunning(force: true)),
    );
  }

  /// Validates [pkcs12] with [password] without storing anything.
  Future<CertificateDetails> inspect(Uint8List pkcs12, String password) =>
      CertificateInspector.inspect(pkcs12, password);

  /// Validates and stores [certificate] for [connectionId], replacing any
  /// earlier one, and presents it to the hosts of [serverUrls] from now on.
  Future<CertificateDetails> install(
    String connectionId, {
    required ClientCertificate certificate,
    required Iterable<String> serverUrls,
  }) => _install(
    connectionId,
    certificate: certificate,
    serverUrls: serverUrls,
    persist: connectionId != stagedConnectionId,
  );

  /// Holds [certificate] in memory for a server that is being added, so the
  /// sign-in requests can present it. [commitStaged] stores it under the
  /// connection's real ID once sign-in succeeds.
  Future<CertificateDetails> stage({
    required ClientCertificate certificate,
    required String serverUrl,
  }) => _install(
    stagedConnectionId,
    certificate: certificate,
    serverUrls: [serverUrl],
    persist: false,
  );

  bool get hasStaged => _entries.containsKey(stagedConnectionId);

  Future<void> commitStaged(
    String connectionId,
    Iterable<String> serverUrls,
  ) async {
    final staged = _entries.remove(stagedConnectionId);
    if (staged == null) return;
    final connection = StoredConnection(
      id: connectionId,
      certificate: staged.connection.certificate,
      serverUrls: _normalized(serverUrls),
    );
    await _store?.save(connection);
    _entries[connectionId] = _Entry(
      connection,
      staged.security,
      persisted: true,
    )..details = staged.details;
    _changed();
  }

  void discardStaged() {
    if (_entries.remove(stagedConnectionId) != null) _changed();
  }

  /// Keeps the hosts the certificate is presented to in step with the
  /// connection's addresses (for example after the remote URL changed).
  Future<void> setServerUrls(
    String connectionId,
    Iterable<String> serverUrls,
  ) async {
    final entry = _entries[connectionId];
    if (entry == null) return;
    final urls = _normalized(serverUrls);
    if (listEquals(urls, entry.connection.serverUrls)) return;
    final connection = entry.connection.copyWith(serverUrls: urls);
    if (entry.persisted) await _store?.save(connection);
    _entries[connectionId] = _Entry(
      connection,
      entry.security,
      persisted: entry.persisted,
    )..details = entry.details;
    _changed();
  }

  /// Sets (or with null, removes) the private CA used to verify the servers
  /// of [connectionId], keeping its client certificate.
  Future<void> setCustomCa(String connectionId, Uint8List? caPem) async {
    final entry = _entries[connectionId];
    if (entry == null) return;
    if (caPem != null) CertificateInspector.validateCaPem(caPem);
    final certificate = entry.connection.certificate.withCaPem(caPem);
    final connection = entry.connection.copyWith(certificate: certificate);
    if (entry.persisted) await _store?.save(connection);
    _entries[connectionId] = _Entry(
      connection,
      ConnectionSecurity(certificate),
      persisted: entry.persisted,
    )..details = entry.details;
    _changed();
  }

  /// Presents [connectionId]'s certificate to [urls] too: other services
  /// behind the same reverse proxy (for example a music request service on
  /// its own host) that accept the same client certificate.
  ///
  /// Kept in memory only and apart from the connection's own addresses, so
  /// [setServerUrls], [install] and replacing the certificate leave them in
  /// place. The app attaches them again after every launch. They take effect
  /// while [connectionId] has a certificate; an empty list detaches them.
  void attachUrls(String connectionId, Iterable<String> urls) {
    final normalized = _normalized(urls);
    final current = _attachedUrls[connectionId] ?? const <String>[];
    if (listEquals(normalized, current)) return;
    if (normalized.isEmpty) {
      _attachedUrls.remove(connectionId);
    } else {
      _attachedUrls[connectionId] = normalized;
    }
    if (_entries.containsKey(connectionId)) _changed();
  }

  /// The URLs attached to [connectionId] with [attachUrls].
  List<String> attachedUrls(String connectionId) =>
      List.unmodifiable(_attachedUrls[connectionId] ?? const <String>[]);

  Future<void> remove(String connectionId) async {
    final entry = _entries.remove(connectionId);
    await _store?.remove(connectionId);
    if (entry == null) return;
    _changed();
    if (_entries.isEmpty) await _server.close();
  }

  bool hasCertificate(String connectionId) =>
      _entries.containsKey(connectionId);

  bool hasCustomCa(String connectionId) =>
      _entries[connectionId]?.connection.certificate.caPem != null;

  /// What the UI shows about [connectionId]'s certificate.
  Future<CertificateDetails?> details(String connectionId) async {
    final entry = _entries[connectionId];
    if (entry == null) return null;
    final certificate = entry.connection.certificate;
    return entry.details ??= await CertificateInspector.inspect(
      certificate.pkcs12,
      certificate.password,
    );
  }

  /// The connection whose certificate applies to [uri], if any.
  String? connectionIdFor(Uri uri) {
    final origin = ServerOrigin.of(uri);
    if (origin == null) return null;
    for (final MapEntry(:key, :value) in _entries.entries.toList().reversed) {
      if (_originsOf(value.connection).contains(origin)) return key;
    }
    return null;
  }

  /// Whether requests to [uri] need the client certificate.
  bool appliesTo(Uri uri) {
    final origin = ServerOrigin.of(uri);
    return origin != null && _routesByOrigin.containsKey(origin);
  }

  bool appliesToUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && appliesTo(uri);
  }

  /// The TLS context that presents the client certificate to [host]:[port],
  /// or null when no configured connection uses that host. With [pinned] the
  /// context trusts no roots, so the caller's pin check decides alone.
  SecurityContext? contextFor(String host, int port, {required bool pinned}) {
    final route = _routesByOrigin[ServerOrigin(host, port)];
    return route?.security.contextFor(pinned: pinned);
  }

  /// [uri] as the native consumers must open it: through the loopback proxy
  /// when its server needs a client certificate, unchanged otherwise.
  ///
  /// Call this at the moment of use and never persist the result: the token
  /// changes at every launch and the port can change after a restart.
  Future<Uri> resolve(Uri uri) async {
    if (!appliesTo(uri)) return uri;
    await _server.ensureRunning();
    return _server.proxyUriFor(uri) ?? uri;
  }

  Future<String> resolveUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return (await resolve(uri)).toString();
  }

  Future<void> ensureRunning({bool force = false}) async {
    if (_entries.isEmpty) return;
    await _server.ensureRunning(force: force);
  }

  /// [message] with the proxy token replaced, for anything that might quote
  /// a proxy URL (player error messages, for example) before it is logged.
  String redact(String message) {
    final token = _server.token.value;
    return message.contains(token)
        ? message.replaceAll(token, '<proxy-token>')
        : message;
  }

  /// An [HttpClient] that presents the client certificate to configured
  /// servers (and only to them), independent of the app's HttpOverrides.
  HttpClient createHttpClient({ServerTrust? trust}) {
    final judge = trust ?? const StrictServerTrust();
    return HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _PlainHttpOverrides(),
      )
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        final origin = ServerOrigin.of(uri);
        final route = origin == null ? null : _routesByOrigin[origin];
        if (origin != null && route != null) {
          return startSecureConnection(origin, route.security, judge);
        }
        final port = uri.hasPort
            ? uri.port
            : (uri.isScheme('https') ? 443 : 80);
        return uri.isScheme('https')
            ? SecureSocket.startConnect(
                uri.host,
                port,
                onBadCertificate: (certificate) =>
                    judge.allowsUntrusted(certificate, uri.host, port),
              )
            : Socket.startConnect(uri.host, port);
      };
  }

  @override
  ProxyRoute? routeById(String id) => _routesById[id];

  @override
  ProxyRoute? routeForOrigin(ServerOrigin origin) => _routesByOrigin[origin];

  /// Stops the proxy and forgets the lifecycle hook.
  Future<void> close() async {
    _lifecycle?.dispose();
    _lifecycle = null;
    await _server.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  Future<CertificateDetails> _install(
    String connectionId, {
    required ClientCertificate certificate,
    required Iterable<String> serverUrls,
    required bool persist,
  }) async {
    final details = await CertificateInspector.inspect(
      certificate.pkcs12,
      certificate.password,
    );
    final ca = certificate.caPem;
    if (ca != null) CertificateInspector.validateCaPem(ca);
    final connection = StoredConnection(
      id: connectionId,
      certificate: certificate,
      serverUrls: _normalized(serverUrls),
    );
    final security = ConnectionSecurity(certificate);
    if (persist) await _store?.save(connection);
    _entries
      ..remove(connectionId)
      ..[connectionId] = (_Entry(
        connection,
        security,
        persisted: persist,
      )..details = details);
    _changed();
    await _server.start();
    return details;
  }

  void _changed() {
    _rebuildRoutes();
    _server.resetUpstreamConnections();
    notifyListeners();
  }

  void _rebuildRoutes() {
    _routesById.clear();
    _routesByOrigin.clear();
    // Later entries win when two connections claim the same host, so a
    // freshly staged certificate takes precedence while a server is added.
    for (final MapEntry(key: id, value: entry) in _entries.entries) {
      final origins = {
        ..._originsOf(entry.connection),
        for (final url in _attachedUrls[id] ?? const <String>[])
          ?ServerOrigin.parse(url),
      };
      for (final origin in origins) {
        final routeId = _routeIds.putIfAbsent(origin, _newRouteId);
        final route = ProxyRoute(
          id: routeId,
          origin: origin,
          security: entry.security,
        );
        _routesById[routeId] = route;
        _routesByOrigin[origin] = route;
      }
    }
  }

  static Set<ServerOrigin> _originsOf(StoredConnection connection) => {
    for (final url in connection.serverUrls) ?ServerOrigin.parse(url),
  };

  static List<String> _normalized(Iterable<String> urls) => [
    for (final url in {for (final url in urls) url.trim()})
      if (url.isNotEmpty) url,
  ];

  static String _newRouteId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 6; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }
}

class _PlainHttpOverrides extends HttpOverrides {}
