// ORPHEUS: ways into Lyra from the library search in Browse, shown only when
// the current server has a Lyra address.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/providers/search_provider.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_providers.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_settings.dart';

/// A button for the Browse search field: opens Lyra, searching for what is
/// typed in the field.
class LyraSearchButton extends ConsumerWidget {
  const LyraSearchButton({required this.query, super.key});

  /// The text currently in the search field.
  final String Function() query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(lyraUrlProvider) == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Request music with Lyra',
      padding: EdgeInsets.zero,
      onPressed: () => openLyra(context, query: query()),
      icon: const Icon(Icons.library_add_outlined),
    );
  }
}

/// Offers to search Lyra for the current library search, below its results
/// (or below "Nothing found").
class LyraSearchSuggestion extends ConsumerWidget {
  const LyraSearchSuggestion({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(searchProvider)?.trim() ?? '';
    if (query.isEmpty || ref.watch(lyraUrlProvider) == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: TextButton.icon(
          onPressed: () => openLyra(context, query: query),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: Icon(Icons.library_add_outlined, color: muted),
          label: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Not in your library? ',
                  style: TextStyle(color: muted),
                ),
                TextSpan(
                  text: 'Search Lyra for "$query"',
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
              ],
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
