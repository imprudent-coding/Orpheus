import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/domain/providers/update_banner_provider.dart';
import 'package:jplayer/src/presentation/widgets/changelog_dialog.dart';
import 'package:jplayer/src/presentation/widgets/hover_zoom.dart';
import 'package:jplayer/src/providers/color_scheme_provider.dart';

// ORPHEUS: opens the GitHub release notes instead of updatify.io; the dot
// marks an available update. The class keeps its upstream name so its call
// sites are unchanged.
class UpdatifyBell extends ConsumerWidget {
  const UpdatifyBell({
    required this.isDesktop,
    this.iconSize = 28,
    this.tapSize = 40,
    super.key,
  });

  final bool isDesktop;
  final double iconSize;
  final double tapSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentColorProvider);
    final hasNewUpdates = ref.watch(visibleUpdateProvider) != null;
    return HoverZoom(
      builder: (context, hovered) => IconTheme.merge(
        data: IconThemeData(size: iconSize),
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.square(tapSize),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: hovered ? accent : null,
              overlayColor: Colors.transparent,
            ),
          ),
          child: Builder(
            builder: (context) => IconButton(
              onPressed: () => showChangelog(context),
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications_outlined),
                  if (hasNewUpdates)
                    Positioned(
                      top: -1,
                      right: -1,
                      child: SizedBox.square(
                        dimension: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.redAccent.shade200,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
