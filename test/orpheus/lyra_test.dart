// ORPHEUS: Lyra (music requests): API client, settings storage, and the
// client certificate shared with the media server.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/providers/shared_preferences_provider.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_client.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_providers.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:mtls_proxy/mtls_proxy.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixtures = 'packages/mtls_proxy/test/fixtures';

Uint8List _fixture(String name) => File('$_fixtures/$name').readAsBytesSync();

/// A plain HTTP stand-in for Lyra that records requests and answers from
/// [handlers] by path.
class _FakeLyra {
  _FakeLyra._(this._server) {
    _server.listen((request) async {
      final body = await utf8.decodeStream(request);
      received.add((
        request.method,
        request.uri,
        body.isEmpty ? null : jsonDecode(body),
      ));
      final handler = handlers[request.uri.path];
      final (status, payload) = handler == null
          ? (404, '<html>not found</html>')
          : handler(request.uri);
      request.response.statusCode = status;
      if (payload is String) {
        request.response.headers.contentType = ContentType.html;
        request.response.write(payload);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(payload));
      }
      await request.response.close();
    });
  }

  static Future<_FakeLyra> start() async =>
      _FakeLyra._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final handlers = <String, (int, Object) Function(Uri uri)>{};
  final received = <(String, Uri, Object?)>[];

  Uri url([String path = '/']) =>
      Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> close() => _server.close(force: true);
}

Map<String, Object?> _request(String id, String status) => {
  'id': id,
  'url': 'https://open.qobuz.com/album/1',
  'status': status,
  'title': 'Kid A',
  'artist': 'Radiohead',
  'service': 'qobuz',
  'cover_url': null,
  'quality': 'FLAC 24/96',
  'queue_position': status == 'queued' ? 1 : null,
  'created_at': 1700000000.5,
  'started_at': null,
  'finished_at': status == 'completed' ? 1700000100 : null,
  'next_allowed_at': null,
  'error': status == 'failed' ? 'Streamrip could not complete the download' : null,
};

