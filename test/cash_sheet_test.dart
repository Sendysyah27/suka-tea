import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/kasir/cash_sheet.dart';

/// Regresi pola yang sama dengan crash diskon 23 Nov 2026 16:01:
/// cash sheet juga punya TextField (nominal manual) + pop langsung
/// dari tombol Konfirmasi — laten crash '_dependents.isEmpty' yang
/// sama. Fix: pop lewat popSheetSafely (lihat sheet_pop.dart).
void main() {
  testWidgets('Ketik nominal manual lalu Konfirmasi — tanpa error',
      (tester) async {
    int? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCashReceivedSheet(context, 19000);
              },
              child: const Text('Buka tunai'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Buka tunai'));
    await tester.pumpAndSettle();
    expect(find.text('Uang diterima'), findsOneWidget);
    // Ketik seperti user: field jadi fokus (keyboard terbuka di HP).
    await tester.enterText(find.byType(TextField), '20000');
    await tester.pump();
    await tester.tap(find.textContaining('Konfirmasi'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, 20000);
  });
}
