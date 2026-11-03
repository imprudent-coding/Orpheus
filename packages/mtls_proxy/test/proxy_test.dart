import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

import 'support/test_support.dart';

void main() {
  late MtlsTestServer upstream;
  late MtlsProxy proxy;
  late HttpClient client;
  late InMemorySecureKeyValueStore storage;

  Future<MtlsProxy> newProxy({
    ProxyOptions options = const ProxyOptions(),
    ServerTrust? trust,
  }) async {
    final instance = MtlsProxy(options: options);
    if (trust != null) instance.trust = trust;
    await instance.load(CertificateStore(storage));
    return instance;
  }

  setUp(() async {
    storage = InMemorySecureKeyValueStore();
    upstream = await MtlsTestServer.start();
    proxy = await newProxy();
    await proxy.install(
      'server-1',
      certificate: Fixtures.client(),
      serverUrls: [upstream.url],
    );
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.close();
    await upstream.close();
  });

  Future<Uri> via(String pathAndQuery) =>
      proxy.resolve(upstream.uri(pathAndQuery));

  void answer(String path, String body, {int status = 200}) {
    upstream.handlers[path] = (request) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.text
        ..write(body);
      await request.response.close();
    };
  }

  group('the upstream test server', () {
    test('- refuses clients without a certificate', () async {
      final plain = HttpClient()
        ..badCertificateCallback = (certificate, host, port) => true;
      Object? failure;
      try {
        final response = await send(plain, upstream.uri('/'));
        await response.drain<void>();
      } on Object catch (error) {
        failure = error;
      } finally {
        plain.close(force: true);
      }

      expect(failure, isNotNull);
      expect(
        await ClientCertificateProbe.requiresCertificate(upstream.uri('/')),
        isTrue,
      );
    });

    test('- is told apart from a server without client auth', () async {
      final open = await MtlsTestServer.start(requireClientCertificate: false);
      addTearDown(open.close);

      expect(
        await ClientCertificateProbe.requiresCertificate(open.uri('/')),
        isFalse,
      );
    });
  });

  group('resolve', () {
    test('- routes a configured server through the loopback proxy', () async {
      final proxied = await via('/Items?api_key=abc');

      expect(proxied.scheme, 'http');
      expect(proxied.host, '127.0.0.1');
      expect(proxied.port, proxy.server.port);
      expect(proxied.pathSegments.first, proxy.server.token.value);
      expect(proxied.path, endsWith('/Items'));
      expect(proxied.query, 'api_key=abc');
    });

    test('- leaves every other URL alone', () async {
      for (final url in [
        'https://other.example.net/Items',
        'http://127.0.0.1:${upstream.port}/Items',
        'https://127.0.0.1:${upstream.port + 1}/Items',
        'file:///music/song.flac',
      ]) {
        expect(await proxy.resolveUrl(url), url);
      }
    });

    test('- presents the certificate only to configured hosts', () {
      expect(
        proxy.contextFor('127.0.0.1', upstream.port, pinned: false),
        isNotNull,
      );
      expect(
        proxy.contextFor('127.0.0.1', upstream.port + 1, pinned: false),
        isNull,
      );
      expect(proxy.contextFor('lrclib.net', 443, pinned: false), isNull);
      expect(proxy.contextFor('api.github.com', 443, pinned: false), isNull);
    });
  });

  group('forwarding', () {
    test('- reaches the mTLS server with the client certificate', () async {
      answer('/hello', 'hi there');

      final response = await send(client, await via('/hello'));

      expect(response.statusCode, 200);
      expect(await readText(response), 'hi there');
      expect(upstream.lastClientSubject, contains('orpheus-test-client'));
    });

    test('- forwards method, query, encoded path and body', () async {
      String? seen;
      upstream.handlers['/Items/a%2Fb'] = (request) async {
        final body = await utf8.decodeStream(request);
        seen =
            '${request.method} ${request.uri.path}?${request.uri.query} '
            '$body';
        await request.response.close();
      };

      final response = await send(
        client,
        await via('/Items/a%2Fb?x=1&y=%20z'),
        method: 'POST',
        body: utf8.encode('{"a":1}'),
      );
      await response.drain<void>();

      expect(response.statusCode, 200);
      expect(seen, 'POST /Items/a%2Fb?x=1&y=%20z {"a":1}');
    });

    test('- forwards headers, rewrites Host, strips hop-by-hop', () async {
      late HttpHeaders seen;
      upstream.handlers['/headers'] = (request) async {
        seen = request.headers;
        await request.response.close();
      };

      final response = await send(
        client,
        await via('/headers'),
        headers: {
          'Authorization': 'MediaBrowser Token="t"',
          'X-Emby-Token': 'secret-token',
          'Range': 'bytes=0-99',
          'User-Agent': 'ExoPlayer/2.19',
          'Connection': 'X-Drop-Me',
          'X-Drop-Me': '1',
          'Keep-Alive': 'timeout=5',
          'TE': 'trailers',
          'Proxy-Authorization': 'Basic abc',
          'X-Custom': 'kept',
        },
      );
      await response.drain<void>();

      expect(seen.value('authorization'), 'MediaBrowser Token="t"');
      expect(seen.value('x-emby-token'), 'secret-token');
      expect(seen.value('range'), 'bytes=0-99');
      expect(seen.value('user-agent'), 'ExoPlayer/2.19');
      expect(seen.value('x-custom'), 'kept');
      expect(seen.value('host'), '127.0.0.1:${upstream.port}');
      expect(seen.value('x-drop-me'), isNull);
      expect(seen.value('keep-alive'), isNull);
      expect(seen.value('te'), isNull);
      expect(seen.value('proxy-authorization'), isNull);
      // The proxy adds no compression the player did not ask for.
      expect(seen.value('accept-encoding'), isNull);
    });

    test('- passes status codes and response headers through', () async {
      upstream.handlers['/missing'] = (request) async {
        request.response
          ..statusCode = 404
          ..headers.set('X-Upstream', 'yes')
          ..write('nope');
        await request.response.close();
      };

      final response = await send(client, await via('/missing'));

      expect(response.statusCode, 404);
      expect(response.headers.value('x-upstream'), 'yes');
      expect(await readText(response), 'nope');
    });

    test('- answers HEAD with the upstream headers and no body', () async {
      upstream.handlers['/Audio/2/stream'] = (request) async {
        request.response
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..headers.set('Accept-Ranges', 'bytes')
          ..contentLength = 4096;
        if (request.method != 'HEAD') request.response.add(Uint8List(4096));
        await request.response.close();
      };

      final response = await send(
        client,
        await via('/Audio/2/stream'),
        method: 'HEAD',
      );
      final body = await response.fold<int>(0, (n, chunk) => n + chunk.length);

      expect(response.statusCode, 200);
      expect(response.contentLength, 4096);
      expect(response.headers.value('accept-ranges'), 'bytes');
      expect(body, 0);
    });

    test('- serves byte ranges with 206 and their headers', () async {
      final file = Uint8List.fromList(
        List.generate(1 << 20, (i) => (i * 31) & 0xff),
      );
      upstream.handlers['/Audio/1/stream'] = (request) async {
        final range = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(request.headers.value('range') ?? '');
        final response = request.response
          ..headers.set('Accept-Ranges', 'bytes')
          ..headers.contentType = ContentType('audio', 'flac');
        if (range == null) {
          response
            ..contentLength = file.length
            ..add(file);
        } else {
          final start = int.parse(range.group(1)!);
          final end = int.parse(range.group(2)!);
          response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(
              'Content-Range',
              'bytes $start-$end/${file.length}',
            )
            ..contentLength = end - start + 1
            ..add(file.sublist(start, end + 1));
        }
        await response.close();
      };

      final response = await send(
        client,
        await via('/Audio/1/stream'),
        headers: {'Range': 'bytes=1000-1999'},
      );
      final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));

      expect(response.statusCode, 206);
      expect(
        response.headers.value('content-range'),
        'bytes 1000-1999/${file.length}',
      );
      expect(response.headers.value('accept-ranges'), 'bytes');
      expect(response.headers.contentType?.mimeType, 'audio/flac');
      expect(response.contentLength, 1000);
      expect(body, file.sublist(1000, 2000));
    });

    test('- streams responses without buffering them', () async {
      final release = Completer<void>();
      final first = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 7);
      upstream.handlers['/stream'] = (request) async {
        final response = request.response
          ..bufferOutput = false
          ..contentLength = first.length * 2
          ..add(first);
        await response.flush();
        await release.future;
        response.add(first);
        await response.close();
      };

      final response = await send(client, await via('/stream'));
      final chunks = StreamIterator(response);
      var received = 0;
      while (received < first.length) {
        // Every byte of the first half arrives while the upstream still holds
        // back the second half: nothing waits for the whole body.
        expect(
          await chunks.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        received += chunks.current.length;
      }
      expect(release.isCompleted, isFalse);

      release.complete();
      while (await chunks.moveNext()) {
        received += chunks.current.length;
      }
      expect(received, first.length * 2);
    });

    test('- streams request bodies without buffering them', () async {
      final firstSeen = Completer<void>();
      final total = Completer<int>();
      upstream.handlers['/upload'] = (request) async {
        var length = 0;
        await for (final chunk in request) {
          length += chunk.length;
          if (!firstSeen.isCompleted) firstSeen.complete();
        }
        total.complete(length);
        await request.response.close();
      };

      final request = await client.postUrl(await via('/upload'));
      request.headers.chunkedTransferEncoding = true;
      request.add(Uint8List(32 * 1024));
      await request.flush();
      // The upstream sees the first chunk before the upload is finished.
      await firstSeen.future.timeout(const Duration(seconds: 5));
      request.add(Uint8List(32 * 1024));
      final response = await request.close();
      await response.drain<void>();

      expect(await total.future, 64 * 1024);
    });

    test('- answers 502 when the server cannot be reached', () async {
      await upstream.close();

      final response = await send(client, await via('/gone'));

      expect(response.statusCode, 502);
      expect(await readText(response), isNot(contains('127.0.0.1')));
    });
  });

  group('redirects and playlists', () {
    test(
      '- points redirects to a configured server back to the proxy',
      () async {
        upstream.handlers['/moved'] = (request) async {
          request.response
            ..statusCode = 302
            ..headers.set('Location', '${upstream.url}/new/place?x=1');
          await request.response.close();
        };

        final response = await send(client, await via('/moved'));
        await response.drain<void>();

        expect(response.statusCode, 302);
        expect(
          response.headers.value('location'),
          (await via('/new/place?x=1')).toString(),
        );
      },
    );

    test('- leaves redirects elsewhere and relative ones alone', () async {
      upstream.handlers['/away'] = (request) async {
        request.response
          ..statusCode = 302
          ..headers.set('Location', 'https://cdn.example.net/file');
        await request.response.close();
      };
      upstream.handlers['/relative'] = (request) async {
        request.response
          ..statusCode = 301
          ..headers.set('Location', '/elsewhere');
        await request.response.close();
      };

      final away = await send(client, await via('/away'));
      final relative = await send(client, await via('/relative'));
      await away.drain<void>();
      await relative.drain<void>();

      expect(away.headers.value('location'), 'https://cdn.example.net/file');
      expect(relative.headers.value('location'), '/elsewhere');
    });

    test('- rewrites absolute playlist URLs of configured servers', () async {
      upstream.handlers['/master.m3u8'] = (request) async {
        request.response
          ..headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          )
          ..write(
            '#EXTM3U\n'
            '#EXT-X-MAP:URI="${upstream.url}/init.mp4"\n'
            '${upstream.url}/seg0.ts?api_key=k\n'
            'seg1.ts\n'
            'https://cdn.example.net/seg2.ts\n',
          );
        await request.response.close();
      };

      final response = await send(client, await via('/master.m3u8'));
      final lines = const LineSplitter().convert(await readText(response));

      expect(lines[1], '#EXT-X-MAP:URI="${await via('/init.mp4')}"');
      expect(lines[2], '${await via('/seg0.ts?api_key=k')}');
      expect(lines[3], 'seg1.ts');
      expect(lines[4], 'https://cdn.example.net/seg2.ts');
    });
  });

  group('access control', () {
    Uri withToken(Uri proxied, String token) {
      final segments = [...proxied.pathSegments]..[0] = token;
      return proxied.replace(pathSegments: segments);
    }

    test('- rejects requests without the right token with 403', () async {
      answer('/hello', 'secret data');
      final proxied = await via('/hello');
      final token = proxy.server.token.value;
      final origin = 'http://127.0.0.1:${proxy.server.port}';

      for (final uri in [
        Uri.parse('$origin/'),
        Uri.parse('$origin/hello'),
        withToken(proxied, 'x' * token.length),
        withToken(proxied, token.substring(0, token.length - 1)),
        withToken(proxied, '${token}x'),
        withToken(proxied, token.toLowerCase()),
      ]) {
        final response = await send(client, uri);
        expect(response.statusCode, 403, reason: '$uri');
        expect(await readText(response), isNot(contains('secret data')));
      }
      expect(upstream.requests, isEmpty);
    });

    test(
      '- refuses connections for a cooldown after repeated bad tokens',
      () async {
        await proxy.close();
        proxy = await newProxy(
          options: const ProxyOptions(
            maxInvalidRequests: 3,
            cooldown: Duration(milliseconds: 600),
          ),
        );
        await proxy.install(
          'server-1',
          certificate: Fixtures.client(),
          serverUrls: [upstream.url],
        );
        answer('/hello', 'ok');
        final good = await via('/hello');
        final bad = good.replace(pathSegments: ['nope', 'x']);

        for (var i = 0; i < 3; i++) {
          final response = await send(client, bad);
          await response.drain<void>();
          expect(response.statusCode, 403);
        }

        // Even the right token is refused while the cooldown lasts: the
        // listener drops new connections before reading a byte.
        final fresh = HttpClient();
        await expectLater(
          () async => (await send(fresh, good)).drain<void>(),
          throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
        );
        fresh.close(force: true);

        await Future<void>.delayed(const Duration(milliseconds: 700));
        final after = HttpClient();
        final response = await send(after, good);
        expect(response.statusCode, 200);
        expect(await readText(response), 'ok');
        after.close(force: true);
      },
    );

    test('- 404s an unknown route behind a valid token', () async {
      final proxied = await via('/hello');
      final segments = [...proxied.pathSegments]..[1] = 'unknown';

      final response = await send(
        client,
        proxied.replace(pathSegments: segments),
      );
      await response.drain<void>();

      expect(response.statusCode, 404);
    });

    test('- listens on the loopback interface only', () {
      final proxied = Uri.parse('http://127.0.0.1:${proxy.server.port}');

      expect(proxied.host, InternetAddress.loopbackIPv4.address);
    });
  });

  group('WebSocket', () {
    test('- bridges both directions and the close', () async {
      upstream.handlers['/socket'] = (request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          if (message == 'bye') {
            unawaited(socket.close(4001, 'upstream says bye'));
          } else {
            socket.add(message);
          }
        });
      };

      final address = await proxy.resolve(
        Uri.parse('wss://127.0.0.1:${upstream.port}/socket?api_key=k'),
      );
      expect(address.scheme, 'ws');

      final socket = await WebSocket.connect(address.toString());
      final messages = StreamIterator(socket);

      socket.add('hello');
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, 'hello');

      socket.add([1, 2, 3]);
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, [1, 2, 3]);

      socket.add('bye');
      expect(await messages.moveNext(), isFalse);
      expect(socket.closeCode, 4001);
      expect(upstream.lastClientSubject, contains('orpheus-test-client'));
    });
  });

  group('lifecycle', () {
    test('- restarts on the same port after the listener died', () async {
      answer('/hello', 'back');
      final before = await via('/hello');

      await proxy.server.simulateDeath();
      await proxy.ensureRunning(force: true);

      final after = await via('/hello');
      expect(after, before);
      final response = await send(HttpClient(), after);
      expect(await readText(response), 'back');
    });

    test('- starts again on demand after being closed', () async {
      answer('/hello', 'again');
      await proxy.server.close();
      expect(proxy.server.isRunning, isFalse);

      final response = await send(client, await via('/hello'));

      expect(await readText(response), 'again');
    });

    test('- detects a dead listener in a health check', () async {
      await proxy.server.simulateDeath();

      await proxy.server.ensureRunning(force: true);

      expect(proxy.server.isRunning, isTrue);
      expect(
        (await send(client, await via('/missing'))).statusCode,
        404,
      );
    });

    test('- stops when the last certificate is removed', () async {
      await proxy.remove('server-1');

      expect(proxy.server.isRunning, isFalse);
      expect(await proxy.resolveUrl('${upstream.url}/a'), '${upstream.url}/a');
      expect(await CertificateStore(storage).loadAll(), isEmpty);
    });

    test('- reloads stored connections at launch', () async {
      final relaunched = await newProxy();
      addTearDown(relaunched.close);

      expect(relaunched.hasCertificate('server-1'), isTrue);
      expect(relaunched.server.isRunning, isTrue);
      expect(relaunched.appliesToUrl('${upstream.url}/x'), isTrue);
      expect(
        relaunched.server.token.value,
        isNot(proxy.server.token.value),
      );
    });
  });

  group('connections', () {
    test('- keeps a staged certificate in memory until committed', () async {
      await proxy.remove('server-1');
      await proxy.stage(
        certificate: Fixtures.client(),
        serverUrl: upstream.url,
      );
      answer('/hello', 'staged');

      expect(await readText(await send(client, await via('/hello'))), 'staged');
      expect(await CertificateStore(storage).loadAll(), isEmpty);

      await proxy.commitStaged('server-9', [upstream.url]);

      expect(proxy.hasStaged, isFalse);
      expect(
        (await CertificateStore(storage).loadAll()).single.id,
        'server-9',
      );
    });

    test('- serves several servers with different certificates', () async {
      final other = await MtlsTestServer.start(clientCa: 'other_ca.pem');
      addTearDown(other.close);
      await proxy.install(
        'server-2',
        certificate: Fixtures.client(file: 'client_other_ca.p12'),
        serverUrls: [other.url],
      );
      answer('/who', 'one');
      other.handlers['/who'] = (request) async {
        request.response.write('two');
        await request.response.close();
      };

      final first = await send(client, await via('/who'));
      final second = await send(
        client,
        await proxy.resolve(other.uri('/who')),
      );

      expect(await readText(first), 'one');
      expect(await readText(second), 'two');
      expect(other.lastClientSubject, contains('orpheus-other-client'));
      expect(upstream.lastClientSubject, contains('orpheus-test-client'));
    });

    test('- covers every address of a connection', () async {
      await proxy.setServerUrls('server-1', [
        'https://home.example.net',
        upstream.url,
      ]);

      expect(proxy.appliesToUrl('https://home.example.net/Items'), isTrue);
      expect(proxy.appliesToUrl('${upstream.url}/Items'), isTrue);
      expect(proxy.connectionIdFor(upstream.uri('/')), 'server-1');
      expect(
        (await CertificateStore(storage).load('server-1'))?.serverUrls,
        ['https://home.example.net', upstream.url],
      );
    });
  });

  group('server trust', () {
    late MtlsTestServer selfSigned;

    setUp(() async {
      selfSigned = await MtlsTestServer.start(
        certificate: 'self_signed.pem',
        key: 'self_signed.key',
      );
      selfSigned.handlers['/x'] = (request) async {
        request.response.write('trusted');
        await request.response.close();
      };
    });

    tearDown(() => selfSigned.close());

    Future<HttpClientResponse> fetchWith(ServerTrust trust) async {
      final instance = await newProxy(trust: trust);
      addTearDown(instance.close);
      await instance.install(
        'self-signed',
        certificate: Fixtures.client(withCa: false),
        serverUrls: [selfSigned.url],
      );
      return send(client, await instance.resolve(selfSigned.uri('/x')));
    }

    test('- refuses an untrusted server certificate', () async {
      expect((await fetchWith(const StrictServerTrust())).statusCode, 502);
    });

    test('- accepts a certificate the user trusted', () async {
      final response = await fetchWith(FixtureTrust(allowUntrusted: true));

      expect(response.statusCode, 200);
      expect(await readText(response), 'trusted');
    });

    test('- accepts a pinned certificate that matches its pin', () async {
      final response = await fetchWith(
        FixtureTrust(pinnedPem: Fixtures.text('self_signed.pem')),
      );

      expect(response.statusCode, 200);
    });

    test('- refuses a pinned host presenting another certificate', () async {
      final response = await fetchWith(
        FixtureTrust(pinnedPem: Fixtures.text('server.pem')),
      );

      expect(response.statusCode, 502);
    });
  });
}
