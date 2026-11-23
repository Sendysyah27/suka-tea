import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/kasir/discount_sheet.dart';

/// Regresi crash layar merah 23 Nov 2026 16:01 (Sendy): sesudah ketik
/// nominal diskon lalu tap "Terapkan diskon", app menampilkan layar
/// merah assertion '_dependents.isEmpty' — route sheet di-pop saat
/// TextField masih fokus + keyboard masih terbuka. Fix: pop lewat
/// popSheetSafely (unfocus + tunggu satu frame + guard mounted).
/// Tes ini memompa sheet beneran, mengetik, lalu menekan Terapkan —
/// bila pola lama kembali, tester.takeException() != null.
Future<DiscountResult?> _openAndApply(
  WidgetTester tester, {
  required int subtotal,
  int currentDiscount = 0,
  int currentPercent = 0,
  required String typed,
  bool percentMode = false,
}) async {
  DiscountResult? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDiscountSheet(
                context,
                subtotal: subtotal,
                currentDiscount: currentDiscount,
                currentPercent: currentPercent,
              );
            },
            child: const Text('Buka diskon'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Buka diskon'));
  await tester.pumpAndSettle();
  expect(find.text('Diskon manual'), findsOneWidget);
  if (percentMode) {
    await tester.tap(find.text('Persen (%)'));
    await tester.pump();
  }
  // Ketik seperti user: field jadi fokus (keyboard terbuka di HP).
  await tester.enterText(find.byType(TextField), typed);
  await tester.pump();
  await tester.tap(find.textContaining('Terapkan diskon'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('Regresi crash: ketik nominal Rp lalu Terapkan — tanpa error',
      (tester) async {
    final result = await _openAndApply(
      tester,
      subtotal: 21000,
      typed: '2000',
    );
    expect(tester.takeException(), isNull);
    expect(result, isNotNull);
    expect(result!.amount, 2000);
    expect(result!.percent, 0);
  });

  testWidgets('Regresi crash: mode persen 10% dari Rp21.000 = Rp2.100',
      (tester) async {
    final result = await _openAndApply(
      tester,
      subtotal: 21000,
      typed: '10',
      percentMode: true,
    );
    expect(tester.takeException(), isNull);
    expect(result, isNotNull);
    expect(result!.amount, 2100);
    expect(result!.percent, 10);
  });

  testWidgets('Sheet dibuka dengan persen tersimpan: mode % aktif',
      (tester) async {
    DiscountResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDiscountSheet(
                  context,
                  subtotal: 21000,
                  currentDiscount: 2100,
                  currentPercent: 10,
                );
              },
              child: const Text('Buka diskon'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Buka diskon'));
    await tester.pumpAndSettle();
    // Field sudah berisi 10 (persen), tombol menampilkan (10%).
    expect(find.textContaining('10%'), findsWidgets);
    await tester.tap(find.textContaining('Terapkan diskon'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result!.amount, 2100);
    expect(result!.percent, 10);
  });
}
