// ORPHEUS: the Lyra request page and settings section, rendered against a
// fake client.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_client.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_page.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_providers.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_settings.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_wrapper.dart';

class _FakeClient extends LyraClient {
  _FakeClient() : super(Uri.parse('https://lyra.example.com/'));

  final searches = <(String, String, String)>[];
  final requested = <String>[];
  LyraException? requestError;

  @override
  Future<LyraInfo> info() async => const LyraInfo(
    apiVersion: 1,
    sources: ['qobuz', 'deezer'],
    searchTypes: ['album', 'track', 'playlist', 'artist'],
    artistDownloads: false,
    defaultQuality: {'qobuz': 'FLAC 24/96'},
  );

  @override
  Future<List<LyraSearchResult>> search(
    String query, {
    required String source,
    required String type,
  }) async {
    searches.add((query, source, type));
    return const [
      LyraSearchResult(
        id: '1',
        source: 'qobuz',
        type: 'album',
        title: 'Kid A',
        artist: 'Radiohead',
        url: 'https://open.qobuz.com/album/1',
      ),
    ];
  }

  @override
  Future<String?> artwork(LyraSearchResult result) async => null;

  @override
  Future<LyraRequest> request(
    LyraSearchResult result, {
    String? coverUrl,
  }) async {
    if (requestError case final error?) throw error;
    requested.add(result.url);
    return LyraRequest(
      id: 'dl_1',
      url: result.url,
      status: LyraRequestStatus.queued,
    );
  }
}

const _queue = LyraRequests(
  active: [
    LyraRequest(
      id: 'dl_2',
      url: 'https://open.qobuz.com/album/2',
      status: LyraRequestStatus.downloading,
      title: 'OK Computer',
      artist: 'Radiohead',
    ),
  ],
  recent: [
    LyraRequest(
      id: 'dl_1',
      url: 'https://open.qobuz.com/album/1',
      status: LyraRequestStatus.completed,
      title: 'Kid A',
      artist: 'Radiohead',
    ),
    LyraRequest(
      id: 'dl_0',
      url: 'https://open.qobuz.com/album/0',
      status: LyraRequestStatus.failed,
      title: 'Amnesiac',
      error: 'Streamrip could not complete the download',
    ),
  ],
);

void main() {
  late _FakeClient client;

  ProviderContainer container({Uri? lyraUrl}) {
    final container = ProviderContainer(
      overrides: [
        lyraUrlProvider.overrideWithValue(lyraUrl),
        lyraClientProvider.overrideWithValue(lyraUrl == null ? null : client),
        lyraRequestsProvider.overrideWith((ref) => Stream.value(_queue)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => client = _FakeClient());

  testWidgets('- asks for an address when none is set', (tester) async {
    await tester.pumpWidget(
      createTestApp(providerContainer: container(), home: const LyraPage()),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Settings > Lyra'), findsOneWidget);
  });

  testWidgets('- searches and requests a release', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        providerContainer: container(
          lyraUrl: Uri.parse('https://lyra.example.com/'),
        ),
        home: const LyraPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Downloads in FLAC 24/96.'), findsOneWidget);
    // Artists only when Lyra allows public artist downloads.
    expect(find.widgetWithText(ChoiceChip, 'Albums'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Artists'), findsNothing);

    await tester.enterText(find.byType(TextField), 'kid a');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(client.searches, [('kid a', 'qobuz', 'album')]);
    expect(find.text('Kid A'), findsOneWidget);
    expect(find.text('Radiohead · Qobuz'), findsOneWidget);

    await tester.tap(find.byTooltip('Request'));
    await tester.pumpAndSettle();
    expect(client.requested, ['https://open.qobuz.com/album/1']);
    expect(find.byTooltip('Requested'), findsOneWidget);
    expect(find.text('Requested "Kid A"'), findsOneWidget);

    // Another type searches again with the same query.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Tracks'));
    await tester.pumpAndSettle();
    expect(client.searches.last, ('kid a', 'qobuz', 'track'));
  });

  testWidgets("- shows Lyra's refusal of a request", (tester) async {
    client.requestError = const LyraException('Not allowed here');
    await tester.pumpWidget(
      createTestApp(
        providerContainer: container(
          lyraUrl: Uri.parse('https://lyra.example.com/'),
        ),
        home: const LyraPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'kid a');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Request'));
    await tester.pumpAndSettle();
    expect(find.text('Not allowed here'), findsOneWidget);
    expect(find.byTooltip('Request'), findsOneWidget);
  });

  testWidgets('- lists requests with their status', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        providerContainer: container(
          lyraUrl: Uri.parse('https://lyra.example.com/'),
        ),
        home: const LyraPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Requests'));
    // The downloading spinner never settles; the stream needs a few frames.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('Radiohead · Downloading'), findsOneWidget);
    expect(
      find.text('Radiohead · Downloaded, waiting for import'),
      findsOneWidget,
    );
    expect(
      find.text('Failed: Streamrip could not complete the download'),
      findsOneWidget,
    );
  });

  testWidgets('- settings validate, save and remove the address', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentServerIdProvider.notifier).state = 'server-1';
    await tester.pumpWidget(
      createTestApp(
        providerContainer: container,
        home: const Scaffold(
          body: SingleChildScrollView(child: LyraSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Request music'), findsNothing);

    await tester.enterText(find.byType(TextField), 'ftp://nope');
    await tester.tap(find.text('Save and test'));
    await tester.pumpAndSettle();
    expect(find.text('This is not a valid http(s) address.'), findsOneWidget);
    expect(container.read(lyraUrlProvider), isNull);

    // Saving stores the address even when the test cannot reach Lyra (the
    // test environment answers every HTTP request with 400).
    await tester.enterText(find.byType(TextField), 'lyra.example.com');
    await tester.runAsync(() async {
      await tester.tap(find.text('Save and test'));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
    expect(
      container.read(lyraUrlProvider),
      Uri.parse('https://lyra.example.com/'),
    );
    expect(find.text('https://lyra.example.com/'), findsOneWidget);
    expect(find.text('Request music'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(container.read(lyraUrlProvider), isNull);
    expect(find.text('Request music'), findsNothing);
  });
}
