// ORPHEUS: client for Lyra's app API (/api/v1/), the self-hosted service
// that searches streaming catalogues and queues downloads into the library.
//
// Lyra has no authentication of its own: it sits behind the same reverse
// proxy as the media server, and the app reaches it with that server's client
// certificate (attached in lyra_settings.dart). Requests go through plain
// Dio, so the app's HttpOverrides present the certificate and apply the
// app's certificate trust like for every other Dart-side request.
import 'package:dio/dio.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

/// The API version this client speaks.
const lyraApiVersion = 1;

class LyraException implements Exception {
  const LyraException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class LyraInfo {
  const LyraInfo({
    required this.apiVersion,
    required this.sources,
    required this.searchTypes,
    required this.artistDownloads,
    required this.defaultQuality,
  });

  factory LyraInfo.fromJson(Map<String, dynamic> json) => LyraInfo(
    apiVersion: json['api_version'] as int? ?? 0,
    sources: _strings(json['sources']),
    searchTypes: _strings(json['search_types']),
    artistDownloads: json['artist_downloads'] == true,
    defaultQuality: {
      for (final MapEntry(:key, :value)
          in (json['default_quality'] as Map<String, dynamic>? ?? const {})
              .entries)
        if (value is String) key: value,
    },
  );

  final int apiVersion;
  final List<String> sources;
  final List<String> searchTypes;
  final bool artistDownloads;
  final Map<String, String> defaultQuality;
}

class LyraSearchResult {
  const LyraSearchResult({
    required this.id,
    required this.source,
    required this.type,
    required this.title,
    required this.url,
    this.artist,
  });

  factory LyraSearchResult.fromJson(Map<String, dynamic> json) =>
      LyraSearchResult(
        id: json['id'] as String? ?? '',
        source: json['source'] as String? ?? '',
        type: json['type'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String?,
        url: json['url'] as String? ?? '',
      );

  final String id;
  final String source;
  final String type;
  final String title;
  final String? artist;
  final String url;
}

/// Where a request is in Lyra's queue.
enum LyraRequestStatus {
  queued,
  waitingForRateLimit,
  downloading,
  completed,
  failed,
  unknown;

  static LyraRequestStatus parse(String? value) => switch (value) {
    'queued' => queued,
    'waiting_for_rate_limit' => waitingForRateLimit,
    'downloading' => downloading,
    'completed' => completed,
    'failed' => failed,
    _ => unknown,
  };

  bool get isFinished => this == completed || this == failed;

  String get label => switch (this) {
    queued => 'Queued',
    waitingForRateLimit => 'Waiting',
    downloading => 'Downloading',
    // Lyra downloads into a staging folder; the library sees the release
    // after the import.
    completed => 'Downloaded, waiting for import',
    failed => 'Failed',
    unknown => 'Unknown',
  };
}

class LyraRequest {
  const LyraRequest({
    required this.id,
    required this.url,
    required this.status,
    this.title,
    this.artist,
    this.service,
    this.coverUrl,
    this.queuePosition,
    this.createdAt,
    this.finishedAt,
    this.error,
  });

  factory LyraRequest.fromJson(Map<String, dynamic> json) => LyraRequest(
    id: json['id'] as String? ?? '',
    url: json['url'] as String? ?? '',
    status: LyraRequestStatus.parse(json['status'] as String?),
    title: json['title'] as String?,
    artist: json['artist'] as String?,
    service: json['service'] as String?,
    coverUrl: json['cover_url'] as String?,
    queuePosition: json['queue_position'] as int?,
    createdAt: _time(json['created_at']),
    finishedAt: _time(json['finished_at']),
    error: json['error'] as String?,
  );

  final String id;
  final String url;
  final LyraRequestStatus status;
  final String? title;
  final String? artist;
  final String? service;
  final String? coverUrl;
  final int? queuePosition;
  final DateTime? createdAt;
  final DateTime? finishedAt;
  final String? error;
}

/// Lyra's queue: running, waiting, and recently finished (newest first).
class LyraRequests {
  const LyraRequests({
    this.active = const [],
    this.queued = const [],
    this.recent = const [],
  });

  factory LyraRequests.fromJson(Map<String, dynamic> json) => LyraRequests(
    active: _requests(json['active']),
    queued: _requests(json['queued']),
    recent: _requests(json['recent']),
  );

  final List<LyraRequest> active;
  final List<LyraRequest> queued;
  final List<LyraRequest> recent;

  List<LyraRequest> get all => [...active, ...queued, ...recent];

  bool get isEmpty => active.isEmpty && queued.isEmpty && recent.isEmpty;
}

class LyraClient {
  LyraClient(Uri baseUrl, {Dio? dio})
    : baseUrl = normalizeLyraUrl(baseUrl),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              // Lyra's search runs Streamrip with a 30 second limit.
              receiveTimeout: const Duration(seconds: 45),
              contentType: Headers.jsonContentType,
            ),
          );

