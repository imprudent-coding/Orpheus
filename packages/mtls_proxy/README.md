# mtls_proxy

Client-certificate (mTLS) support for Orpheus. Everything here is new code;
the app wires it in at a few hook points marked `// ORPHEUS:` (see `SYNC.md`
at the repository root).

## Pieces

- **`CertificateInspector`** validates a PKCS#12 file and password with the
  platform TLS stack (BoringSSL), and reads the certificate's subject,
  issuer and validity by presenting it on a throwaway loopback TLS socket.
- **`CertificateStore`** keeps the raw PKCS#12 bytes, the password, an
  optional private CA (PEM) and the connection's server URLs in
  `flutter_secure_storage`, one entry per connection ID. Nothing is written
  to logs, shared preferences or plain files.
- **`MtlsProxy`** is the in-memory registry and the single entry point the app
  uses:
  - `contextFor(host, port)` returns the `SecurityContext` carrying the client
    certificate, only for a host:port that belongs to a configured
    connection. The app's `HttpOverrides` use it, so every Dart-side request
    (Dio, `package:http`, `HttpClient`) presents the certificate to that
    server and to nobody else.
  - `resolve(uri)` turns a server URL into a loopback proxy URL for native
    consumers (ExoPlayer, AVPlayer, libmpv, background_downloader, OS media
    shells). URLs of servers without a certificate are returned unchanged.
    Resolve at use time; never persist the result.
- **`MtlsProxyServer`** is the loopback reverse proxy:
  - bound to `127.0.0.1` on an OS-assigned port, plain HTTP;
  - every URL starts with `/<token>/<route>/`. The token is 32 bytes from
    `Random.secure()`, base64url, new at every launch, compared in constant
    time; anything else gets 403, and repeated invalid tokens close the
    listener to new connections for a cooldown;
  - forwards method, headers (minus hop-by-hop), body and query; streams
    both directions; passes status and headers through (206, `Content-Range`,
    ...); rewrites `Location` headers and HLS playlists that point at a
    configured server; bridges WebSocket upgrades;
  - honours the app's certificate trust (user-trusted self-signed
    certificates and pinned fingerprints) through `ServerTrust`;
  - restarts itself (on the same port when possible) when it was killed,
    for example after the app resumes on iOS.
- **`ForegroundDownloader`** downloads a file in-process with the client
  certificate, for platforms where the background downloader cannot reach
  the loopback proxy (iOS while suspended).

## Tests

```bash
flutter test
```

The tests run a local HTTPS server that requires a client certificate. The
throwaway CA, server and client certificates in `test/fixtures` are created
by `test/fixtures/generate.sh`.
