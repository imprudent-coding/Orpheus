// ORPHEUS: request music from Lyra: search streaming catalogues, queue a
// download, and follow the requests until they are downloaded.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_client.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_providers.dart';
import 'package:jplayer/src/presentation/utils/utils.dart';
import 'package:jplayer/src/presentation/widgets/widgets.dart';

const _typeLabels = {
  'album': 'Albums',
  'track': 'Tracks',
  'playlist': 'Playlists',
  'artist': 'Artists',
};

const _sourceLabels = {
  'qobuz': 'Qobuz',
  'tidal': 'Tidal',
  'deezer': 'Deezer',
  'soundcloud': 'SoundCloud',
};

String _sourceLabel(String source) => _sourceLabels[source] ?? source;

class LyraPage extends ConsumerWidget {
  const LyraPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final device = DeviceType.fromScreenSize(MediaQuery.sizeOf(context));
    final padding = MediaQuery.paddingOf(context);
    final horizontal = device.isMobile ? 16.0 : 30.0;
    final configured = ref.watch(lyraUrlProvider) != null;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: GradientBackground(
          child: Padding(
            padding: EdgeInsets.only(
              left: padding.left + horizontal,
              right: padding.right + horizontal,
              top: padding.top + (device.isMobile ? 8 : 20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const BackButton(),
                    const SizedBox(width: 4),
                    Text(
                      'Request music',
                      style: TextStyle(
                        fontSize: device.isMobile ? 22 : 26,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ],
                ),
                if (!configured)
                  const Expanded(
                    child: _Message(
                      'Set the Lyra address under Settings > Lyra first.',
                    ),
                  )
                else ...[
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: theme.colorScheme.primary,
                    unselectedLabelColor: theme.colorScheme.onPrimary,
                    indicatorColor: theme.colorScheme.primary,
                    dividerColor: Colors.transparent,
                    tabs: const [
                      Tab(text: 'Search'),
                      Tab(text: 'Requests'),
                    ],
                  ),
                  const Expanded(
                    child: TabBarView(
                      children: [_SearchTab(), _RequestsTab()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchTab extends ConsumerStatefulWidget {
  const _SearchTab();

  @override
  ConsumerState<_SearchTab> createState() => _SearchTabState();
}

enum _RequestState { idle, busy, done }

class _SearchTabState extends ConsumerState<_SearchTab>
    with AutomaticKeepAliveClientMixin {
  final _query = TextEditingController();
  String? _source;
  var _type = 'album';
  List<LyraSearchResult>? _results;
  String? _message;
  var _searching = false;
  var _generation = 0;
  final _artwork = <String, Future<String?>>{};
  final _requests = <String, _RequestState>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(LyraInfo info) async {
    final client = ref.read(lyraClientProvider);
    final query = _query.text.trim();
    if (client == null || query.isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _message = null;
    });
    try {
      final results = await client.search(
        query,
        source: _source ?? info.sources.first,
        type: _type,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _artwork.clear();
        _requests.clear();
        _message = results.isEmpty ? 'No results.' : null;
      });
    } on LyraException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _message = error.message);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
      }
    }
  }

  Future<String?> _artworkFor(LyraSearchResult result) =>
      _artwork.putIfAbsent(result.url, () async {
        try {
          return await ref.read(lyraClientProvider)?.artwork(result);
        } on LyraException {
          return null;
        }
      });

  Future<void> _request(LyraSearchResult result) async {
    final client = ref.read(lyraClientProvider);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _requests[result.url] = _RequestState.busy);
    try {
      final cover = await _artworkFor(result);
      await client.request(result, coverUrl: cover);
      if (!mounted) return;
      setState(() => _requests[result.url] = _RequestState.done);
      ref.invalidate(lyraRequestsProvider);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Requested "${result.title}"')),
        );
    } on LyraException catch (error) {
      if (!mounted) return;
      setState(() => _requests[result.url] = _RequestState.idle);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final info = ref.watch(lyraInfoProvider);
    return switch (info) {
      AsyncData(:final value) => _content(context, value),
      AsyncError(:final error) => _Message(
        error is LyraException ? error.message : 'Lyra could not be reached.',
        onRetry: () => ref.invalidate(lyraInfoProvider),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _content(BuildContext context, LyraInfo info) {
    if (info.sources.isEmpty) {
      return const _Message('This Lyra offers no sources.');
    }
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
    final source = info.sources.contains(_source)
        ? _source!
        : info.sources.first;
    final types = [
      for (final type in _typeLabels.keys)
        if (info.searchTypes.contains(type) &&
            (type != 'artist' || info.artistDownloads))
          type,
    ];
    final results = _results;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_search(info)),
                decoration: InputDecoration(
                  hintText: 'Artist, album or track',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            DropdownButton<String>(
              value: source,
              underline: const SizedBox.shrink(),
              items: [
                for (final item in info.sources)
                  DropdownMenuItem(
                    value: item,
                    child: Text(_sourceLabel(item)),
                  ),
              ],
              onChanged: (value) => setState(() => _source = value),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final type in types)
              ChoiceChip(
                label: Text(_typeLabels[type]!),
                selected: _type == type,
                onSelected: (_) {
                  setState(() => _type = type);
                  if (_query.text.trim().isNotEmpty) unawaited(_search(info));
                },
              ),
          ],
        ),
        if (info.defaultQuality[source] case final quality?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Downloads in $quality.',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
        const SizedBox(height: 8),
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: results == null || results.isEmpty
              ? _Message(
                  _message ??
                      'Search for music that is not in your library yet.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: results.length + (_message == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (index == 0 && _message != null) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _message!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      );
                    }
                    final result =
                        results[index - (_message == null ? 0 : 1)];
                    return _ResultTile(
                      result: result,
                      artwork: _artworkFor(result),
                      state: _requests[result.url] ?? _RequestState.idle,
                      onRequest: () => unawaited(_request(result)),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.artwork,
    required this.state,
    required this.onRequest,
  });

  final LyraSearchResult result;
  final Future<String?> artwork;
  final _RequestState state;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onPrimary.withValues(alpha: 0.7);
    final details = [
      ?result.artist,
      _sourceLabel(result.source),
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _Cover(url: artwork),
      title: Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: muted),
      ),
      trailing: switch (state) {
        _RequestState.idle => IconButton(
          tooltip: 'Request',
          onPressed: onRequest,
          icon: const Icon(Icons.add_circle_outline),
        ),
        _RequestState.busy => const SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        _RequestState.done => const Tooltip(
          message: 'Requested',
          child: Icon(Icons.check_circle_outline),
        ),
      },
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url});

  final Future<String?> url;

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: url,
    builder: (context, snapshot) => _CoverImage(snapshot.data),
  );
}