  final Uri baseUrl;
  final Dio _dio;

  Uri _endpoint(String path) => baseUrl.resolve('api/v$lyraApiVersion/$path');

  Future<LyraInfo> info() async {
    final info = LyraInfo.fromJson(await _get('info'));
    if (info.apiVersion != lyraApiVersion) {
      throw LyraException(
        'This Lyra speaks API version ${info.apiVersion}; Orpheus needs '
        'version $lyraApiVersion. Update Lyra or Orpheus.',
      );
    }
    return info;
  }

  Future<List<LyraSearchResult>> search(
    String query, {
    required String source,
    required String type,
  }) async {
    final json = await _send(
      () => _dio.postUri<Object?>(
        _endpoint('search'),
        data: {'query': query, 'source': source, 'type': type},
      ),
    );
    return [
      for (final item in json['results'] as List<dynamic>? ?? const [])
        if (item is Map<String, dynamic>) LyraSearchResult.fromJson(item),
    ];
  }

  /// The cover image URL of [result], or null when Lyra has none.
  Future<String?> artwork(LyraSearchResult result) async {
    final json = await _send(
      () => _dio.getUri<Object?>(
        _endpoint('artwork').replace(
          queryParameters: {
            'source': result.source,
            'type': result.type,
            'id': result.id,
          },
        ),
      ),
    );
    final url = json['url'];
    return url is String && url.isNotEmpty ? url : null;
  }

  Future<LyraRequest> request(
    LyraSearchResult result, {
    String? coverUrl,
  }) async {
    final json = await _send(
      () => _dio.postUri<Object?>(
        _endpoint('requests'),
        data: {
          'url': result.url,
          if (result.title.isNotEmpty) 'title': result.title,
          'artist': ?result.artist,
          'cover_url': ?coverUrl,
        },
      ),
    );
    return LyraRequest.fromJson(json['request'] as Map<String, dynamic>);
  }

  Future<LyraRequests> requests() async =>
      LyraRequests.fromJson(await _get('requests'));

  Future<Map<String, dynamic>> _get(String path) =>
      _send(() => _dio.getUri<Object?>(_endpoint(path)));

  Future<Map<String, dynamic>> _send(
    Future<Response<Object?>> Function() call,
  ) async {
    final Response<Object?> response;
    try {
      response = await call();
    } on DioException catch (error) {
      throw _explain(error);
    }
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    throw const LyraException(
      'The address answered, but not like Lyra. Check the Lyra address.',
    );
  }

  LyraException _explain(DioException error) {
    final response = error.response;
    final status = response?.statusCode;
    final data = response?.data;
    final body = data is String ? data : null;
    if (looksLikeClientCertificateRequired(
      error.error,
      statusCode: status,
      body: body,
    )) {
      return LyraException(
        "Lyra's reverse proxy refused the connection: it needs this "
        "server's client certificate, which is missing, expired or not "
        'accepted there.',
        statusCode: status,
      );
    }
    if (data is Map<String, dynamic> && data['error'] is String) {
      return LyraException(data['error'] as String, statusCode: status);
    }
    if (status == 404) {
      return LyraException(
        'No Lyra app API at this address. Check the address, and that Lyra '
        'is up to date.',
        statusCode: status,
      );
    }
    if (status != null) {
      return LyraException(
        'Lyra answered with HTTP $status.',
        statusCode: status,
      );
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => const LyraException(
        'Lyra did not answer in time.',
      ),
      DioExceptionType.badCertificate => const LyraException(
        "Lyra's server certificate is not trusted.",
      ),
      _ => const LyraException('Lyra could not be reached.'),
    };
  }
}

/// [url] with a trailing slash on its path and no query or fragment, so
/// relative API paths resolve below it (Lyra may live under a path prefix).
Uri normalizeLyraUrl(Uri url) {
  final path = url.path.endsWith('/') ? url.path : '${url.path}/';
  return Uri(
    scheme: url.scheme,
    userInfo: url.userInfo,
    host: url.host,
    port: url.hasPort ? url.port : null,
    path: path,
  );
}

/// Parses what the user typed as a Lyra address: http(s) with a host, or
/// null.
Uri? parseLyraUrl(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null ||
      !(uri.isScheme('https') || uri.isScheme('http')) ||
      uri.host.isEmpty) {
    return null;
  }
  return normalizeLyraUrl(uri);
}

List<String> _strings(Object? value) => [
  for (final item in value as List<dynamic>? ?? const [])
    if (item is String) item,
];

List<LyraRequest> _requests(Object? value) => [
  for (final item in value as List<dynamic>? ?? const [])
    if (item is Map<String, dynamic>) LyraRequest.fromJson(item),
];

DateTime? _time(Object? value) => value is num
    ? DateTime.fromMillisecondsSinceEpoch((value * 1000).round())
    : null;
