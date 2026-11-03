import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/config/constants.dart';
import 'package:jplayer/src/core/updates/release_checker.dart';

// ORPHEUS: the checker reads the fork's releases; asset names match the fork's
// release workflows.
const _page = 'https://github.com/imprudent-coding/Orpheus/releases/tag';

Map<String, dynamic> release({
  String tag = 'v1.5.0',
  bool draft = false,
  bool prerelease = false,
  String body = '## Changes\n- Faster',
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'body': body,
  'html_url': '$_page/$tag',
  'assets': [
    {
      'name': 'orpheus-universal.apk',
      'browser_download_url': 'https://example.com/orpheus-universal.apk',
    },
    {
      'name': 'Orpheus-1.5.0.dmg',
      'browser_download_url': 'https://example.com/Orpheus-1.5.0.dmg',
    },
    {
      'name': 'windows-setup.exe',
      'browser_download_url': 'https://example.com/windows-setup.exe',
    },
    {
      'name': 'orpheus-linux-x86_64.AppImage',
      'browser_download_url':
          'https://example.com/orpheus-linux-x86_64.AppImage',
    },
  ],
};

AvailableUpdate? parse(
  Map<String, dynamic> data, {
  required DownloadPlatform platform,
  String current = '1.4.2',
}) => ReleaseChecker.parseRelease(
  data,
  currentVersion: current,
  platform: platform,
);

/// Answers GitHub API paths from a map and records every request.
class _FakeGitHub implements HttpClientAdapter {
  _FakeGitHub(this.routes);

  final Map<String, (int, Object?)> routes;
  final requested = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    final (status, body) = routes[options.uri.path] ?? (404, {'x': 'y'});
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('compareVersions', () {
    test('orders numerically, not lexically', () {
      expect(ReleaseChecker.compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(ReleaseChecker.compareVersions('1.4.2', '1.4.10'), lessThan(0));
    });

    test('ignores v prefix, build number and missing trailing parts', () {
      expect(ReleaseChecker.compareVersions('v1.4.0+250', '1.4'), 0);
      expect(ReleaseChecker.compareVersions('1.4.1', 'v1.4'), greaterThan(0));
    });
  });

  group('parseRelease', () {
    test('reports a newer release', () {
      final update = parse(release(), platform: DownloadPlatform.linux);
      expect(update?.version, '1.5.0');
    });

    test('ignores the same or an older release', () {
      expect(
        parse(release(tag: 'v1.4.2'), platform: DownloadPlatform.linux),
        isNull,
      );
      expect(
        parse(release(tag: 'v1.3.0'), platform: DownloadPlatform.linux),
        isNull,
      );
    });

    test('ignores drafts and prereleases', () {
      expect(
        parse(release(draft: true), platform: DownloadPlatform.linux),
        isNull,
      );
      expect(
        parse(release(prerelease: true), platform: DownloadPlatform.linux),
        isNull,
      );
    });

    test('links the matching asset per platform', () {
      expect(
        parse(release(), platform: DownloadPlatform.android)?.url.toString(),
        'https://example.com/orpheus-universal.apk',
      );
      expect(
        parse(release(), platform: DownloadPlatform.macos)?.url.toString(),
        'https://example.com/Orpheus-1.5.0.dmg',
      );
      expect(
        parse(release(), platform: DownloadPlatform.windows)?.url.toString(),
        'https://example.com/windows-setup.exe',
      );
    });

    test('links the release page on Linux', () {
      expect(
        parse(release(), platform: DownloadPlatform.linux)?.url.toString(),
        '$_page/v1.5.0',
      );
    });

    test('falls back to the release page when the asset is missing', () {
      final data = release()..['assets'] = <Object>[];
      expect(
        parse(data, platform: DownloadPlatform.android)?.url.toString(),
        '$_page/v1.5.0',
      );
    });
  });

  group('against a mocked GitHub Releases API', () {
    late _FakeGitHub github;

    ReleaseChecker checker() =>
        ReleaseChecker(dio: Dio()..httpClientAdapter = github);

    test('targets the fork, never upstream', () async {
      expect(ReleaseChecker.defaultRepository, orpheusGitHubRepository);
      expect(orpheusGitHubRepository, 'imprudent-coding/Orpheus');

      github = _FakeGitHub({
        '/repos/imprudent-coding/Orpheus/releases/latest': (200, release()),
      });

      final update = await checker().check(
        currentVersion: '1.4.2',
        platform: DownloadPlatform.android,
      );

      expect(update?.version, '1.5.0');
      expect(
        update?.url.toString(),
        'https://example.com/orpheus-universal.apk',
      );
      expect(github.requested.single.host, 'api.github.com');
      expect(
        github.requested.single.path,
        '/repos/imprudent-coding/Orpheus/releases/latest',
      );
    });

    test('reports nothing when the latest release is not newer', () async {
      github = _FakeGitHub({
        '/repos/imprudent-coding/Orpheus/releases/latest': (
          200,
          release(tag: 'v1.4.2'),
        ),
      });

      final update = await checker().check(
        currentVersion: '1.4.2',
        platform: DownloadPlatform.macos,
      );

      expect(update, isNull);
    });

    test('reads the notes of the installed version', () async {
      github = _FakeGitHub({
        '/repos/imprudent-coding/Orpheus/releases/tags/v1.4.2': (
          200,
          release(tag: 'v1.4.2', body: '  Fixed playback  '),
        ),
      });

      final notes = await checker().notes(version: '1.4.2+130');

      expect(notes?.version, '1.4.2');
      expect(notes?.body, 'Fixed playback');
      expect(notes?.page.toString(), '$_page/v1.4.2');
    });

    test(
      'falls back to the latest notes when the tag has no release',
      () async {
        github = _FakeGitHub({
          '/repos/imprudent-coding/Orpheus/releases/latest': (200, release()),
        });

        final notes = await checker().notes(version: '9.9.9');

        expect(notes?.version, '1.5.0');
        expect(github.requested.map((uri) => uri.path), [
          '/repos/imprudent-coding/Orpheus/releases/tags/v9.9.9',
          '/repos/imprudent-coding/Orpheus/releases/latest',
        ]);
      },
    );
  });
}
