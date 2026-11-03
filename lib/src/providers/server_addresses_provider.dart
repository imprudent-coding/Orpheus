import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/providers/secure_storage_provider.dart';
import 'package:jplayer/src/data/services/server_probe_service.dart';

// ORPHEUS: the JellyBox relay tunnel is removed. A server has
// its home address and, optionally, a manual remote address.
@immutable
class ServerAddresses {
  const ServerAddresses({required this.home, this.remote});

  final String home;
  final String? remote;

  List<String> get fallbacks => [?remote];

  List<String> get candidates => [home, ...fallbacks];

  ServerAddresses copyWith({
    String? home,
    String? Function()? remote,
  }) => ServerAddresses(
    home: home ?? this.home,
    remote: remote == null ? this.remote : remote(),
  );

  @override
  bool operator ==(Object other) =>
      other is ServerAddresses && other.home == home && other.remote == remote;

  @override
  int get hashCode => Object.hash(home, remote);
}

const remoteUrlStorageKey = 'remoteUrl';

final serverAddressesProvider = StateProvider<ServerAddresses?>((ref) => null);

Future<void> rememberRemote(Ref ref, String? url) async {
  final addresses = ref.read(serverAddressesProvider);
  if (addresses == null) return;
  final remote = url == null || url.trim().isEmpty
      ? null
      : normalizeServerUrl(url);
  if (remote == addresses.remote) return;
  final storage = ref.read(secureStorageProvider);
  if (remote == null) {
    await storage.delete(key: remoteUrlStorageKey);
  } else {
    await storage.write(key: remoteUrlStorageKey, value: remote);
  }
  ref.read(serverAddressesProvider.notifier).state = addresses.copyWith(
    remote: () => remote,
  );
}
