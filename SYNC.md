# Keeping Orpheus in sync with upstream JellyBox

Orpheus is a fork of [avdept/JellyBoxPlayer](https://github.com/avdept/JellyBoxPlayer).
The fork is kept as a small, rebase-friendly stack of commits on top of an
upstream release:

1. **Rebrand to Orpheus**: names, bundle/application IDs, packaging.
2. **Remove relay, cloud wiring, Sentry, Plausible, review prompt, Discord**.
3. **Update checker and release workflows for the fork**.
4. **`packages/mtls_proxy`**: new code only, no upstream files.
5. **mTLS hook points and settings UI**: the only commit that wires the new
   package into upstream code.

All new logic lives in `packages/mtls_proxy`. Upstream files are touched only
at a few hook points, each marked with an `// ORPHEUS:` comment (or
`# ORPHEUS:` / `<!-- ORPHEUS: -->` in non-Dart files). To list them:

```bash
git grep -n "ORPHEUS:"
```

## Rebasing onto a new upstream release

```bash
git remote add upstream https://github.com/avdept/JellyBoxPlayer.git
```

```bash
git fetch upstream --tags
```

Rebase the fork's commits onto the release tag (for example `v2.12.0`). The
first argument is the upstream commit the fork currently sits on, which you can
find with `git merge-base main upstream/main` before fetching:

```bash
git rebase --onto v2.12.0 <old-upstream-base> main
```

Resolve conflicts commit by commit. Then run the checks:

```bash
flutter pub get && flutter analyze && flutter test
```

```bash
(cd packages/mtls_proxy && flutter test)
```

```bash
tool/check_no_jellybox_app.sh
```

Things that commonly need attention after a rebase:

- **New `jellybox.app` or relay/cloud code upstream.** The CI check
  `tool/check_no_jellybox_app.sh` fails if a `jellybox.app` reference shows
  up in `lib/` or `packages/`. Remove the new code path the same way commit 2
  did.
- **New network paths.** If upstream adds a new place that hands a server URL
  to native code (a player, a downloader, an OS media shell), route it through
  `MtlsProxy.resolve()` like the existing hook points do. Dart-side requests
  (Dio, `package:http`, `HttpClient`) are covered automatically by the
  `HttpOverrides` hook.
- **Renamed or moved files** in the list below.
- **New platform identifiers** (new extensions, app groups, desktop files).

## Upstream files touched and why

### Commit 1: rebrand

| File | Why |
|---|---|
| `android/app/build.gradle` | `applicationId` changed to `com.github.imprudentcoding.orpheus`. The Kotlin `namespace` is kept as `com.prodigytech.jellybox` on purpose (moving Kotlin sources would conflict on every rebase). |
| `android/app/src/main/AndroidManifest.xml` | App label. |
| `android/app/src/main/res/values/strings.xml` | Widget idle title. |
| `android/fastlane/Fastfile` | Default package name, APK file name. |
| `lib/src/core/android_auto/cover_art_uri.dart` | Cover content-provider authority must equal `${applicationId}.covers`. |
| `lib/src/core/home_widget/now_playing_widget_sync.dart` | iOS app group ID. |
| `ios/Runner.xcodeproj/project.pbxproj`, `ios/Runner/Info.plist` | Bundle IDs (app and `.NowPlayingWidget` extension), display name, local network usage text. |
| `ios/Runner/Runner.entitlements`, `ios/NowPlayingWidgetExtension.entitlements`, `ios/NowPlayingWidget/NowPlayingWidget.swift` | App group `group.com.github.imprudentcoding.orpheus`, widget idle title. |
| `ios/Runner/CarPlaySceneDelegate.swift` | CarPlay title and hint text. |
| `macos/Runner/Configs/AppInfo.xcconfig`, `macos/Runner.xcodeproj/project.pbxproj`, `macos/Runner/Info.plist` | Product name, bundle ID, display name. |
| `macos/Runner/Base.lproj/MainMenu.xib` | `customModule` must match the Swift module name, which follows `PRODUCT_NAME`. |
| `macos/Runner/{Debug,Release}.entitlements` | Keychain access group. |
| `windows/CMakeLists.txt`, `windows/runner/Runner.rc`, `windows/runner/main.cpp` | Executable name, file metadata, window title, AppUserModelID. |
| `windows/installer/jellybox.iss` → `orpheus.iss` | Names, URLs, AppUserModelID and a new `AppId` GUID (so it does not upgrade over JellyBox). |
| `linux/CMakeLists.txt`, `linux/my_application.cc` | Binary name, application ID, window title. |
| `linux/packaging/**` | Desktop entry, AppImage/deb/rpm/flatpak scripts and manifests renamed to the new ID and binary. |
| `web/index.html`, `web/manifest.json` | Title and name. |
| `lib/main.dart` | Device log header. |
| `lib/src/presentation/pages/main_page.dart` | Sidebar title. |
| `lib/src/presentation/pages/support_page.dart` | Support links point at the fork; upstream developer's email and Discord removed. |
| `lib/src/presentation/widgets/{update_banner,server_address_settings,certificate_trust_dialog}.dart` | User-visible strings. |
| `lib/src/data/backend/server_auth_headers.dart`, `lib/src/data/api/subsonic/subsonic_api.dart`, `lib/src/core/listenbrainz/listenbrainz_payload.dart` | Client name reported to servers and ListenBrainz. |
| `lib/src/core/android_auto/android_auto_handler.dart` | Android Auto hint strings. |
| `lib/src/domain/providers/lyrics_provider.dart` | LRCLIB User-Agent names Orpheus and the fork URL. |
| `.github/workflows/*.yaml` | Artifact and binary names. |
| `tool/pull_android_logs.sh` | Package name. |
| `README.md` | Fork notice at the top. |
| tests | Expectations for the renamed client name. |

New files: `NOTICE`, `SYNC.md`.

### Commit 2: remove relay, cloud wiring, Sentry, Plausible, review prompt, Discord

| File | Why |
|---|---|
| `pubspec.yaml`, `pubspec.lock`, `{linux,windows}/flutter/generated_*`, `macos/Flutter/GeneratedPluginRegistrant.swift` | Dropped `sentry_flutter`, `plausible`, `in_app_review` (registrants are regenerated by `flutter pub get`). |
| `lib/main.dart` | No Sentry binding, no telemetry runner, cloud provider not started. |
| `lib/src/core/telemetry/telemetry.dart` | Deleted (Sentry DSN, Plausible host). |
| `lib/src/core/diagnostics/diagnostics.dart` | Console only; `SentryLevel` replaced by a local `DiagnosticLevel`. |
| `lib/src/domain/providers/cast_failure_provider.dart` | Never claims an error report was sent. |
| `lib/src/domain/providers/app_settings_provider.dart`, `lib/src/presentation/pages/settings_page.dart` | Telemetry opt-out and "Jellybox Cloud" sections removed. |
| `lib/src/domain/providers/review_prompt_provider.dart` (+ test), `lib/src/domain/providers/providers.dart`, `lib/src/domain/providers/playback_provider.dart`, `lib/src/presentation/pages/main_page.dart` | Review prompt removed; plugin-notice banner removed from the main page. |
| `lib/src/domain/providers/cloud_provider.dart` | `CloudNotifier` is inert (same public API, empty state, never contacts a service). |
| `lib/src/data/cloud/cloud_host_adapter.dart`, `lib/src/presentation/widgets/{jellybox_cloud_settings,jellybox_cloud_connect_form,continuity_intro,plugin_notice_banner}.dart`, `widgets.dart` | Deleted / exports removed. |
| `lib/src/presentation/widgets/playback_target_picker.dart` | Continuity sign-in row and "share device list" button removed. |
| `lib/src/data/backend/remote_access.dart`, `media_server_client.dart`, `jellyfin/emby/subsonic` clients | `remoteAccess()` (the relay plugin endpoint) removed. |
| `lib/src/providers/server_addresses_provider.dart`, `connectivity_provider.dart`, `auth_provider.dart`, `lib/src/data/storages/account_store.dart`, `lib/src/domain/providers/account_libraries_provider.dart` | Relay address, tunnel pinning, relay probing and plugin notice removed; home + manual remote failover is unchanged. |
| `lib/src/config/constants.dart` | Cloud, relay plugin and tunnel domain constants removed. |
| `lib/src/core/discord/discord_presence_handler.dart` | Rich Presence off unless built with `--dart-define=ORPHEUS_DISCORD_PRESENCE=true`. |
| `packages/optional_features/pubspec.yaml` | Homepage. |
| `.github/actions/optional-features/` | Deleted; every workflow step that used it removed. |
| `.github/workflows/tests.yaml` | Runs the `jellybox.app` check and `flutter analyze` (errors only). |
| tests | Relay/review/telemetry tests removed; failover tests now use the manual remote address. |

New file: `tool/check_no_jellybox_app.sh`.

### Commit 3: update checker and release workflows

| File | Why |
|---|---|
| `lib/src/config/constants.dart` | `orpheusGitHubRepository = 'imprudent-coding/Orpheus'`, the single place that names the repo; `updatifyProjectId` removed. |
| `lib/src/core/updates/release_checker.dart` | Uses the fork's repo; can read release notes; Windows links `windows-setup.exe`. |
| `lib/src/presentation/widgets/updatify_bell.dart` | Same class name, now opens the GitHub release notes; the dot marks an available update. |
| `lib/src/presentation/pages/main_page.dart`, `settings_page.dart` | Changelog dialog instead of updatify popup/sheet. |
| `pubspec.yaml`, `pubspec.lock` | `updatify_flutter` removed. |
| `android/fastlane/Fastfile` | Builds with the debug key (with a warning) when no keystore is configured. |
| `.github/workflows/android-beta.yaml` | Play upload only when `PLAY_SERVICE_ACCOUNT_JSON` is set. |
| `.github/workflows/{ios,macos}-beta.yaml` | TestFlight skipped when the App Store Connect / match secrets are missing. |
| `.github/workflows/macos-dmg.yaml` | Developer ID signing + notarization only with secrets; otherwise ad-hoc signed DMG. |
| `.github/workflows/macos-dmg-renderer-test.yaml` | Deleted (manual upstream diagnostic that needs upstream's Apple secrets). |
| tests | Release checker tests use the fork's repo and asset names and a mocked GitHub API. |

New files: `lib/src/domain/providers/changelog_provider.dart`,
`lib/src/presentation/widgets/changelog_dialog.dart`,
`test/domain/providers/changelog_provider_test.dart`.

## Release assets the update checker expects

The checker reads `GET /repos/imprudent-coding/Orpheus/releases/latest`,
ignores drafts and prereleases, compares `tag_name` (`v1.2.3`, an optional
`+build` is ignored) with the installed version, and links:

| Platform | Asset it looks for | Produced by |
|---|---|---|
| Android | first asset ending in `.apk` | `android-beta.yaml` → `orpheus-universal.apk` |
| macOS (DMG build) | first asset ending in `.dmg` | `macos-dmg.yaml` → `Orpheus-<version>.dmg` |
| Windows | first asset ending in `.exe` | `windows-release.yaml` → `windows-setup.exe` |
| Linux | none, opens the release page | `linux-release.yaml` → `orpheus-linux-*.{tar.gz,AppImage,deb,rpm}` |
| iOS / App Store builds | no update check | |

Only builds made with `--dart-define=JELLYBOX_SIDELOAD=true` check for updates
(the Linux, Windows, macOS DMG workflows and the Android APK lane set it).
The changelog shows the release body of the tag matching the installed
version (`v<version>`), falling back to the latest release.

## Release workflow configuration

`release.yaml` (tag push `v*` or manual dispatch) creates a draft release,
runs every platform leg, and publishes the release when all legs succeed.
Linux, Windows, Android (debug-signed) and macOS (ad-hoc signed) build with
no secrets at all. Configure these for proper releases:

| Secret / variable | Used for |
|---|---|
| `ANDROID_KEYSTORE_ENV_VAR` (base64 .jks), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` | Stable Android signing. Without them every CI run uses a new debug key and users cannot update in place. |
| `PLAY_SERVICE_ACCOUNT_JSON`, vars `PACKAGE_NAME`, `PLAY_TRACK` | Optional Play upload. |
| `APPSTORE_P8_KEY_CONTENT` (base64), `APPSTORE_KEY_ID`, `APPSTORE_KEY_ISSUER_ID` | Notarization and TestFlight. |
| `MATCH_PASSWORD`, `GIT_AUTHORIZATION`, vars `GIT_USERNAME`, `GIT_REPOSITORY` | fastlane match repository with your Developer ID / App Store certificates. |
| vars `APP_IDENTIFIER` (`com.github.imprudentcoding.orpheus`), `APPLE_ID`, `TEAM_ID`, `ITC_TEAM_ID` | fastlane / App Store Connect. Also set `DEVELOPMENT_TEAM` in the Xcode projects to your team (upstream's `RVM9F3VSHV` is still there). |

`GITHUB_TOKEN` is provided automatically.

### Commit 4: `packages/mtls_proxy`

Only new files under `packages/mtls_proxy/` (see its README), plus a
`tests.yaml` step that analyzes and tests the package. No upstream code is
touched. Regenerate the test certificates with
`packages/mtls_proxy/test/fixtures/generate.sh`.

### Commit 5: mTLS hook points and settings UI

New app files (fork-owned, safe on rebase): `lib/src/orpheus/mtls_integration.dart`
(all glue), `lib/src/orpheus/client_certificate_ui.dart` (import dialog,
settings section, login section), `test/orpheus/mtls_integration_test.dart`,
`android/app/src/main/res/xml/network_security_config.xml`,
`docs/orpheus-testing.md`.

| Upstream file | Hook |
|---|---|
| `pubspec.yaml`, `pubspec.lock`, generated plugin registrants | `mtls_proxy` (path) and `file_picker`. |
| `lib/main.dart` | `initOrpheusMtls(container)` right after the provider container exists, before anything makes a request. Loads certificates, starts the proxy, keeps certificates in step with saved accounts. |
| `lib/src/core/network/certificate_trust.dart` | `TrustedCertificateHttpOverrides.connectionFactory` uses `MtlsProxy.instance.contextFor(host, port)`: every Dart-side request (Dio, `package:http`, artwork cache, probes) presents the client certificate to that connection's hosts and to nobody else. |
| `lib/src/domain/providers/playback_provider.dart` | Playback precedence (below) and a guard in `switchTarget` that refuses Cast/DLNA targets for certificate servers. |
| `lib/src/data/services/download_service.dart`, `lib/src/core/downloads/cache_downloader.dart` | Proxy URL resolved at the moment a download starts (never stored); foreground download on iOS. |
| `lib/src/presentation/widgets/playback_target_picker.dart` | Cast and DLNA rows disabled with an explanation for certificate servers. |
| `lib/src/presentation/pages/settings_page.dart` | "Client certificate (mTLS)" section under Connection. |
| `lib/src/presentation/pages/login_page.dart` | Certificate import while adding a server; sign-in errors explain a missing client certificate. |
| `android/app/src/main/AndroidManifest.xml` | `networkSecurityConfig` (cleartext to 127.0.0.1; upstream's cleartext behaviour kept, see the file). |
| `macos/Runner/{Debug,Release}.entitlements` | `files.user-selected.read-only` for the file picker in the sandboxed build (`network.server` was already there). |
| `ios/Runner/Info.plist`, `macos/Runner/Info.plist` | Comment only: why `NSAllowsLocalNetworking` must not be added. |

## How mTLS is wired

- **Storage.** The real server URLs stay in every store, exactly as upstream
  keeps them. Certificates live in secure storage under the account's server
  ID (`orpheus_mtls_*` keys), together with the account's home and remote
  URLs. Proxy URLs exist only in memory, resolved at the moment of use.
- **Dart-side requests** get the certificate in the TLS handshake through the
  app's `HttpOverrides` (no URL rewriting): Dio/Retrofit API calls, login
  probes, connectivity probes, artwork (`flutter_cache_manager`), Android
  Auto and CarPlay artwork (both go through the Dart artwork cache), the
  home-screen widget.
- **Native consumers** get a loopback proxy URL from `MtlsProxy.resolve()`:
  just_audio (ExoPlayer, AVPlayer), just_audio_media_kit (libmpv on
  Windows/Linux), background_downloader, and the OS media shells that load
  artwork by URL (SMTC, MPRIS).
- **Cast and DLNA** devices fetch streams themselves and can neither present
  the certificate nor reach the phone's loopback, so they are disabled for
  certificate servers.

### Playback precedence

At the playback hook (`PlaybackNotifier`, where the stream URL for the local
player is built):

1. If the stream's server has a client certificate, the **mTLS proxy** serves
   it. The mTLS proxy honours `CertificateTrust` (user-trusted self-signed
   certificates and pinned fingerprints), so a server using both works.
2. Otherwise upstream's **StreamProxyServer** serves it exactly as before.

The two are never chained. One consequence: StreamProxyServer's mid-stream
fallback between home and remote address (its "location" mode) is not used
for certificate servers; each track is resolved against the address the
connectivity check currently prefers.

## Known limitations

- **iOS downloads** from certificate servers run in the foreground (in the
  app) instead of through background_downloader: iOS suspends the app, and
  with it the loopback proxy, while a background download continues in a
  system daemon. Such downloads pause when the app is suspended and need to
  be restarted (the download sync picks them up again). Pause/resume is not
  available for them.
- **Background playback on iOS** keeps working because the audio background
  mode keeps the app (and the proxy) running while audio plays. After a long
  pause the app may be suspended; the proxy is restarted on resume (on the
  same port when possible) and before each track is resolved.
- **Android** downloads go through the proxy, which lives in the app process:
  they stop if Android kills the app.
- **Cast and DLNA** are unavailable for certificate servers. AirPlay video
  hand-off of a URL would hit the same wall; AirPlay audio streams from the
  phone and works.
- **Token exposure:** the proxy URL (with its per-launch token) is visible to
  other processes of the same user where the OS publishes now-playing
  artwork by URL (MPRIS on Linux, SMTC on Windows). The token only unlocks
  the configured servers, only on 127.0.0.1, and only until the app quits.
- **Cooldown:** another app spamming the proxy with wrong tokens can trigger
  the cooldown (30 bad requests in 10 s close the listener for 10 s), which
  interrupts playback for that time.
- **Web:** the import UI is hidden and the proxy never starts; the browser
  handles client certificates. Upstream's web target does not run in any
  case (`main()` uses `dart:io` `Platform` unconditionally).
- **Certificate replacement** takes effect for new connections at once;
  pooled keep-alive connections of the API client are reused until they idle
  out (about 15 s).
- A certificate is presented on TLS 1.3 only when the server asks for one,
  and only to the exact host:port of the connection's home and remote
  address. A server reached through a different name or port (for example a
  redirect to another host) does not get it.

## Icons to replace

Icon files were left as they are. Replace these to rebrand the artwork:

- Android: `android/app/src/main/res/mipmap-*/ic_launcher.png` (launcher)
  and `android/app/src/main/res/drawable-*/ic_stat_music.png` (notification)
- iOS: `ios/Runner/Assets.xcassets/AppIcon.appiconset/*`
- macOS: `macos/Runner/Assets.xcassets/AppIcon.appiconset/*`,
  `macos/Runner/Assets.xcassets/appstore.png`
- Windows: `windows/runner/resources/app_icon.ico`
- Linux: `linux/packaging/jellybox.png` (installed as `orpheus.png` /
  `com.github.imprudentcoding.orpheus.png` by the packaging scripts)
- Web: `web/favicon.png`, `web/icons/*`
- In-app login logo: `assets/images/jellybox_logo.svg`
- README artwork: `docs/logo.png`, `docs/screenshots/*`
