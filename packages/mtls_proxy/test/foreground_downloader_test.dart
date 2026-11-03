import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

import 'support/test_support.dart';

void main() {
  late MtlsTestServer upstream;
  late MtlsProxy proxy;
  late Directory directory;

  setUp(() async {
    upstream = await MtlsTestServer.start();
    proxy = MtlsProxy();
    await proxy.load(CertificateStore(InMemorySecureKeyValueStore()));
    await proxy.install(
      'server-1',
      certificate: Fixtures.client(),
      serverUrls: [upstream.url],
    );
    directory = await Directory.systemTemp.createTemp('mtls_download');
  });

  tearDown(() async {
    await proxy.close();
    await upstream.close();
    await directory.delete(recursive: true);
  });

  test('- downloads with the client certificate, reporting progress', () async {
    final file = Uint8List.fromList(List.generate(300000, (i) => i & 0xff));
    upstream.handlers['/song.flac'] = (request) async {
      request.response
        ..contentLength = file.length
        ..add(file);
      await request.response.close();
    };
    final progress = <double>[];
    final target = '${directory.path}/album/song.flac';

    final done = await ForegroundDownloader(proxy.createHttpClient).download(
      upstream.uri('/song.flac'),
      target,
      onProgress: progress.add,
    );

    expect(done, isTrue);
    expect(File(target).readAsBytesSync(), file);
    expect(File('$target.part').existsSync(), isFalse);
    expect(progress.last, 1);
    expect(upstream.lastClientSubject, contains('orpheus-test-client'));
  });

  test('- fails on an HTTP error without leaving a file behind', () async {
    final target = '${directory.path}/missing.flac';

    await expectLater(
      ForegroundDownloader(proxy.createHttpClient).download(
        upstream.uri('/missing'),
        target,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(File(target).existsSync(), isFalse);
    expect(File('$target.part').existsSync(), isFalse);
  });

  test('- stops when cancelled', () async {
    final release = Completer<void>();
    upstream.handlers['/slow'] = (request) async {
      request.response
        ..bufferOutput = false
        ..contentLength = 2048
        ..add(Uint8List(1024));
      await request.response.flush();
      await release.future;
      request.response.add(Uint8List(1024));
      await request.response.close().catchError((Object _) {});
    };
    final cancel = Completer<void>();
    final target = '${directory.path}/slow.flac';

    final result = ForegroundDownloader(proxy.createHttpClient).download(
      upstream.uri('/slow'),
      target,
      onProgress: (_) {
        if (!cancel.isCompleted) cancel.complete();
      },
      cancel: cancel.future,
    );

    expect(await result, isFalse);
    expect(File(target).existsSync(), isFalse);
    release.complete();
  });

  test('- does not present the certificate to other hosts', () async {
    final unrelated = await MtlsTestServer.start(
      requireClientCertificate: false,
    );
    addTearDown(unrelated.close);
    unrelated.handlers['/x'] = (request) async {
      request.response.write('ok');
      await request.response.close();
    };
    final client = proxy.createHttpClient(
      trust: FixtureTrust(allowUntrusted: true),
    );
    addTearDown(() => client.close(force: true));

    // Same host, other port: not a configured origin, so no certificate.
    final response = await send(client, unrelated.uri('/x'));
    await response.drain<void>();

    expect(response.statusCode, anyOf(200, 404));
    expect(unrelated.requests, isNotEmpty);
    expect(unrelated.lastClientSubject, isNull);
  });
}
