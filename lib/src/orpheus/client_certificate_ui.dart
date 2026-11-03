// ORPHEUS: client certificate (mTLS) import and management UI, shown in the
// Connection settings of the current server and on the login page.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart' as picker;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:jplayer/src/orpheus/mtls_integration.dart';
import 'package:jplayer/src/presentation/widgets/form_modal.dart';
import 'package:jplayer/src/presentation/widgets/labeled_text_field.dart';
import 'package:jplayer/src/providers/connectivity_provider.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:jplayer/src/providers/server_addresses_provider.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

/// The browser handles client certificates itself on the web.
bool get clientCertificatesSupported => MtlsProxy.instance.isSupported;

typedef _PickedFile = ({String name, Uint8List bytes});

Future<_PickedFile?> _pickFile(List<String> extensions) async {
  final files = await picker.FilePicker.pickFiles(
    dialogTitle: 'Choose a file',
    // Android's document picker greys out .p12/.pem files behind a custom
    // filter on many devices, so it shows every file there.
    type: !kIsWeb && Platform.isAndroid
        ? picker.FileType.any
        : picker.FileType.custom,
    allowedExtensions: !kIsWeb && Platform.isAndroid ? null : extensions,
  );
  final file = files.firstOrNull;
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
}

/// Lets the user pick a PKCS#12 file, enter its password and, optionally, a
/// private CA. Completes with the validated certificate, or null if cancelled.
Future<ClientCertificate?> showClientCertificateImport(
  BuildContext context,
) => showFormModal<ClientCertificate>(
  context,
  builder: (context) => const ClientCertificateImportForm(),
);

class ClientCertificateImportForm extends StatefulWidget {
  const ClientCertificateImportForm({
    this.padding = const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
    super.key,
  });

  final EdgeInsets padding;

  @override
  State<ClientCertificateImportForm> createState() =>
      _ClientCertificateImportFormState();
}

class _ClientCertificateImportFormState
    extends State<ClientCertificateImportForm> {
  final _password = TextEditingController();
  _PickedFile? _file;
  _PickedFile? _ca;
  CertificateDetails? _details;
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _chooseCertificate() async {
    final file = await _pickFile(const ['p12', 'pfx']);
    if (file == null || !mounted) return;
    setState(() {
      _file = file;
      _details = null;
      _error = null;
    });
  }

  Future<void> _chooseCa() async {
    final file = await _pickFile(const ['pem', 'crt', 'cer']);
    if (file == null || !mounted) return;
    setState(() {
      _ca = file;
      _error = null;
    });
  }

  ClientCertificate get _certificate => ClientCertificate(
    pkcs12: _file!.bytes,
    password: _password.text,
    caPem: _ca?.bytes,
  );

  Future<void> _submit() async {
    if (_details != null) {
      Navigator.of(context).pop(_certificate);
      return;
    }
    final file = _file;
    if (file == null) {
      setState(() => _error = 'Choose a .p12 or .pfx file first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final details = await MtlsProxy.instance.inspect(
        file.bytes,
        _password.text,
      );
      final ca = _ca;
      if (ca != null) CertificateInspector.validateCaPem(ca.bytes);
      if (!mounted) return;
      setState(() => _details = details);
    } on CertificateImportException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
    final details = _details;
    return SafeArea(
      top: false,
      minimum: widget.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ModalFormHeader('Client certificate (mTLS)'),
          const SizedBox(height: 8),
          Text(
            'For servers behind a reverse proxy that requires a client '
            'certificate. Import the PKCS#12 file (.p12 or .pfx) issued to '
            'this device. It is stored in the system keychain and only '
            "presented to this server's addresses.",
            style: TextStyle(fontSize: 14, color: muted),
          ),
          const SizedBox(height: 16),
          if (details == null) ...[
            _FileRow(
              label: 'Certificate',
              fileName: _file?.name,
              placeholder: 'No file chosen',
              onChoose: () => unawaited(_chooseCertificate()),
            ),
            const SizedBox(height: 8),
            LabeledTextField(
              controller: _password,
              placeholder: 'Certificate password',
              obscureText: true,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 8),
            _FileRow(
              label: 'Private CA',
              fileName: _ca?.name,
              placeholder: 'Optional, PEM',
              onChoose: () => unawaited(_chooseCa()),
              onClear: _ca == null ? null : () => setState(() => _ca = null),
            ),
          ] else
            CertificateDetailsView(details: details, hasCustomCa: _ca != null),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          ModalFormActions(
            submitLabel: details == null ? 'Check' : 'Use certificate',
            onSubmit: () => unawaited(_submit()),
            busy: _busy,
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.label,
    required this.fileName,
    required this.placeholder,
    required this.onChoose,
    this.onClear,
  });

  final String label;
  final String? fileName;
  final String placeholder;
  final VoidCallback onChoose;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onPrimary.withValues(alpha: 0.7);
    return Row(
      spacing: 8,
      children: [
        SizedBox(
          width: 88,
          child: Text(label, style: TextStyle(color: muted)),
        ),
        Expanded(
          child: Text(
            fileName ?? placeholder,
            overflow: TextOverflow.ellipsis,
            style: fileName == null ? TextStyle(color: muted) : null,
          ),
        ),
        if (onClear != null)
          IconButton(
            tooltip: 'Remove',
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
            icon: const Icon(Icons.close, size: 18),
          ),
        TextButton(onPressed: onChoose, child: const Text('Choose…')),
      ],
    );
  }
}