class _CoverImage extends StatelessWidget {
  const _CoverImage(this.url);

  final String? url;

  static const _size = 48.0;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(Icons.album_outlined),
    );
    final src = url;
    if (src == null || src.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        src,
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(lyraRequestsProvider);
    final value = requests.valueOrNull;
    final error = requests.hasError
        ? (requests.error is LyraException
              ? (requests.error! as LyraException).message
              : 'Lyra could not be reached.')
        : null;
    if (value == null) {
      if (error != null) {
        return _Message(
          error,
          onRetry: () => ref.invalidate(lyraRequestsProvider),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final all = value.all;
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(lyraRequestsProvider.future),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (all.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: _Message(
                'No requests yet. Lyra keeps finished requests until it '
                'restarts.',
              ),
            ),
          for (final request in all) _RequestTile(request: request),
        ],
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.request});

  final LyraRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
    final status = request.status;
    final position = request.queuePosition;
    final statusText = switch (status) {
      LyraRequestStatus.queued when position != null => 'Queued (#$position)',
      LyraRequestStatus.failed when request.error != null =>
        'Failed: ${request.error}',
      _ => status.label,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _CoverImage(request.coverUrl),
      title: Text(
        request.title ?? request.url,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [?request.artist, statusText].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: status == LyraRequestStatus.failed
              ? theme.colorScheme.error
              : muted,
        ),
      ),
      trailing: switch (status) {
        LyraRequestStatus.downloading => const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        LyraRequestStatus.completed => const Icon(Icons.download_done),
        LyraRequestStatus.failed => Icon(
          Icons.error_outline,
          color: theme.colorScheme.error,
        ),
        _ => const Icon(Icons.schedule),
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onPrimary.withValues(alpha: 0.7);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: muted)),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
