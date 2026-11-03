import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mtls_proxy/src/client_certificate.dart';

/// The subset of a secure key/value store the certificate store needs. The
/// app passes its own [FlutterSecureStorage] (with its platform options) via
/// [FlutterSecureKeyValueStore]; tests use an in-memory map.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  const FlutterSecureKeyValueStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A server connection that presents a client certificate.
@immutable
class StoredConnection {
  StoredConnection({
    required this.id,
    required this.certificate,
    required Iterable<String> serverUrls,
  }) : serverUrls = List.unmodifiable(serverUrls);

  /// The app's identifier for the server connection (its server ID).
  final String id;

  final ClientCertificate certificate;

  /// Every base URL of the connection (home and remote address). The
  /// certificate is presented to these hosts and to no other.
  final List<String> serverUrls;

  StoredConnection copyWith({
    ClientCertificate? certificate,
    Iterable<String>? serverUrls,
  }) => StoredConnection(
    id: id,
    certificate: certificate ?? this.certificate,
    serverUrls: serverUrls ?? this.serverUrls,
  );

  @override
  String toString() =>
      'StoredConnection($id, ${serverUrls.length} url(s), $certificate)';
}

/// Persists client certificates in secure storage, one entry per connection.
///
/// The PKCS#12 bytes, the password and the optional CA live only here: never
/// in shared preferences, plain files or logs.
class CertificateStore {
  CertificateStore(this._storage);

  static const indexKey = 'orpheus_mtls_connections';
  static const _entryPrefix = 'orpheus_mtls_connection_';

  final SecureKeyValueStore _storage;

  static String entryKey(String connectionId) =>
      '$_entryPrefix${Uri.encodeComponent(connectionId)}';

  Future<List<StoredConnection>> loadAll() async {
    final connections = <StoredConnection>[];
    for (final id in await _index()) {
      final connection = await load(id);
      if (connection != null) connections.add(connection);
    }
    return connections;
  }

  Future<StoredConnection?> load(String connectionId) async {
    final raw = await _storage.read(entryKey(connectionId));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ca = json['ca'] as String?;
      return StoredConnection(
        id: connectionId,
        certificate: ClientCertificate(
          pkcs12: base64Decode(json['p12'] as String),
          password: json['password'] as String,
          caPem: ca == null ? null : base64Decode(ca),
        ),
        serverUrls: [
          for (final url in json['urls'] as List<dynamic>? ?? const []) '$url',
        ],
      );
    } on Object {
      // A damaged entry is skipped rather than taking every connection down.
      return null;
    }
  }

  Future<void> save(StoredConnection connection) async {
    final certificate = connection.certificate;
    await _storage.write(
      entryKey(connection.id),
      jsonEncode({
        'p12': base64Encode(certificate.pkcs12),
        'password': certificate.password,
        if (certificate.caPem != null) 'ca': base64Encode(certificate.caPem!),
        'urls': connection.serverUrls,
      }),
    );
    final ids = await _index();
    if (!ids.contains(connection.id)) {
      await _writeIndex([...ids, connection.id]);
    }
  }

  Future<void> remove(String connectionId) async {
    await _storage.delete(entryKey(connectionId));
    final ids = await _index();
    if (ids.remove(connectionId)) await _writeIndex(ids);
  }

  Future<List<String>> _index() async {
    final raw = await _storage.read(indexKey);
    if (raw == null) return [];
    try {
      return [for (final id in jsonDecode(raw) as List<dynamic>) '$id'];
    } on Object {
      return [];
    }
  }

  Future<void> _writeIndex(List<String> ids) =>
      _storage.write(indexKey, jsonEncode(ids));
}

/// [SecureKeyValueStore] backed by a map, for tests.
class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
