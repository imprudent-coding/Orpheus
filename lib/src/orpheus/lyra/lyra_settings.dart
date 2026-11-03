// ORPHEUS: Settings > Lyra: the current server's Lyra address.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:jplayer/src/config/routes.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_client.dart';
import 'package:jplayer/src/orpheus/lyra/lyra_providers.dart';
import 'package:jplayer/src/orpheus/mtls_integration.dart';
import 'package:jplayer/src/presentation/widgets/labeled_text_field.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

/// Opens the Lyra request page, searching for [query] when given. From
/// Browse it stays in the Browse tab; from anywhere else it opens under
/// Settings.
void openLyra(BuildContext context, {String? query}) {
  final router = GoRouter.of(context);
  final location = router.routerDelegate.currentConfiguration.uri.path;
  final route = location.startsWith(Routes.browse.path)
      ? Routes.browseLyra
      : Routes.lyra;
  final trimmed = query?.trim() ?? '';
  unawaited(
    router.pushNamed(
      route.name,
      queryParameters: {if (trimmed.isNotEmpty) 'q': trimmed},
    ),
  );
}

class LyraSettings extends ConsumerStatefulWidget {
  const LyraSettings({super.key});

  @override
  ConsumerState<LyraSettings> createState() => _LyraSettingsState();
}

class _LyraSettingsState extends ConsumerState<LyraSettings> {
  static final ButtonStyle _buttonStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  final _address = TextEditingController();
  (String, Uri?)? _shown;
  String? _message;
  var _messageIsError = false;
  var _busy = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  /// Fills the field with the saved address when the server or the saved
  /// address changes (including when the settings finish loading).
  void _syncField(String serverId, Uri? saved) {
    final shown = (serverId, saved);
    if (_shown == shown) return;
    if (_shown?.$1 != serverId) _message = null;
    _shown = shown;
    _address.text = saved?.toString() ?? '';
  }

  Future<void> _save(String serverId) async {
    final text = _address.text;
    final url = parseLyraUrl(text);
    if (url == null) {
      setState(() {
        _message = text.trim().isEmpty
            ? 'Enter the Lyra address, for example https://lyra.example.com'
            : 'This is not a valid http(s) address.';
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    await ref.read(lyraUrlsProvider.notifier).set(serverId, url);
    _address.text = url.toString();
    try {
      // The certificate is attached as soon as the address is saved, so the
      // test already goes through the reverse proxy like real use.
      final info = await LyraClient(url).info();
      if (!mounted) return;
      setState(() {
        _message =
            'Connected. Sources: ${info.sources.join(', ')}.'
            '${info.artistDownloads ? ' Whole-artist downloads are allowed.' : ''}';
        _messageIsError = false;
      });
    } on LyraException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = 'Saved, but the test failed: ${error.message}';
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String serverId) async {
    await ref.read(lyraUrlsProvider.notifier).set(serverId, null);
    if (!mounted) return;
    setState(() {
      _address.clear();
      _message = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final serverId = ref.watch(currentServerIdProvider);
    if (serverId == null) return const SizedBox.shrink();
    ref.watch(mtlsRevisionProvider);
    final saved = ref.watch(lyraUrlProvider);
    _syncField(serverId, saved);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
    final proxy = MtlsProxy.instance;
    final certificateNote = !proxy.isSupported
        ? null
        : proxy.hasCertificate(serverId)
        ? "Orpheus presents this server's client certificate to Lyra too."
        : 'This server has no client certificate, so Lyra is reached '
              'without one.';

    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text(
              'Request music that is not in your library yet. Lyra searches '
              'streaming catalogues and downloads releases for import.',
              style: TextStyle(fontSize: 13, color: muted),
            ),
            LabeledTextField(
              controller: _address,
              placeholder: 'https://lyra.example.com',
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
            ),
            if (certificateNote != null)
              Text(
                certificateNote,
                style: TextStyle(fontSize: 13, color: muted),
              ),
            if (_message case final message?)
              Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  color: _messageIsError ? theme.colorScheme.error : muted,
                ),
              ),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : () => unawaited(_save(serverId)),
                  style: _buttonStyle,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Save and test'),
                ),
                if (saved != null) ...[
                  TextButton.icon(
                    onPressed: () => openLyra(context),
                    style: _buttonStyle,
                    icon: const Icon(Icons.library_add_outlined),
                    label: const Text('Request music'),
                  ),
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_remove(serverId)),
                    style: _buttonStyle,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
