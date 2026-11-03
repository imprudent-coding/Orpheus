# Orpheus manual test checklist

Automated coverage: `flutter test` (app) and `cd packages/mtls_proxy && flutter test`
(proxy against a local HTTPS server that requires a client certificate).
Everything below needs real devices and a real server.

## Test setup

- **Server A:** Jellyfin behind Caddy with mandatory mTLS
  (`client_auth { mode require_and_verify; trusted_ca_cert_file ... }`),
  reachable on a home URL and, ideally, a second remote URL.
- **Server B:** a server without client certificates (plain HTTPS or HTTP on the
  LAN). This checks that upstream behaviour is unchanged.
- **Certificates:** a client `.p12` for A with its password, plus a wrong
  password, an expired `.p12` and a non-PKCS#12 file to test rejection.
  `packages/mtls_proxy/test/fixtures/generate.sh` shows how to make
  throwaway ones.
- Optionally, server A with a private CA or self-signed server certificate, to
  test "Trust a private CA" and the existing "trust this certificate" prompt
  together with mTLS.

## Every platform

| # | Check | Expected |
|---|---|---|
| 1 | Add server A **without** a certificate | Sign-in fails; the error adds "This server asks for a client certificate (mTLS)…" |
| 2 | Login page → **Client certificate** → wrong password | "The password is wrong for this certificate file." |
| 3 | Same with a non-PKCS#12 file / corrupt file | Clear "not a PKCS#12 file" / "damaged" message |
| 4 | Same with the expired `.p12` | Details shown with a red "expired" warning |
| 5 | Correct `.p12` + password | CN, issuer and expiry shown; server type is detected; sign-in works |
| 6 | Browsing: home, albums, artists, playlists, search | All load |
| 7 | Artwork everywhere (grid, player, lock screen / notification / media flyout) | Covers load |
| 8 | Playback: direct play and a transcoded (HLS) track | Plays |
| 9 | Seeking, including far ahead in a long FLAC | Seeks without restarting from 0 |
| 10 | Download an album; then go offline (flight mode) and play it | Plays offline |
| 11 | Settings → Connection → Client certificate (mTLS) | Shows CN/issuer/expiry; Replace, Remove, Trust a private CA work |
| 12 | Remove the certificate | Requests to A fail; re-import fixes them |
| 13 | Add a remote URL for A (Settings → Connection) and make home unreachable | Falls back to remote; the certificate is presented there too |
| 14 | Cast/DLNA picker while on A | Cast and DLNA rows disabled with "needs a client certificate" |
| 15 | Switch to server B | Everything (including Cast/DLNA) behaves as in upstream JellyBox |
| 16 | Settings → Changelog / bell | Shows the release notes of the fork's GitHub release |
| 17 | Update check (sideload builds, older version installed) | Banner offers the fork's newer release with the right asset |
| 18 | Check the device log (Support → Send the app log) | No token, no `127.0.0.1:<port>/<token>` URLs, no certificate data |
| 19 | Restart the app | Certificate still there; playback works (new token) |

## Android

- Background playback with the screen off for 10+ minutes, then skip tracks.
- Android Auto: browse, artwork, play.
- Downloads continue while the app is in the background; kill the app during
  a download and reopen: the download is re-queued by the download sync.
- Home-screen widget artwork.

## iOS

- Background playback: lock the phone, let a few tracks play through
  (the next track is resolved through the proxy while in the background).
- Pause for 10+ minutes in the background, then resume from the lock screen.
- CarPlay: browse, artwork, play.
- Downloads of server A run in the foreground: start an album, keep the app
  open until done; background the app mid-download and verify it fails
  cleanly and is retried later.
- Now-playing widget artwork.
- AirPlay to an AirPlay speaker.

## macOS

- Both the DMG build (unsandboxed) and the App Store-style build (sandboxed):
  file picker opens, proxy can listen (network.server entitlement).
- Media keys and Now Playing artwork.

## Windows

- Playback through libmpv including seeking (Range requests through the proxy).
- SMTC media flyout shows title and artwork.
- Installer installs side by side with JellyBox (different AppId).

## Linux

- Playback through libmpv including seeking.
- MPRIS (GNOME/KDE media controls) shows artwork.
- File picker opens (needs zenity, kdialog or the XDG portal).
- AppImage, .deb, .rpm and flatpak launch as "Orpheus".
