// ORPHEUS: changelog backed by the fork's GitHub release notes, replacing the
// updatify.io dialog, bottom sheet and launch popup.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/config/constants.dart';
import 'package:jplayer/src/domain/providers/changelog_provider.dart';
import 'package:jplayer/src/domain/providers/update_banner_provider.dart';
import 'package:jplayer/src/presentation/themes/themes.dart';
import 'package:jplayer/src/presentation/widgets/form_modal.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showChangelog(BuildContext context) => showAppDialog<void>(
  context,
  builder: (context) => const ChangelogDialog(),
);

/// Shows the changelog once after the app was updated to a new version.
Future<void> maybeShowChangelogAfterUpdate(
  BuildContext context,
  WidgetRef ref,
) async {
  final info = await PackageInfo.fromPlatform();
  final seen = ChangelogSeen(await SharedPreferences.getInstance());
  if (!seen.isNewSinceLastLaunch(info.version)) {
    await seen.markSeen(info.version);
    return;
  }
  final notes = await ref
      .read(changelogProvider.future)
      .catchError((Object _) => null);
  if (notes == null || notes.body.isEmpty || !context.mounted) return;
  await seen.markSeen(info.version);
  if (!context.mounted) return;
  await showChangelog(context);
}

class ChangelogDialog extends ConsumerWidget {
  const ChangelogDialog({super.key});

  void _open(Uri uri) =>
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notes = ref.watch(changelogProvider);
    final update = ref.watch(visibleUpdateProvider);
    final page = notes.valueOrNull?.page;
    final size = MediaQuery.sizeOf(context);

    final content = switch (notes) {
      AsyncData(:final value?) when value.body.isNotEmpty => SelectableText(
        value.body,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
      ),
      AsyncData() => const Text('This release has no notes.'),
      AsyncError() => const Text(
        'Could not load the release notes. Check your connection and try '
        'again later.',
      ),
      _ => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
    };

    return AlertDialog(
      backgroundColor: Themes.changelogSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: Text(
        notes.valueOrNull == null
            ? changelogTitle
            : '$changelogTitle in ${notes.valueOrNull!.version}',
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: size.width < 700 ? size.width : 600,
          maxHeight: size.height * 0.6,
        ),
        child: SingleChildScrollView(child: content),
      ),
      actions: [
        if (update != null)
          TextButton(
            onPressed: () => _open(update.url),
            child: Text('Get ${update.version}'),
          ),
        TextButton(
          onPressed: () => _open(
            page ??
                Uri.parse(
                  'https://github.com/$orpheusGitHubRepository/releases',
                ),
          ),
          child: const Text('Open on GitHub'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
