import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/domain/providers/changelog_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ORPHEUS: the changelog shows once after an update, never on a fresh install.
void main() {
  test('- a fresh install is not an update', () async {
    SharedPreferences.setMockInitialValues({});
    final seen = ChangelogSeen(await SharedPreferences.getInstance());

    expect(seen.isNewSinceLastLaunch('1.0.0'), isFalse);
  });

  test('- a new version is shown once', () async {
    SharedPreferences.setMockInitialValues({ChangelogSeen.key: '1.0.0'});
    final seen = ChangelogSeen(await SharedPreferences.getInstance());

    expect(seen.isNewSinceLastLaunch('1.1.0'), isTrue);
    await seen.markSeen('1.1.0');
    expect(seen.isNewSinceLastLaunch('1.1.0'), isFalse);
  });
}
