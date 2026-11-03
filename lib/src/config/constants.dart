/// Limit for building a mobile or tablet UI
const int kTabletBreakpoint = 600;

// ORPHEUS: the GitHub repository whose releases the update checker and the
// changelog read. Change only this to point the app at another fork.
const String orpheusGitHubRepository = 'imprudent-coding/Orpheus';

const String changelogTitle = "What's new";

/// True for the direct-download (Developer ID / notarized DMG) build, set via
/// `--dart-define=JELLYBOX_DIRECT_DOWNLOAD=true` in the macOS DMG workflow.
/// Those builds are not sandboxed; the App Store build leaves this false.
const bool kDirectDownloadBuild = bool.fromEnvironment(
  'JELLYBOX_DIRECT_DOWNLOAD',
);

const bool kSideloadBuild = bool.fromEnvironment('JELLYBOX_SIDELOAD');

const String discordApplicationId = '1547587702344388712';

const int connectionsPerHost = 6;
