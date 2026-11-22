import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/pin/pin_dialog.dart';

/// Dialog dibuka lewat showDialog seperti di app beneran (bukan dipasang
/// langsung sebagai home — AlertDialog butuh route + constraint layar).
Future<void> _openDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => const PinEntryDialog(),
            ),
            child: const Text('Buka PIN'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Buka PIN'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Dialog PIN menampilkan 6 titik + keypad angka', (tester) async {
    await _openDialog(tester);
    expect(find.text('Masukkan PIN Owner'), findsOneWidget);
    for (final digit in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) {
      expect(find.text(digit), findsOneWidget);
    }
  });

  testWidgets('6 digit tanpa Supabase menampilkan pesan tidak bisa verifikasi',
      (tester) async {
    await _openDialog(tester);
    // Tanpa --dart-define SUPABASE_URL, PinService mengembalikan
    // 'unavailable' — dialog harus gagal tertutup (fail closed).
    for (int i = 0; i < 6; i++) {
      await tester.tap(find.text('1'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('Tidak bisa verifikasi PIN'), findsOneWidget);
    expect(find.text('Masukkan PIN Owner'), findsOneWidget);
  });
}
