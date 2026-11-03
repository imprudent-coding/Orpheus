<div align="center">

# Orpheus

**A native music player for your self-hosted Jellyfin, Emby or Navidrome server, on Windows, Linux, Android, macOS and iOS, built for libraries behind client-certificate (mTLS) reverse proxies.**

[![Works with Jellyfin](https://img.shields.io/badge/Jellyfin-00A4DC?logo=jellyfin&logoColor=white)](https://jellyfin.org)
[![Works with Emby](https://img.shields.io/badge/Emby-52B54B?logo=emby&logoColor=white)](https://emby.media)
[![Works with Navidrome](https://img.shields.io/badge/Navidrome-1F2A44?logoColor=white)](https://www.navidrome.org)

[![Latest release](https://img.shields.io/github/v/release/imprudent-coding/Orpheus)](https://github.com/imprudent-coding/Orpheus/releases/latest)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue)](./LICENSE)

[Download](#download) · [What Orpheus adds](#what-orpheus-adds) · [Features](#features) · [Development](#development) · [Credits](#credits-and-license)

</div>

---

Orpheus is a music client for [Jellyfin](https://jellyfin.org), [Emby](https://emby.media) and [Navidrome](https://www.navidrome.org) (other OpenSubsonic servers may work, but only Navidrome is tested). It makes your own library feel like a streaming app: fast browsing, offline downloads, lyrics, everyday mixes, and a layout made for each platform.

On top of that, Orpheus is built for servers that are not open to the whole internet. It presents a **client certificate (mTLS)** to servers behind a reverse proxy that requires one, and it can **request music you don't have yet** through [Lyra](https://github.com/imprudent-coding/streamrip). It has no telemetry, crash reporting or cloud relay (see [Privacy](#privacy)).

> [!IMPORTANT]
> Orpheus is a client, not a server. You need a running Jellyfin, Emby or Navidrome server with a music library on it.

## Download

Get the latest build from the [releases page](https://github.com/imprudent-coding/Orpheus/releases/latest).

| Platform | Release asset |
|---|---|
| **Windows** | `windows-setup.exe` (installer) or `windows-portable.zip` |
| **Linux** (x64 and arm64) | `.AppImage`, `.deb`, `.rpm` or `.tar.gz` bundle (`orpheus-linux-*`) |
| **Android** | `orpheus-universal.apk` (sideload) |
| **macOS** | `Orpheus-<version>.dmg`, when the release includes one |
| **iOS** | Not distributed; build it from source |

Orpheus installs side by side with JellyBox: it uses its own application ID (`com.github.imprudentcoding.orpheus`) on every platform. Release builds check this repository for updates.

## What Orpheus adds

### Client certificates (mTLS)

Keep your music server behind a reverse proxy (Caddy, nginx, Traefik…) that only lets in devices with a certificate you issued.

- Import a PKCS#12 file (`.p12` / `.pfx`) when you add a server, or later under **Settings → Client certificate (mTLS)**. It is stored in the system keychain, and its name, issuer and expiry date are shown, with a warning before it expires.
- The certificate is presented only to that server's own addresses (home and remote), never to anyone else. A private CA can be trusted for the server too.
- Everything works through it: browsing, artwork, streaming, downloads, Android Auto, CarPlay and the media controls of each OS. Native players and downloaders go through a loopback proxy inside the app, protected by a random token that is different at every launch.
- If sign-in fails because the server wants a certificate, or refuses the one you gave it, Orpheus tells you so.
- Cast and DLNA are turned off for such a server: those devices fetch the stream themselves and cannot present the certificate.

### Music requests with Lyra

[Lyra](https://github.com/imprudent-coding/streamrip) is a small self-hosted service that searches streaming catalogues and queues downloads for import into your library.

- Set its address under **Settings → Lyra** (one per server). Lyra sits behind the same reverse proxy and gets the same client certificate.
- **Request music** (in the desktop sidebar, or under Settings → Lyra on mobile): search Qobuz, Tidal, Deezer or SoundCloud, then request an album, track or playlist with one tap.
- The **Requests** tab follows each request from queued to downloaded. A downloaded release shows up in your library after the import and the next library scan.

### Privacy

Orpheus removes the JellyBox cloud relay and continuity service, Sentry crash reporting, Plausible analytics and the store review prompt, and turns off Discord Rich Presence. Besides your own servers, it contacts only:

- GitHub, to check for updates;
- [LRCLIB](https://lrclib.net), for lyrics your server doesn't have (on by default, under Settings → Lyrics);
- [ListenBrainz](https://listenbrainz.org), if you connect an account;
- an animated-cover lookup service, if you turn on animated album covers. It receives artist and album names.

## Features

**Library & browsing**
- Jellyfin, Emby and Navidrome (Subsonic API) servers; switch between them without signing out
- Jellyfin Quick Connect: sign in without typing a password
- Albums, artists, genres, playlists and songs across multiple music libraries
- Search everything at once, or only playlists, albums, artists or songs
- Artist pages with biography and discography
- Favourites synced to your server; create and edit playlists from anywhere
- Home page with recently played, recently added and personalised mixes, including genre mixes built from what you play (see [Normalizing your music genres](./docs/normalizing-genres.md) if your genre tags are messy)

**Playback**
- Queue and position remembered between restarts
- Time-synced lyrics
- Shuffle, repeat and a random "surprise me" queue
- Per-connection streaming profiles, with transcoding when a codec isn't supported natively
- Audio quality badge showing whether you're getting the original file
- Landscape now-playing layout on phones
- ListenBrainz scrobbling

**Offline**
- Download albums and tracks
- Full offline mode for your downloads

**Look & feel**
- Colour scheme generated from the current album artwork
- Studio Mode: full-screen animated playback on desktop

**Desktop & system integration**
- Media keys and global keyboard shortcuts
- MPRIS on Linux (GNOME/KDE media controls, `playerctl`)
- Windows media overlay with artwork and transport controls
- AirPlay and system output routing on macOS and iOS
- Cast to DLNA / UPnP renderers (not for servers that need a client certificate)
- Lock screen and notification controls on iOS and Android
- Apple CarPlay and Android Auto (beta)
- In-app changelog from this repository's release notes

## Platform notes

### Windows

The installer is not code-signed, so SmartScreen warns on first run: choose **More info → Run anyway**. The portable zip needs no installation.

### Linux

The bundles expect a few shared libraries. On Debian/Ubuntu:

```bash
sudo apt-get install libmpv-dev mpv libasound2-dev libsecret-1-dev libsqlite3-dev libjsoncpp-dev libcurl4-openssl-dev libdbus-1-dev
```

Importing a certificate uses the system file picker, which needs zenity, kdialog or the XDG desktop portal.

### Android

Allow installs from your browser or file manager, then open the APK. An update installs over the previous version only if both were signed with the same key.

### macOS

The DMG is not notarized unless the release was built with Apple credentials; open it with right-click → **Open** the first time. To use media keys, allow Orpheus under **System Settings → Privacy & Security → Accessibility**.

## Development

**Prerequisites:** [Flutter](https://docs.flutter.dev/get-started/install) with Dart SDK 3.8 or newer, plus the toolchain for your target platform (Visual Studio, Android Studio, Xcode, or the Linux packages above).

```bash
git clone https://github.com/imprudent-coding/Orpheus.git
cd Orpheus
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # freezed, json_serializable, retrofit
flutter run
```

Checks, as CI runs them:

```bash
flutter analyze && flutter test
```

```bash
(cd packages/mtls_proxy && flutter analyze && flutter test)
```

Regenerate the `*.g.dart` and `*.freezed.dart` files with `build_runner` whenever you change a model, DTO or API client; don't edit them by hand.

Where things live:
- `packages/mtls_proxy`: client certificates, their storage and the loopback proxy
- `lib/src/orpheus/`: the app-side mTLS wiring, its settings UI, and the Lyra client and pages
- [SYNC.md](./SYNC.md): how Orpheus stays rebased on upstream JellyBox, and every upstream file it touches
- [docs/orpheus-testing.md](./docs/orpheus-testing.md): the manual test checklist

Bug reports and pull requests are welcome on the [issue tracker](https://github.com/imprudent-coding/Orpheus/issues); see [CONTRIBUTING.md](./CONTRIBUTING.md). Please report problems with Orpheus here, not to the JellyBox developer.

## Credits and license

Orpheus is a modified version of **[JellyBox](https://github.com/avdept/JellyBoxPlayer)** by Alex Sinelnikov / ProdigyTech Inc. and its contributors. Almost everything that makes Orpheus a good music player comes from their work. If you like it, consider [supporting the JellyBox developer](https://www.buymeacoffee.com/avdept).

Orpheus is not affiliated with or endorsed by the JellyBox developers; the name JellyBox is used only to identify the original work. [NOTICE](./NOTICE) lists every change this fork makes.

Like the original, Orpheus is licensed under the [GNU Affero General Public License v3.0](./LICENSE). Copyright © ProdigyTech Inc. and contributors, with modifications by the Orpheus contributors. The original copyright notices are kept intact.
