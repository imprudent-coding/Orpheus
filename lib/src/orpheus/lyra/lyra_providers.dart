// ORPHEUS: Lyra settings and state. The Lyra address is set per media server
// account, and Lyra is reached with that server's client certificate.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/providers/shared_preferences_provider.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_client.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

/// Lyra addresses by server account ID.
final lyraUrlsProvider = NotifierProvider<LyraUrlsNotifier, Map<String, Uri>>(
  LyraUrlsNotifier.new,
);

class LyraUrlsNotifier extends Notifier<Map<String, Uri>> {
  static const prefsKey = 'orpheus_lyra_urls';

  @override
  Map<String, Uri> build() {
    final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
    if (prefs == null) return const {};
    return decode(prefs.getString(prefsKey));
  }

  /// Sets (or with null, removes) the Lyra address of [serverId].
  Future<void> set(String serverId, Uri? url) async {
    // Start from what is stored, not from state: before the preferences have
    // loaded, state is still empty.
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final next = {...decode(prefs.getString(prefsKey))};
    if (url == null) {
      next.remove(serverId);
    } else {
      next[serverId] = normalizeLyraUrl(url);
    }
    // Written before state changes, so a rebuild reads the new value too.
    final write = prefs.setString(prefsKey, encode(next));
    state = Map.unmodifiable(next);
    await write;
  }

  static String encode(Map<String, Uri> urls) => jsonEncode({
    for (final MapEntry(:key, :value) in urls.entries) key: value.toString(),
  });

  static Map<String, Uri> decode(String? stored) {
    if (stored == null || stored.isEmpty) return const {};
    try {
      final json = jsonDecode(stored);
      if (json is! Map<String, dynamic>) return const {};
      return Map.unmodifiable({
        for (final MapEntry(:key, :value) in json.entries)
          if (value is String)
            if (parseLyraUrl(value) case final url?) key: url,
      });
    } on FormatException {
      return const {};
    }
  }
}

/// The current server's Lyra address, or null when none is set.
final lyraUrlProvider = Provider<Uri?>((ref) {
  final serverId = ref.watch(currentServerIdProvider);
  if (serverId == null) return null;
  return ref.watch(lyraUrlsProvider)[serverId];
});

/// The current server's Lyra client, or null when no Lyra is set.
final lyraClientProvider = Provider<LyraClient?>((ref) {
  final url = ref.watch(lyraUrlProvider);
  return url == null ? null : LyraClient(url);
});

/// What the current Lyra offers (sources, search types, artist downloads).
final lyraInfoProvider = FutureProvider.autoDispose<LyraInfo>((ref) {
  final client = ref.watch(lyraClientProvider);
  if (client == null) throw const LyraException('No Lyra address is set.');
  return client.info();
});

/// How often the request list refreshes while it is shown.
const lyraPollInterval = Duration(seconds: 5);

/// Lyra's queue, refreshed every [lyraPollInterval] while anything watches
/// it. A failed refresh is reported as an error and retried on the next tick.
final lyraRequestsProvider = StreamProvider.autoDispose<LyraRequests>((
  ref,
) async* {
  final client = ref.watch(lyraClientProvider);
  if (client == null) {
    yield const LyraRequests();
    return;
  }
  while (true) {
    yield await client.requests();
    await Future<void>.delayed(lyraPollInterval);
  }
});

/// Presents each server's client certificate to its Lyra address as well, and
/// keeps that in step with the settings. Called once at startup from
/// initOrpheusMtls. An address only takes effect while its server has a
/// client certificate, and survives the certificate being replaced.
void attachLyraCertificates(ProviderContainer container, MtlsProxy proxy) {
  container.listen<Map<String, Uri>>(lyraUrlsProvider, (previous, next) {
    for (final serverId in (previous ?? const {}).keys) {
      if (!next.containsKey(serverId)) proxy.attachUrls(serverId, const []);
    }
    for (final MapEntry(key: serverId, value: url) in next.entries) {
      proxy.attachUrls(serverId, [url.toString()]);
    }
  }, fireImmediately: true);
}
