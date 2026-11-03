// ORPHEUS: app-side wiring of packages/mtls_proxy (client certificates /
// mTLS). Everything the upstream hook points call lives here, so upstream
// files only carry one-line calls marked "ORPHEUS:".
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/core/android_auto/cover_art_uri.dart';
import 'package:jplayer/src/core/enums/download_status.dart';
import 'package:jplayer/src/core/network/certificate_trust.dart';
import 'package:jplayer/src/data/providers/secure_storage_provider.dart';
import 'package:jplayer/src/data/storages/account_store.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/playback/playback_target.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_providers.dart';
import 'package:jplayer/src/providers/accounts_provider.dart';
import 'package:jplayer/src/providers/base_url_provider.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:jplayer/src/providers/server_addresses_provider.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

/// Bumped whenever a client certificate is installed, replaced or removed,
/// so UI and providers that depend on [MtlsProxy] rebuild.
final mtlsRevisionProvider = StateProvider<int>((ref) => 0);

/// Why Cast and DLNA devices cannot play from the current server, or null
/// when they can. Those devices fetch the stream themselves: they can neither
/// present the client certificate nor reach this device's loopback proxy.
final remotePlaybackBlockedProvider = Provider<String?>((ref) {
  ref.watch(mtlsRevisionProvider);
  final url = ref.watch(baseUrlProvider);
  if (url == null || !MtlsProxy.instance.appliesToUrl(url)) return null;
  return 'Not available: this server needs a client certificate, which '
      'Cast and DLNA devices cannot present.';
});

/// Loads the stored client certificates and starts the loopback proxy before
/// the app makes its first request, and keeps the certificates in step with
/// the saved server accounts from then on.
Future<void> initOrpheusMtls(ProviderContainer container) async {
  final proxy = MtlsProxy.instance;
  if (!proxy.isSupported) return;
  proxy.trust = AppServerTrust(CertificateTrust.instance);
  // Player errors can quote the stream URL; keep the proxy token out of the
  // console and the device log (DeviceLog records through debugPrint).
  final print = debugPrint;
  debugPrint = (message, {wrapWidth}) => print(
    message == null ? null : proxy.redact(message),
    wrapWidth: wrapWidth,
  );
  try {
    await proxy.load(
      CertificateStore(
        FlutterSecureKeyValueStore(container.read(secureStorageProvider)),
      ),
    );
  } on Object catch (error) {
    // Never log the error text itself: it could quote stored data.
    debugPrint(
      '[mTLS] loading client certificates failed '
      '(${error.runtimeType})',
    );
  }
  proxy
    ..attachToAppLifecycle()
    ..addListener(() => container.read(mtlsRevisionProvider.notifier).state++);

  container
    ..listen<List<ServerAccount>>(
      accountsProvider,
      (previous, next) =>
          unawaited(_syncAccounts(proxy, previous ?? const [], next)),
      fireImmediately: true,
    )
    ..listen<ServerAddresses?>(serverAddressesProvider, (_, addresses) {
      final serverId = container.read(currentServerIdProvider);
      if (addresses == null || serverId == null) return;
      unawaited(proxy.setServerUrls(serverId, addresses.candidates));
    });
  // Lyra (music requests) shares its server's client certificate.
  attachLyraCertificates(container, proxy);
  unawaited(_cancelStaleProxyDownloads());
}

Future<void> _syncAccounts(
  MtlsProxy proxy,
  List<ServerAccount> previous,
  List<ServerAccount> accounts,
) async {
  // A server just added with a certificate imported on the login page. This
  // runs before the first await, so the login page cannot discard the staged
  // certificate in between.
  final added = proxy.hasStaged
      ? accounts
            .where(
              (account) =>
                  !proxy.hasCertificate(account.serverId) &&
                  proxy.connectionIdFor(Uri.parse(account.url)) ==
                      MtlsProxy.stagedConnectionId,
            )
            .firstOrNull
      : null;
  final commit = added == null
      ? null
      : proxy.commitStaged(added.serverId, [added.url, ?added.remoteUrl]);
  await commit;
  for (final account in accounts) {
    if (proxy.hasCertificate(account.serverId)) {
      await proxy.setServerUrls(account.serverId, [
        account.url,
        ?account.remoteUrl,
      ]);
    }
  }
  final kept = {for (final account in accounts) account.serverId};
  for (final account in previous) {
    if (!kept.contains(account.serverId) &&
        proxy.hasCertificate(account.serverId)) {
      await proxy.remove(account.serverId);
    }
  }
}

/// The app's certificate trust (user-trusted self-signed certificates and
/// pinned fingerprints) for the mTLS proxy's upstream connections.
class AppServerTrust implements ServerTrust {
  AppServerTrust(this._trust);

  final CertificateTrust _trust;

  @override
  bool isPinned(String host, int port) => _trust.pinFor(host, port) != null;

  @override
  bool matchesPin(X509Certificate certificate, String host, int port) =>
      _trust.matchesPin(certificate, host, port);

  @override
  bool allowsUntrusted(X509Certificate certificate, String host, int port) =>
      _trust.allows(certificate, host, port);
}

/// The client-certificate context for [host]:[port], or null when no
/// configured connection uses that host (so nobody else ever gets it).
SecurityContext? clientCertificateContextFor(
  String host,
  int port, {
  required bool pinned,
}) => MtlsProxy.instance.contextFor(host, port, pinned: pinned);

