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
