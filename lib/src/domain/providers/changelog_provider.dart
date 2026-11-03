// ORPHEUS: replaces the updatify.io changelog with the release notes of the
// fork's GitHub releases (see orpheusGitHubRepository).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/core/updates/release_checker.dart';
import 'package:jplayer/src/domain/providers/update_banner_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Release notes of the installed version, or of the latest release when the
/// installed version has none (for example a local build).
final AutoDisposeFutureProvider<ReleaseNotes?> changelogProvider =
    FutureProvider.autoDispose<ReleaseNotes?>((
      ref,
    ) async {
      final info = await PackageInfo.fromPlatform();
      return ref.read(releaseCheckerProvider).notes(version: info.version);
    });

/// Remembers which version's changelog the user has already seen, so it is
/// shown once after an update and never on a fresh install.
class ChangelogSeen {
  const ChangelogSeen(this._prefs);

  static const key = 'orpheus_changelog_seen_version';

  final SharedPreferences _prefs;

  /// Whether [version] is new since the last launch. A fresh install only
  /// records the version, so the changelog does not greet a new user.
  bool isNewSinceLastLaunch(String version) {
    final seen = _prefs.getString(key);
    return seen != null && seen != version;
  }

  Future<void> markSeen(String version) => _prefs.setString(key, version);
}
