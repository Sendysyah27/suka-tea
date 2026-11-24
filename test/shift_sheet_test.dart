import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/cash_shift_service.dart';
import 'package:suka_tea/features/laporan/shift_sheets.dart';

/// Tes sheet buka/tutup shift (Batch C7) — sheet murni UI, tidak
/// menyentuh database / Supabase, jadi bisa di-test tanpa backend.
/// Juga regresi pola popSheetSafely: ketik lalu konfirmasi tidak
/// boleh melempar assertion '_dependents.isEmpty' (23 Nov 2026).

Future<void> _pumpOpenSheet(
  WidgetTester tester,
  void Function(int?) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onResult(await showOpenShiftSheet(context));
            },
            child: const Text('Buka shift'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Buka shift'));
  await tester.pumpAndSettle();
  expect(find.text('Buka Shift'), findsOneWidget);
}

Future<void> _pumpCloseSheet(
  WidgetTester tester,
  void Function(CloseShiftInput?) onResult,
) async {
  // `final` (bukan `const`): DateTime(...) bukan konstruktor const,
  // jadi `const CashShift(...)` tidak bisa dikompilasi (CI v31).
  final shift = CashShift(
    id: 'shift-1',
    outletId: 'outlet-1',
    cashierName: 'Budi',
    openedAt: DateTime(2026, 11, 24, 8, 0),
    openingFloat: 50000,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onResult(
                await showCloseShiftSheet(
                  context,
                  shift: shift,
                  expected: 75000,
                  cashIn: 40000,
                  cashExpenses: 15000,
                ),
              );
            },
            child: const Text('Tutup kas'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Tutup kas'));
  await tester.pumpAndSettle();
  expect(find.text('Tutup Kas'), findsOneWidget);
}

void main() {
  testWidgets('Buka shift: ketik modal awal lalu konfirmasi — tanpa error',
      (tester) async {
    int? result;
    await _pumpOpenSheet(tester, (v) => result = v);
    await tester.enterText(find.byType(TextField), '50000');
    await tester.pump();
    await tester.tap(find.textContaining('Buka Shift •'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, 50000);
  });

  testWidgets('Tutup kas: preview expected + selisih live, lalu konfirmasi',
      (tester) async {
    CloseShiftInput? result;
    await _pumpCloseSheet(tester, (v) => result = v);
    // Preview awal: expected Rp75.000, selisih masih -Rp75.000.
    expect(find.textContaining('Rp75.000'), findsWidgets);
    // Ketik uang dihitung Rp74.000 (field pertama = uang dihitung).
    await tester.enterText(find.byType(TextField).first, '74000');
    await tester.pump();
    expect(find.textContaining('Kurang Rp1.000'), findsOneWidget);
    await tester.tap(find.textContaining('Tutup Kas •'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, isNotNull);
    expect(result!.countedCash, 74000);
    expect(result!.note, '');
  });

  testWidgets('Tutup kas: dihitung pas = selisih Rp0, label Pas',
      (tester) async {
    CloseShiftInput? result;
    await _pumpCloseSheet(tester, (v) => result = v);
    await tester.enterText(find.byType(TextField).first, '75000');
    await tester.pump();
    expect(find.textContaining('Pas — tidak ada selisih.'), findsOneWidget);
    await tester.tap(find.textContaining('Tutup Kas •'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result!.countedCash, 75000);
  });
}
