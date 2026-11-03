// ORPHEUS: the certificate details shown after "Check" in the import dialog.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:jplayer/src/orpheus/client_certificate_ui.dart';
import 'package:mtls_proxy/mtls_proxy.dart';

void main() {
  // S.load sets the default locale to "en", for which intl has no date data
  // until initializeDateFormatting() runs. The app never runs it.
  setUp(() => Intl.defaultLocale = 'en');
  tearDown(() => Intl.defaultLocale = null);

  CertificateDetails details({required DateTime validTo}) => CertificateDetails(
    subject: '/CN=pixel-8/O=Home',
    issuer: '/CN=Home CA',
    validFrom: DateTime.utc(2026),
    validTo: validTo,
  );

  Future<void> pump(WidgetTester tester, CertificateDetails details) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CertificateDetailsView(details: details)),
        ),
      );

  testWidgets('- shows CN, issuer and expiry under the app locale', (
    tester,
  ) async {
    await pump(tester, details(validTo: DateTime.utc(2099, 11, 3, 12)));

    expect(tester.takeException(), isNull);
    expect(find.text('pixel-8'), findsOneWidget);
    expect(find.text('Home CA'), findsOneWidget);
    expect(find.text('Nov 3, 2099'), findsOneWidget);
  });

  testWidgets('- warns about an expired certificate', (tester) async {
    await pump(tester, details(validTo: DateTime.utc(2021, 1, 1, 12)));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('expired on Jan 1, 2021'), findsOneWidget);
  });

  test('- formats dates without initialised locale data', () {
    expect(formatCertificateDate(DateTime.utc(2027, 11, 3, 12)), 'Nov 3, 2027');
  });
}