/// Subject CN, issuer and expiry, with a warning when the certificate has
/// expired or expires within 30 days.
class CertificateDetailsView extends StatelessWidget {
  const CertificateDetailsView({
    required this.details,
    this.hasCustomCa = false,
    super.key,
  });

  final CertificateDetails details;
  final bool hasCustomCa;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
    final date = DateFormat.yMMMd().format(details.validTo.toLocal());
    final warning = details.isExpired
        ? 'This certificate expired on $date. The server will refuse it.'
        : details.expiresSoon
        ? 'This certificate expires on $date. Renew it soon.'
        : null;

    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: TextStyle(color: muted)),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('Issued to', details.commonName),
        row('Issued by', details.issuerCommonName),
        row('Expires', date),
        if (hasCustomCa) row('Private CA', 'Trusted for this server'),
        if (warning != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: details.isExpired
                      ? theme.colorScheme.error
                      : Colors.amber,
                ),
                Expanded(
                  child: Text(
                    warning,
                    style: TextStyle(
                      fontSize: 13,
                      color: details.isExpired
                          ? theme.colorScheme.error
                          : Colors.amber,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Settings > Connection: the current server's client certificate.
class ClientCertificateSettings extends ConsumerWidget {
  const ClientCertificateSettings({super.key});

  static final ButtonStyle _buttonStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final serverId = ref.read(currentServerIdProvider);
    final addresses = ref.read(serverAddressesProvider);
    if (serverId == null || addresses == null) return;
    final certificate = await showClientCertificateImport(context);
    if (certificate == null) return;
    try {
      await MtlsProxy.instance.install(
        serverId,
        certificate: certificate,
        serverUrls: addresses.candidates,
      );
    } on CertificateImportException catch (error) {
      if (context.mounted) _snack(context, error.message);
      return;
    }
    unawaited(ref.read(connectivityProvider.notifier).refresh());
  }

  Future<void> _importCa(BuildContext context, String serverId) async {
    final file = await _pickFile(const ['pem', 'crt', 'cer']);
    if (file == null) return;
    try {
      await MtlsProxy.instance.setCustomCa(serverId, file.bytes);
    } on CertificateImportException catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _remove(BuildContext context, String serverId) async {
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Remove client certificate?'),
        content: const Text(
          'Orpheus will stop presenting it to this server. If the server '
          'requires one, it will refuse the connection.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await MtlsProxy.instance.remove(serverId);
  }

  void _snack(BuildContext context, String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!clientCertificatesSupported) return const SizedBox.shrink();
    ref.watch(mtlsRevisionProvider);
    final serverId = ref.watch(currentServerIdProvider);
    if (serverId == null || ref.watch(serverAddressesProvider) == null) {
      return const SizedBox.shrink();
    }
    final proxy = MtlsProxy.instance;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onPrimary.withValues(alpha: 0.7);

    if (!proxy.hasCertificate(serverId)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Text(
              'No client certificate. Import one if this server requires '
              'mutual TLS (mTLS).',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
          TextButton.icon(
            onPressed: () => unawaited(_import(context, ref)),
            style: _buttonStyle,
            icon: const Icon(Icons.badge_outlined),
            label: const Text('Import client certificate'),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          FutureBuilder<CertificateDetails?>(
            key: ValueKey(ref.watch(mtlsRevisionProvider)),
            future: proxy.details(serverId),
            builder: (context, snapshot) => switch (snapshot) {
              AsyncSnapshot(:final data?) => CertificateDetailsView(
                details: data,
                hasCustomCa: proxy.hasCustomCa(serverId),
              ),
              AsyncSnapshot(hasError: true) => Text(
                'The stored certificate can no longer be read. Replace it.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              _ => const SizedBox(height: 48),
            },
          ),
          Text(
            'Cast and DLNA playback are turned off for this server: those '
            'devices cannot present the certificate.'
            '${!kIsWeb && Platform.isIOS ? ' Downloads from it run while '
                      'Orpheus is open.' : ''}',
            style: TextStyle(fontSize: 13, color: muted),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => unawaited(_import(context, ref)),
                style: _buttonStyle,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Replace'),
              ),
              if (proxy.hasCustomCa(serverId))
                TextButton.icon(
                  onPressed: () => unawaited(proxy.setCustomCa(serverId, null)),
                  style: _buttonStyle,
                  icon: const Icon(Icons.gpp_maybe_outlined),
                  label: const Text('Remove private CA'),
                )
              else
                TextButton.icon(
                  onPressed: () => unawaited(_importCa(context, serverId)),
                  style: _buttonStyle,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Trust a private CA'),
                ),
              TextButton.icon(
                onPressed: () => unawaited(_remove(context, serverId)),
                style: _buttonStyle,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Login page: a client certificate for the server being added. It is held
/// in memory until the sign-in succeeds, then stored for the new account.
class LoginClientCertificate extends ConsumerStatefulWidget {
  const LoginClientCertificate({
    required this.serverUrl,
    required this.urlChanges,
    required this.onChanged,
    super.key,
  });

  /// The server address as the login form currently resolves it.
  final String Function() serverUrl;

  /// Notifies when the address field changes.
  final Listenable urlChanges;

  /// Called after a certificate was staged or dropped, to probe the server
  /// again.
  final Future<void> Function() onChanged;

  @override
  ConsumerState<LoginClientCertificate> createState() =>
      _LoginClientCertificateState();
}

class _LoginClientCertificateState
    extends ConsumerState<LoginClientCertificate> {
  CertificateDetails? _details;

  @override
  void initState() {
    super.initState();
    widget.urlChanges.addListener(_retarget);
  }

  @override
  void dispose() {
    widget.urlChanges.removeListener(_retarget);
    // Sign-in commits a staged certificate as soon as the account exists; one
    // still staged here belongs to a server that was never added.
    MtlsProxy.instance.discardStaged();
    super.dispose();
  }

  void _retarget() {
    final url = widget.serverUrl();
    if (!MtlsProxy.instance.hasStaged || url.isEmpty) return;
    unawaited(
      MtlsProxy.instance.setServerUrls(MtlsProxy.stagedConnectionId, [url]),
    );
  }

  Future<void> _import() async {
    final url = widget.serverUrl();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the server address first.')),
      );
      return;
    }
    final certificate = await showClientCertificateImport(context);
    if (certificate == null) return;
    try {
      final details = await MtlsProxy.instance.stage(
        certificate: certificate,
        serverUrl: url,
      );
      if (!mounted) return;
      setState(() => _details = details);
      await widget.onChanged();
    } on CertificateImportException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _drop() async {
    MtlsProxy.instance.discardStaged();
    setState(() => _details = null);
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (!clientCertificatesSupported) return const SizedBox.shrink();
    final details = _details;
    if (details == null) {
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => unawaited(_import()),
          icon: const Icon(Icons.badge_outlined, size: 18),
          label: const Text('Client certificate'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: CertificateDetailsView(details: details)),
          IconButton(
            tooltip: 'Do not use this certificate',
            onPressed: () => unawaited(_drop()),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
