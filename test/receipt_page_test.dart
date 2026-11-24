import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/features/kasir/receipt.dart';

void main() {
  testWidgets('Struk tampil: tagline baru + LUNAS + tombol Bagikan',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DigitalReceiptPage(
          lines: const [
            ReceiptLine(
              name: 'Red Velvet Milktea 22oz',
              modifierText: '(Kurang Manis, Sedikit Es, +Selasih)',
              qty: 1,
              unitPrice: 9000,
            ),
          ],
          method: PaymentMethod.tunai,
          total: 9000,
          paid: 10000,
          time: DateTime(2026, 11, 23, 12, 56),
        ),
      ),
    );
    expect(find.text('SUKA TEA'), findsOneWidget);
    expect(find.text('Es Teh Kekinian'), findsOneWidget);
    expect(find.text('LUNAS'), findsOneWidget);
    expect(find.text('Bagikan'), findsOneWidget);
    expect(find.text('Simpan PDF'), findsOneWidget);
    expect(find.text('Rp9.000'), findsWidgets);
    expect(find.text('Rp10.000'), findsOneWidget);
    expect(find.text('Rp1.000'), findsOneWidget);
  });
}
