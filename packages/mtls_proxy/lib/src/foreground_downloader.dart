import 'dart:async';
import 'dart:io';

/// Downloads a file in this process, presenting the client certificate
/// directly instead of going through the loopback proxy.
///
/// Used where a background download cannot reach the proxy: on iOS,
/// background_downloader hands transfers to a system daemon that keeps running
/// while the app is suspended, but the app's loopback proxy is suspended with
/// it. Downloads of servers that need a client certificate therefore run in
/// the foreground there, and stop when the app is suspended.
class ForegroundDownloader {
  ForegroundDownloader(this._clientFactory);

  final HttpClient Function() _clientFactory;

  /// Writes [uri] to [destinationPath] (via a `.part` file that is renamed on
  /// success). Completes with false when [cancel] completes first. Throws
  /// [HttpException] (without the URL) on a non-2xx answer.
  Future<bool> download(
    Uri uri,
    String destinationPath, {
    Map<String, String> headers = const {},
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    final client = _clientFactory();
    final partial = File('$destinationPath.part');
    var cancelled = false;
    unawaited(
      cancel?.then((_) {
        cancelled = true;
        client.close(force: true);
      }),
    );
    try {
      final request = await client.getUrl(uri);
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException('download failed with HTTP ${response.statusCode}');
      }
      await partial.parent.create(recursive: true);
      final sink = partial.openWrite();
      final total = response.contentLength;
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      if (cancelled) return false;
      await partial.rename(destinationPath);
      onProgress?.call(1);
      return true;
    } on Object {
      if (partial.existsSync()) partial.deleteSync();
      if (cancelled) return false;
      rethrow;
    } finally {
      client.close();
    }
  }
}
