// ORPHEUS: the app-side wiring of packages/mtls_proxy, against local HTTPS
// servers that require (or merely request) a client certificate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/core/network/certificate_trust.dart';
import 'package:jplayer/src/data/backend/server_type.dart';
import 'package:jplayer/src/data/providers/secure_storage_provider.dart';
import 'package:jplayer/src/data/storages/account_store.dart';
import 'package:jplayer/src/orpheus/mtls_integration.dart';
import 'package:jplayer/src/providers/accounts_provider.dart';
import 'package:jplayer/src/providers/base_url_provider.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

const _fixtures = 'packages/mtls_proxy/test/fixtures';

Uint8List _fixture(String name) => File('$_fixtures/$name').readAsBytesSync();

ClientCertificate _clientCertificate() => ClientCertificate(
  pkcs12: _fixture('client.p12'),
  password: 'secret',
  caPem: _fixture('ca.pem'),
);

/// An HTTPS server on 127.0.0.1 signed by the fixture CA. With `require` it
/// refuses clients without a certificate from that CA, otherwise it only asks.
class _TestServer {
  _TestServer._(this._socket, this._http);

  static Future<_TestServer> start({bool require = true}) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(_fixture('server.pem'))
      ..usePrivateKeyBytes(_fixture('server.key'))
      ..setTrustedCertificatesBytes(_fixture('ca.pem'))
      ..setClientAuthoritiesBytes(_fixture('ca.pem'));
    final socket = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
      requireClientCertificate: require,
    );
    final http = HttpServer.listenOn(_Adapter(socket));
    final server = _TestServer._(socket, http);
    http.listen((request) async {
      server.clientSubjects.add(request.certificate?.subject);
      request.response.write('hello from ${request.uri.path}');
      await request.response.close();
    });
    return server;
  }

  final SecureServerSocket _socket;
  final HttpServer _http;
  final clientSubjects = <String?>[];

  int get port => _socket.port;

  String get url => 'https://127.0.0.1:$port';

  Future<void> close() async {
    await _http.close(force: true);
    await _socket.close();
  }
}

class _Adapter extends Stream<Socket> implements ServerSocket {
  _Adapter(this._inner);

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

class _PlainHttpOverrides extends HttpOverrides {}

class _MemorySecureStorage extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.remove(key);
}