/// Whether switching playback to [target] must be refused: Cast and DLNA
/// devices cannot play from a server that needs a client certificate.
bool blocksRemoteTarget(Ref ref, PlaybackTarget target) =>
    target.kind != PlaybackTargetKind.local &&
    ref.read(remotePlaybackBlockedProvider) != null;

/// Whether [uri] belongs to a server that needs the client certificate.
bool needsMtlsProxy(Uri uri) => MtlsProxy.instance.appliesTo(uri);

/// The stream and artwork URIs as the native player must open them: through
/// the mTLS proxy, resolved now and never stored. On Android the artwork goes
/// through the cover provider like every other cover.
Future<(Uri, Uri?)> resolveForMtlsPlayback(Uri stream, Uri? art) async {
  final proxy = MtlsProxy.instance;
  final resolvedArt = art == null ? null : await proxy.resolve(art);
  return (
    await proxy.resolve(stream),
    !kIsWeb && Platform.isAndroid
        ? androidCoverArtUri(resolvedArt)
        : resolvedArt,
  );
}

/// [url] as a native downloader must open it. Resolve right before use; the
/// result must never be stored.
Future<String> downloadUrlFor(String url) => MtlsProxy.instance.resolveUrl(url);

/// On iOS, background_downloader hands transfers to a system daemon that
/// keeps going while the app is suspended, when the app's loopback proxy is
/// suspended too. Downloads from servers that need a client certificate
/// therefore run in the app instead (and pause with it).
bool downloadsInForeground(String url) =>
    !kIsWeb && Platform.isIOS && MtlsProxy.instance.appliesToUrl(url);

final _foregroundCancels = <String, Completer<void>>{};

/// Downloads [task] in the foreground, reporting through the same status and
/// progress notifiers the background path uses.
Future<void> downloadTaskInForeground(DownloadTask task) async {
  final cancel = Completer<void>();
  _foregroundCancels[task.id] = cancel;
  task.status.value = DownloadStatus.downloading;
  try {
    final done =
        await ForegroundDownloader(
          () => MtlsProxy.instance.createHttpClient(
            trust: AppServerTrust(CertificateTrust.instance),
          ),
        ).download(
          Uri.parse(task.url),
          task.destination,
          onProgress: (progress) => task.progress.value = progress,
          cancel: cancel.future,
        );
    if (done) {
      task
        ..progress.value = 1
        ..status.value = DownloadStatus.completed;
    } else {
      task.status.value = DownloadStatus.canceled;
    }
  } on Object catch (error) {
    debugPrint(
      '[Download] "${task.name}" failed in the foreground '
      '(${error.runtimeType})',
    );
    task.status.value = DownloadStatus.failed;
  } finally {
    _foregroundCancels.remove(task.id);
  }
}

/// Cancels a foreground download started by [downloadTaskInForeground].
void cancelForegroundDownload(String id) {
  final cancel = _foregroundCancels.remove(id);
  if (cancel != null && !cancel.isCompleted) cancel.complete();
}

/// Fetches [url] into [path] in the foreground; null when it failed.
Future<String?> fetchInForeground(String url, String path) async {
  try {
    final done = await ForegroundDownloader(
      () => MtlsProxy.instance.createHttpClient(
        trust: AppServerTrust(CertificateTrust.instance),
      ),
    ).download(Uri.parse(url), path);
    return done ? path : null;
  } on Object {
    return null;
  }
}

/// Downloads queued before a restart hold a proxy URL with the previous
/// launch's token, which can never work again. Cancel them; the download
/// sync queues them afresh with a URL resolved at that time.
Future<void> _cancelStaleProxyDownloads() async {
  try {
    final tasks = await bd.FileDownloader().allTasks(allGroups: true);
    final stale = [
      for (final task in tasks)
        if (Uri.tryParse(task.url)?.host ==
            InternetAddress.loopbackIPv4.address)
          task.taskId,
    ];
    if (stale.isNotEmpty) {
      await bd.FileDownloader().cancelTasksWithIds(stale);
    }
  } on Object {
    return;
  }
}

/// Adds a hint about client certificates to a failed sign-in [message] when
/// [server] turns away clients without one, or refuses the one configured.
Future<String> explainSignInFailure(String message, Uri server) async {
  if (kIsWeb || !server.isScheme('https')) return message;
  if (MtlsProxy.instance.appliesTo(server)) {
    if (await _certificateAccepted(server)) return message;
    return '$message\n\nThe server refused the client certificate. Check '
        'that it is the right one and has not expired.';
  }
  if (!await ClientCertificateProbe.requiresCertificate(server)) {
    return message;
  }
  return '$message\n\nThis server asks for a client certificate (mTLS). '
      'Import one under "Client certificate" and try again.';
}

/// Whether [server] answers at all when the configured certificate is
/// presented; any HTTP answer means the TLS side is fine.
Future<bool> _certificateAccepted(Uri server) async {
  final client = MtlsProxy.instance.createHttpClient(
    trust: AppServerTrust(CertificateTrust.instance),
  )..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.headUrl(server.replace(path: '/'));
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>();
    return !looksLikeClientCertificateRequired(
      null,
      statusCode: response.statusCode,
      body: response.reasonPhrase,
    );
  } on Object catch (error) {
    return !looksLikeClientCertificateRequired(error) &&
        error is! SocketException &&
        error is! HttpException;
  } finally {
    client.close(force: true);
  }
}