void main() {
  group('parseLyraUrl', () {
    test('- adds https and a trailing slash', () {
      expect(
        parseLyraUrl(' lyra.example.com ').toString(),
        'https://lyra.example.com/',
      );
      expect(
        parseLyraUrl('http://nas.local:5002/lyra?x=1#y').toString(),
        'http://nas.local:5002/lyra/',
      );
    });

    test('- rejects empty, non-http and host-less input', () {
      expect(parseLyraUrl(''), isNull);
      expect(parseLyraUrl('ftp://lyra.example.com'), isNull);
      expect(parseLyraUrl('https://'), isNull);
    });
  });

  group('LyraClient', () {
    late _FakeLyra lyra;
    late LyraClient client;

    setUp(() async {
      lyra = await _FakeLyra.start();
      // Lyra under a path prefix: API paths must resolve below it.
      client = LyraClient(lyra.url('/lyra'));
    });

    tearDown(() => lyra.close());

    test('- reads the server info', () async {
      lyra.handlers['/lyra/api/v1/info'] = (_) => (
        200,
        {
          'service': 'lyra',
          'api_version': 1,
          'sources': ['qobuz', 'deezer'],
          'search_types': ['album', 'track'],
          'artist_downloads': false,
          'default_quality': {'qobuz': 'FLAC 24/96', 'deezer': null},
        },
      );
      final info = await client.info();
      expect(info.sources, ['qobuz', 'deezer']);
      expect(info.searchTypes, ['album', 'track']);
      expect(info.artistDownloads, isFalse);
      expect(info.defaultQuality, {'qobuz': 'FLAC 24/96'});
    });

    test('- refuses another API version', () async {
      lyra.handlers['/lyra/api/v1/info'] = (_) => (200, {'api_version': 2});
      await expectLater(
        client.info(),
        throwsA(
          isA<LyraException>().having(
            (error) => error.message,
            'message',
            contains('version 2'),
          ),
        ),
      );
    });

    test('- searches and requests a result', () async {
      lyra.handlers['/lyra/api/v1/search'] = (_) => (
        200,
        {
          'results': [
            {
              'id': '1',
              'source': 'qobuz',
              'type': 'album',
              'title': 'Kid A',
              'artist': 'Radiohead',
              'url': 'https://open.qobuz.com/album/1',
            },
          ],
        },
      );
      lyra.handlers['/lyra/api/v1/requests'] = (_) =>
          (202, {'request': _request('dl_1', 'queued')});

      final results = await client.search(
        'kid a',
        source: 'qobuz',
        type: 'album',
      );
      expect(results.single.title, 'Kid A');
      expect(results.single.artist, 'Radiohead');

      final request = await client.request(
        results.single,
        coverUrl: 'https://img.example/c.jpg',
      );
      expect(request.id, 'dl_1');
      expect(request.status, LyraRequestStatus.queued);
      expect(request.queuePosition, 1);
      expect(request.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000000500));

      expect(lyra.received[0].$3, {
        'query': 'kid a',
        'source': 'qobuz',
        'type': 'album',
      });
      expect(lyra.received[1].$3, {
        'url': 'https://open.qobuz.com/album/1',
        'title': 'Kid A',
        'artist': 'Radiohead',
        'cover_url': 'https://img.example/c.jpg',
      });
    });

    test('- reads artwork and the queue', () async {
      lyra.handlers['/lyra/api/v1/artwork'] = (uri) => (
        200,
        {
          'url': uri.queryParameters['id'] == '1' ? 'https://img/1.jpg' : null,
          'year': null,
          'tracks_count': null,
        },
      );
      lyra.handlers['/lyra/api/v1/requests'] = (_) => (
        200,
        {
          'active': [_request('dl_2', 'downloading')],
          'queued': [_request('dl_3', 'queued')],
          'recent': [_request('dl_1', 'completed'), _request('dl_0', 'failed')],
        },
      );
      const result = LyraSearchResult(
        id: '1',
        source: 'qobuz',
        type: 'album',
        title: 'Kid A',
        url: 'https://open.qobuz.com/album/1',
      );
      expect(await client.artwork(result), 'https://img/1.jpg');
      expect(lyra.received.single.$2.queryParameters, {
        'source': 'qobuz',
        'type': 'album',
        'id': '1',
      });

      final queue = await client.requests();
      expect(queue.all.map((request) => request.id), [
        'dl_2',
        'dl_3',
        'dl_1',
        'dl_0',
      ]);
      expect(queue.recent.first.status.isFinished, isTrue);
      expect(queue.recent.first.finishedAt, isNotNull);
      expect(queue.recent.last.error, contains('Streamrip'));
    });

    test("- reports Lyra's error messages", () async {
      lyra.handlers['/lyra/api/v1/requests'] = (_) => (
        403,
        {'error': 'Whole-artist downloads are not enabled on this server'},
      );
      const artist = LyraSearchResult(
        id: '27',
        source: 'deezer',
        type: 'artist',
        title: 'Daft Punk',
        url: 'https://www.deezer.com/artist/27',
      );
      await expectLater(
        client.request(artist),
        throwsA(
          isA<LyraException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having(
                (error) => error.message,
                'message',
                contains('Whole-artist'),
              ),
        ),
      );
    });

    test('- explains a missing API and a missing client certificate', () async {
      await expectLater(
        client.requests(),
        throwsA(
          isA<LyraException>().having(
            (error) => error.message,
            'message',
            contains('No Lyra app API'),
          ),
        ),
      );
      lyra.handlers['/lyra/api/v1/info'] = (_) => (
        400,
        '<html>400 No required SSL certificate was sent</html>',
      );
      await expectLater(
        client.info(),
        throwsA(
          isA<LyraException>().having(
            (error) => error.message,
            'message',
            contains('client certificate'),
          ),
        ),
      );
    });

    test('- reports an unreachable server', () async {
      await lyra.close();
      await expectLater(client.info(), throwsA(isA<LyraException>()));
    });
  });

  group('Lyra settings', () {
    test('- stores addresses per server and ignores bad entries', () async {
      SharedPreferences.setMockInitialValues({
        LyraUrlsNotifier.prefsKey: jsonEncode({
          'server-1': 'https://lyra.example.com',
          'server-2': 'not a url://',
          'server-3': 42,
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(lyraUrlsProvider, (_, _) {});
      await container.read(sharedPreferencesProvider.future);
      expect(container.read(lyraUrlsProvider), {
        'server-1': Uri.parse('https://lyra.example.com/'),
      });

      container.read(currentServerIdProvider.notifier).state = 'server-1';
      expect(
        container.read(lyraUrlProvider),
        Uri.parse('https://lyra.example.com/'),
      );
      expect(container.read(lyraClientProvider)?.baseUrl.host, 'lyra.example.com');

      await container
          .read(lyraUrlsProvider.notifier)
          .set('server-4', Uri.parse('https://requests.example.com/lyra'));
      await container.read(lyraUrlsProvider.notifier).set('server-1', null);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString(LyraUrlsNotifier.prefsKey)!),
        {'server-4': 'https://requests.example.com/lyra/'},
      );
      expect(container.read(lyraUrlProvider), isNull);
    });

    test("- presents the server's certificate to its Lyra address", () async {
      SharedPreferences.setMockInitialValues({});
      final proxy = MtlsProxy();
      addTearDown(proxy.close);
      await proxy.load(CertificateStore(InMemorySecureKeyValueStore()));
      await proxy.install(
        'server-1',
        certificate: ClientCertificate(
          pkcs12: _fixture('client.p12'),
          password: 'secret',
          caPem: _fixture('ca.pem'),
        ),
        serverUrls: ['https://jellyfin.example.com'],
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      attachLyraCertificates(container, proxy);

      final notifier = container.read(lyraUrlsProvider.notifier);
      await notifier.set('server-1', Uri.parse('https://lyra.example.com'));
      expect(proxy.contextFor('lyra.example.com', 443, pinned: false), isNotNull);
      // Another server's Lyra gets no certificate it does not have.
      await notifier.set('server-2', Uri.parse('https://other.example.com'));
      expect(proxy.contextFor('other.example.com', 443, pinned: false), isNull);

      await notifier.set('server-1', null);
      expect(proxy.contextFor('lyra.example.com', 443, pinned: false), isNull);
      expect(
        proxy.contextFor('jellyfin.example.com', 443, pinned: false),
        isNotNull,
      );
    });
  });
}
