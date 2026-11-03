import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

import 'support/test_support.dart';

void main() {
  late InMemorySecureKeyValueStore storage;
  late CertificateStore store;

  setUp(() {
    storage = InMemorySecureKeyValueStore();
    store = CertificateStore(storage);
  });

  StoredConnection connection(
    String id, {
    List<String> urls = const ['https://music.example.net'],
  }) => StoredConnection(
    id: id,
    certificate: Fixtures.client(),
    serverUrls: urls,
  );

  test('- round-trips a connection with its CA and URLs', () async {
    await store.save(
      connection(
        'server-1',
        urls: ['https://music.example.net', 'https://100.64.0.5:8920'],
      ),
    );

    final loaded = await CertificateStore(storage).loadAll();

    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'server-1');
    expect(loaded.single.certificate, Fixtures.client());
    expect(loaded.single.serverUrls, [
      'https://music.example.net',
      'https://100.64.0.5:8920',
    ]);
  });

  test('- keeps one entry per connection and replaces on save', () async {
    await store.save(connection('a'));
    await store.save(connection('b'));
    await store.save(
      connection('a', urls: ['https://new.example.net']),
    );

    final loaded = await store.loadAll();

    expect(loaded.map((c) => c.id), ['a', 'b']);
    expect(loaded.first.serverUrls, ['https://new.example.net']);
  });

  test('- removes a connection and its secrets', () async {
    await store.save(connection('a'));
    await store.save(connection('b'));

    await store.remove('a');

    expect((await store.loadAll()).map((c) => c.id), ['b']);
    expect(storage.values.containsKey(CertificateStore.entryKey('a')), isFalse);
  });

  test('- skips a damaged entry instead of failing', () async {
    await store.save(connection('a'));
    await store.save(connection('b'));
    storage.values[CertificateStore.entryKey('a')] = '{not json';

    expect((await store.loadAll()).map((c) => c.id), ['b']);
  });

  test('- stores the secrets only under its own secure keys', () async {
    await store.save(connection('server/with odd:chars'));

    expect(
      storage.values.keys,
      unorderedEquals([
        CertificateStore.indexKey,
        CertificateStore.entryKey('server/with odd:chars'),
      ]),
    );
    final entry =
        jsonDecode(
              storage.values[CertificateStore.entryKey(
                'server/with odd:chars',
              )]!,
            )
            as Map<String, dynamic>;
    expect(
      base64Decode(entry['p12'] as String),
      Uint8List.fromList(Fixtures.bytes('client.p12')),
    );
    expect(entry['password'], Fixtures.password);
  });

  test('- never prints secrets', () {
    final printed = connection('a').toString();

    expect(printed, isNot(contains(Fixtures.password)));
    expect(printed, contains('redacted'));
  });
}