Future<String> _get(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  return response.transform(utf8.decoder).join();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestServer server;
  late MtlsProxy previous;

  setUp(() async {
    previous = MtlsProxy.instance;
    MtlsProxy.instance = MtlsProxy();
    await MtlsProxy.instance.load(
      CertificateStore(InMemorySecureKeyValueStore()),
    );
    server = await _TestServer.start();
  });

  tearDown(() async {
    await MtlsProxy.instance.close();
    MtlsProxy.instance = previous;
    await server.close();
  });

  Future<void> install() => MtlsProxy.instance.install(
    'server-1',
    certificate: _clientCertificate(),
    serverUrls: [server.url],
  );

  group('Dart-side requests through the app HttpOverrides', () {
    test('- present the client certificate to the configured server', () async {
      await install();

      final body = await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        try {
          return await _get(client, '${server.url}/Users/Me');
        } finally {
          client.close(force: true);
        }
      }, TrustedCertificateHttpOverrides(CertificateTrust()));

      expect(body, 'hello from /Users/Me');
      expect(server.clientSubjects.single, contains('orpheus-test-client'));
    });

    test('- never present it to another host', () async {
      await install();
      final other = await _TestServer.start(require: false);
      addTearDown(other.close);
      final trust = CertificateTrust();
      final pem = File('$_fixtures/server.pem').readAsStringSync();
      final der = base64Decode(
        pem
            .replaceAll(RegExp('-----[A-Z ]+-----'), '')
            .replaceAll(RegExp(r'\s'), ''),
      );
      await trust.trust(
        ServerCertificate(
          host: '127.0.0.1',
          port: other.port,
          fingerprint: sha256.convert(der).toString(),
          subject: '/CN=localhost',
          issuer: '/CN=Orpheus Test CA',
          validFrom: DateTime.utc(2026),
          validTo: DateTime.utc(2126),
        ),
      );

      final body = await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        try {
          return await _get(client, '${other.url}/x');
        } finally {
          client.close(force: true);
        }
      }, TrustedCertificateHttpOverrides(trust));

      expect(body, 'hello from /x');
      expect(other.clientSubjects.single, isNull);
    });
  });

  group('native consumers', () {
    test('- get a loopback URL for a certificate server only', () async {
      await install();

      final proxied = await downloadUrlFor('${server.url}/Audio/1/universal');
      expect(Uri.parse(proxied).host, '127.0.0.1');
      // The test binding mocks HttpClient globally; a player is a real client.
      final client = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _PlainHttpOverrides(),
      );
      addTearDown(() => client.close(force: true));
      expect(await _get(client, proxied), 'hello from /Audio/1/universal');

      expect(
        await downloadUrlFor('http://192.168.1.10:8096/Audio/1'),
        'http://192.168.1.10:8096/Audio/1',
      );
    });

    test('- play stream and artwork through the proxy', () async {
      await install();

      final (stream, art) = await resolveForMtlsPlayback(
        Uri.parse('${server.url}/Audio/1/stream'),
        Uri.parse('${server.url}/Items/1/Images/Primary'),
      );

      expect(stream.host, '127.0.0.1');
      expect(art?.host, '127.0.0.1');
      expect(needsMtlsProxy(Uri.parse('${server.url}/x')), isTrue);
      expect(needsMtlsProxy(Uri.parse('https://example.net/x')), isFalse);
    });
  });

  test('- Cast and DLNA are blocked for a certificate server only', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(baseUrlProvider.notifier).state = server.url;
    expect(container.read(remotePlaybackBlockedProvider), isNull);

    await install();
    container.invalidate(remotePlaybackBlockedProvider);
    expect(container.read(remotePlaybackBlockedProvider), contains('Cast'));

    container.read(baseUrlProvider.notifier).state = 'https://other.net';
    expect(container.read(remotePlaybackBlockedProvider), isNull);
  });

  test('- a staged certificate is stored once its account exists', () async {
    final storage = _MemorySecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await initOrpheusMtls(container);

    await MtlsProxy.instance.stage(
      certificate: _clientCertificate(),
      serverUrl: server.url,
    );
    container.read(accountsProvider.notifier).state = [
      ServerAccount(
        serverId: 'abc123',
        serverType: ServerType.jellyfin,
        url: server.url,
        userId: 'u',
        token: 't',
        remoteUrl: 'https://remote.example.net',
      ),
    ];
    await pumpEventQueue();

    expect(MtlsProxy.instance.hasStaged, isFalse);
    expect(MtlsProxy.instance.hasCertificate('abc123'), isTrue);
    expect(
      MtlsProxy.instance.appliesToUrl('https://remote.example.net/Items'),
      isTrue,
    );
    expect(storage.values.keys, contains(CertificateStore.indexKey));

    // Removing the account removes its certificate.
    container.read(accountsProvider.notifier).state = const [];
    await pumpEventQueue();
    expect(MtlsProxy.instance.hasCertificate('abc123'), isFalse);
    expect(storage.values[CertificateStore.entryKey('abc123')], isNull);
  });

  group('explainSignInFailure', () {
    test(
      '- suggests importing a certificate when the server wants one',
      () async {
        final message = await explainSignInFailure(
          'Could not connect',
          Uri.parse(server.url),
        );

        expect(message, startsWith('Could not connect'));
        expect(message, contains('client certificate'));
      },
    );

    test('- does not blame a working certificate', () async {
      await install();

      expect(
        await explainSignInFailure('Wrong password', Uri.parse(server.url)),
        'Wrong password',
      );
    });

    test('- blames a certificate the server refuses', () async {
      await MtlsProxy.instance.install(
        'server-1',
        certificate: ClientCertificate(
          pkcs12: _fixture('client_other_ca.p12'),
          password: 'secret',
          caPem: _fixture('ca.pem'),
        ),
        serverUrls: [server.url],
      );

      expect(
        await explainSignInFailure('Could not connect', Uri.parse(server.url)),
        contains('refused the client certificate'),
      );
    });

    test('- leaves other failures alone', () async {
      final open = await _TestServer.start(require: false);
      addTearDown(open.close);

      expect(
        await explainSignInFailure('Wrong password', Uri.parse(open.url)),
        'Wrong password',
      );
      expect(
        await explainSignInFailure(
          'Could not connect',
          Uri.parse('http://192.168.1.10:8096'),
        ),
        'Could not connect',
      );
    });
  });
}
