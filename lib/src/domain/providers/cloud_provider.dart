import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optional_features/jellybox_cloud.dart';
import 'package:jplayer/src/data/providers/providers.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';

// ORPHEUS: JellyBox cloud continuity (handoff, remote control, playing
// elsewhere) is removed. CloudNotifier keeps its public API so the player bar,
// output controller and device volume code compile unchanged, but it never
// creates a JellyboxCloud, never contacts any cloud service, and its state
// stays empty, so every provider below resolves to "nothing remote".
final cloudProvider = StateNotifierProvider<CloudNotifier, CloudState>(
  (ref) => CloudNotifier(),
);

class CloudNotifier extends StateNotifier<CloudState> {
  CloudNotifier() : super(const CloudState());

  bool get available => false;

  Future<bool> signIn({
    required String address,
    required String email,
    required String password,
  }) async => false;

  Future<void> signOut() async {}

  Future<bool> handoffTo(String deviceId) async => false;

  bool? sameBackend(ConductorDevice device) => null;

  Future<void> sendCommand(PlayerCommand command, {Object? value}) async {}

  Future<bool> claimHere() async => false;

  Future<void> shutdown() async {}
}

final cloudAvailableProvider = Provider<bool>(
  (ref) => ref.watch(cloudProvider.notifier).available,
);

final remoteSessionOursProvider = Provider<bool>((ref) {
  final queueRef = ref.watch(
    cloudProvider.select((state) => state.remote?.doc.backendRef),
  );
  final ours = ref.watch(currentServerIdProvider);
  return queueRef == null || ours == null || queueRef == ours;
});

final remoteRendererProvider = Provider<ConductorDevice?>((ref) {
  if (!ref.watch(remoteSessionOursProvider)) return null;
  final state = ref.watch(cloudProvider);
  final hasQueue = !(state.remote?.doc.isEmpty ?? true);
  return hasQueue ? state.remoteRenderer : null;
});

final remoteSessionProvider = Provider<RemoteSession?>(
  (ref) => ref.watch(remoteRendererProvider) == null
      ? null
      : ref.watch(cloudProvider.select((state) => state.remote)),
);

final playingElsewhereProvider = Provider<bool>(
  (ref) => ref.watch(remoteRendererProvider) != null,
);

final remoteQueueProvider = FutureProvider<List<LibraryItem>>((ref) async {
  final key = ref.watch(
    remoteSessionProvider.select((remote) => remote?.doc.itemIds.join(',')),
  );
  if (key == null || key.isEmpty) return const [];

  final ids = key.split(',');
  final items = await ref.read(mediaServerClientProvider).getItemsByIds(ids);
  final byId = {for (final item in items) item.id: item};
  return [
    for (final id in ids)
      byId[id] ??
          LibraryItem(id: id, name: 'Unavailable track', kind: ItemKind.song),
  ];
});

final remoteNowPlayingProvider = Provider<LibraryItem?>((ref) {
  final itemId = ref.watch(
    remoteSessionProvider.select((remote) => remote?.doc.currentItemId),
  );
  if (itemId == null) return null;
  final queue = ref.watch(remoteQueueProvider).valueOrNull ?? const [];
  for (final item in queue) {
    if (item.id == itemId) return item;
  }
  return null;
});

final AutoDisposeStreamProvider<int> _remoteTickProvider =
    StreamProvider.autoDispose<int>((ref) {
      final playing = ref.watch(
        remoteSessionProvider.select((remote) => remote?.doc.playing ?? false),
      );
      if (!playing) return Stream.value(0);
      return Stream.periodic(const Duration(milliseconds: 250), (tick) => tick);
    });

final AutoDisposeProvider<Duration> remotePositionProvider =
    Provider.autoDispose<Duration>((ref) {
      ref.watch(_remoteTickProvider);
      final remote = ref.watch(remoteSessionProvider);
      if (remote == null) return Duration.zero;
      return remote.positionAt(DateTime.now());
    });
