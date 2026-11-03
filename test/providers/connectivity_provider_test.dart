import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/core/network/certificate_trust.dart';
import 'package:jplayer/src/data/backend/media_server_client.dart';
import 'package:jplayer/src/data/providers/providers.dart';
import 'package:jplayer/src/domain/providers/current_user_provider.dart';
import 'package:jplayer/src/providers/base_url_provider.dart';
import 'package:jplayer/src/providers/connectivity_provider.dart';
import 'package:jplayer/src/providers/server_addresses_provider.dart';
import 'package:mocktail/mocktail.dart';

import '../provider_container.dart';

class _MockMediaServerClient extends Mock implements MediaServerClient {}

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

class _Hosts implements HttpClientAdapter {
  final status = <String, int>{};
  Duration delay = Duration.zero;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final code = status[options.uri.host];
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    if (code == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'unreachable',
      );
    }
    return ResponseBody.fromString('', code);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const home = 'http://192.168.1.10:8096';
  const remote = 'http://100.64.0.5:8096';

  late _Hosts hosts;
  late _MockMediaServerClient client;
  late _MockSecureStorage storage;
  late CertificateTrust trust;
  late int proberBuilds;

  setUp(() {
    hosts = _Hosts();
    proberBuilds = 0;
    client = _MockMediaServerClient();
    storage = _MockSecureStorage();
    trust = CertificateTrust();
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => storage.delete(key: any(named: 'key')),
    ).thenAnswer((_) async {});
  });

  ProviderContainer start({
    String? knownRemote,
    bool signedIn = true,
    Duration heartbeat = const Duration(hours: 1),
    Duration offlineGrace = Duration.zero,
  }) {
    final container = createProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        certificateTrustProvider.overrideWithValue(trust),
        mediaServerClientProvider.overrideWithValue(client),
        connectivityProvider.overrideWith(
          (ref) => ConnectivityNotifier(
            ref,
            probeClient: () {
              proberBuilds++;
              return Dio()..httpClientAdapter = hosts;
            },
            heartbeat: heartbeat,
            offlineGrace: offlineGrace,
          ),
        ),
      ],
    );
    if (signedIn) {
      container.read(currentUserProvider.notifier).state = const User(
        userId: 'u',
        token: 't',
      );
    }
    container.read(baseUrlProvider.notifier).state = home;
    container.read(serverAddressesProvider.notifier).state = ServerAddresses(
      home: home,
      remote: knownRemote,
    );
    container.read(dioProvider).httpClientAdapter = hosts;
    container.read(connectivityProvider);
    return container;
  }

  Future<bool> probe(ProviderContainer container) =>
      container.read(connectivityProvider.notifier).refresh();

  // ORPHEUS: these tests used to fail over to the JellyBox relay. The relay is
  // removed, so failover is exercised with the manual remote address instead.
  test('- stays on the home address while it answers', () async {
    hosts.status['192.168.1.10'] = 200;
    hosts.status['100.64.0.5'] = 200;
    final container = start(knownRemote: remote);

    expect(await probe(container), isTrue);
    expect(container.read(baseUrlProvider), home);
  });

  test(
    '- falls back to the remote address when home does not answer',
    () async {
      hosts.status['100.64.0.5'] = 200;
      final container = start(knownRemote: remote);

      expect(await probe(container), isTrue);
      expect(container.read(baseUrlProvider), remote);
    },
  );

  test('- is offline when no address answers', () async {
    final container = start(knownRemote: remote);

    expect(await probe(container), isFalse);
    expect(container.read(baseUrlProvider), home);
  });

  test('- goes back home as soon as home answers again', () async {
    hosts.status['100.64.0.5'] = 200;
    final container = start(knownRemote: remote);
    await probe(container);
    expect(container.read(baseUrlProvider), remote);

    hosts.status['192.168.1.10'] = 200;
    await probe(container);

    expect(container.read(baseUrlProvider), home);
  });

  test('- tells direct, remote and offline apart', () async {
    hosts.status['192.168.1.10'] = 200;
    final container = start(knownRemote: remote)
      ..listen(serverConnectionProvider, (_, _) {});

    await probe(container);
    expect(container.read(serverConnectionProvider), ServerConnection.direct);

    hosts.status
      ..remove('192.168.1.10')
      ..['100.64.0.5'] = 200;
    await probe(container);
    expect(container.read(serverConnectionProvider), ServerConnection.remote);

    hosts.status.remove('100.64.0.5');
    await probe(container);
    expect(container.read(serverConnectionProvider), ServerConnection.offline);
  });

  test(
    '- notices home going away on its own, without a network event',
    () async {
      hosts.status['192.168.1.10'] = 200;
      hosts.status['100.64.0.5'] = 200;
      final container = start(
        knownRemote: remote,
        heartbeat: const Duration(milliseconds: 20),
      );
      await probe(container);
      expect(container.read(baseUrlProvider), home);

      hosts.status.remove('192.168.1.10');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(container.read(baseUrlProvider), remote);
    },
  );

  test('- shrugs off a single failed round while it is online', () async {
    hosts.status['192.168.1.10'] = 200;
    final container = start(
      knownRemote: remote,
      offlineGrace: const Duration(milliseconds: 300),
    );
    await probe(container);
    expect(container.read(connectivityProvider), isTrue);

    hosts.status.clear();
    expect(await probe(container), isTrue);
    expect(container.read(connectivityProvider), isTrue);

    hosts.status['100.64.0.5'] = 200;
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(container.read(connectivityProvider), isTrue);
    expect(container.read(baseUrlProvider), remote);
  });

  test('- goes offline once a second round confirms it', () async {
    hosts.status['192.168.1.10'] = 200;
    final container = start(
      knownRemote: remote,
      offlineGrace: const Duration(milliseconds: 200),
    );
    await probe(container);

    hosts.status.clear();
    expect(await probe(container), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(container.read(connectivityProvider), isFalse);
  });

  test('- runs one more round when a refresh arrives mid-round', () async {
    hosts.status['192.168.1.10'] = 200;
    final container = start();
    await probe(container);

    hosts.delay = const Duration(milliseconds: 100);
    hosts.status.remove('192.168.1.10');
    final stale = container.read(connectivityProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    hosts.status['192.168.1.10'] = 200;
    final fresh = container.read(connectivityProvider.notifier).refresh();

    expect(await fresh, isTrue);
    expect(await stale, isTrue);
    expect(container.read(connectivityProvider), isTrue);
    expect(container.read(baseUrlProvider), home);
  });

  test('- keeps one probe client across rounds', () async {
    hosts.status['192.168.1.10'] = 200;
    final container = start(knownRemote: remote);

    await probe(container);
    await probe(container);
    await probe(container);

    expect(proberBuilds, 1);
  });

  test('- treats a block page answering for home as down', () async {
    hosts.status['192.168.1.10'] = 403;
    hosts.status['100.64.0.5'] = 200;
    final container = start(knownRemote: remote);

    expect(await probe(container), isTrue);
    expect(container.read(baseUrlProvider), remote);
  });

  test(
    '- walks a request the block page answered over to the remote address',
    () async {
      hosts.status['192.168.1.10'] = 403;
      hosts.status['100.64.0.5'] = 200;
      final container = start(knownRemote: remote);

      final response = await container
          .read(dioProvider)
          .getUri<void>(Uri.parse('$home/Items'));

      expect(response.realUri.toString(), '$remote/Items');
      expect(container.read(baseUrlProvider), remote);
    },
  );

  test('- retries a request that cannot reach home on the remote', () async {
    hosts.status['192.168.1.10'] = 200;
    hosts.status['100.64.0.5'] = 200;
    final container = start(knownRemote: remote);
    await probe(container);
    hosts.status.remove('192.168.1.10');

    final response = await container
        .read(dioProvider)
        .getUri<void>(Uri.parse('$home/Items?limit=5'));

    expect(response.realUri.toString(), '$remote/Items?limit=5');
    expect(container.read(baseUrlProvider), remote);
  });

  test(
    '- leaves a failed request alone once the remote is known to be down',
    () async {
      hosts.status['192.168.1.10'] = 200;
      final container = start(knownRemote: remote);
      await probe(container);
      hosts.status.remove('192.168.1.10');

      await expectLater(
        container.read(dioProvider).getUri<void>(Uri.parse('$home/Items')),
        throwsA(isA<DioException>()),
      );
      expect(container.read(baseUrlProvider), home);
    },
  );

  test('- counts a redirect as an answer', () async {
    hosts.status['100.64.0.5'] = 302;
    final container = start(knownRemote: remote);

    expect(await probe(container), isTrue);
    expect(container.read(baseUrlProvider), remote);
  });

  test('- tells a remote connection apart from a direct one', () async {
    hosts.status['100.64.0.5'] = 200;
    final container = start(knownRemote: remote)
      ..listen(serverConnectionProvider, (_, _) {});

    await probe(container);
    expect(container.read(serverConnectionProvider), ServerConnection.remote);

    hosts.status['192.168.1.10'] = 200;
    await probe(container);
    expect(container.read(serverConnectionProvider), ServerConnection.direct);
  });

  test('- leaves the remote address alone when home answers', () async {
    hosts.status['192.168.1.10'] = 200;
    hosts.status['100.64.0.5'] = 200;
    final container = start(knownRemote: remote);

    final response = await container
        .read(dioProvider)
        .getUri<void>(Uri.parse('$home/Items'));

    expect(response.realUri.toString(), '$home/Items');
  });

  test('- stores the remote address and probes it at once', () async {
    hosts.status['100.64.0.5'] = 200;
    final container = start();
    await probe(container);
    expect(container.read(connectivityProvider), isFalse);

    await container
        .read(connectivityProvider.notifier)
        .setRemote('100.64.0.5:8096');
    await pumpEventQueue();

    verify(
      () => storage.write(key: remoteUrlStorageKey, value: remote),
    ).called(1);
    expect(container.read(serverAddressesProvider)?.remote, remote);
    expect(container.read(baseUrlProvider), remote);
    expect(container.read(connectivityProvider), isTrue);
  });

  test('- forgets the remote address on request', () async {
    final container = start(knownRemote: remote);

    await container.read(connectivityProvider.notifier).setRemote(null);

    verify(() => storage.delete(key: remoteUrlStorageKey)).called(1);
    expect(container.read(serverAddressesProvider)?.remote, isNull);
  });

  test(
    '- orders stream endpoints: selected, then up, then known down',
    () async {
      hosts.status['100.64.0.5'] = 200;
      final container = start(knownRemote: remote);
      await probe(container);

      expect(container.read(baseUrlProvider), remote);
      expect(
        container.read(connectivityProvider.notifier).liveEndpoints(),
        [remote, home],
      );
    },
  );

  test('- adopts the endpoint a stream got through on', () async {
    final container = start(knownRemote: remote);
    expect(await probe(container), isFalse);
    expect(container.read(baseUrlProvider), home);

    hosts.status['100.64.0.5'] = 200;
    container.read(connectivityProvider.notifier).adopt(remote);

    expect(container.read(baseUrlProvider), remote);
    expect(container.read(connectivityProvider), isTrue);
  });

  test(
    '- streams from the new server right after switching accounts',
    () async {
      hosts.status['100.64.0.5'] = 200;
      final container = start(knownRemote: remote);
      await probe(container);
      expect(container.read(baseUrlProvider), remote);

      const other = 'http://192.168.1.20:4533';
      container.read(serverAddressesProvider.notifier).state = null;
      container.read(baseUrlProvider.notifier).state = other;
      container.read(serverAddressesProvider.notifier).state =
          const ServerAddresses(home: other);

      expect(
        container.read(connectivityProvider.notifier).liveEndpoints(),
        [other],
      );
    },
  );
}
