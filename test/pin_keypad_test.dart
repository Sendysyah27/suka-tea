import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/pin/pin_keypad.dart';

/// PinKeypad mode compact (redesain login 23 Nov 2026 — perintah
/// Sendy: keypad lama terlalu besar). Tombol compact 72px, lebar
/// total 232px; mode normal (dialog PIN Kasir) tidak berubah.
void main() {
  testWidgets('compact: tombol 72x72', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinKeypad(
            compact: true,
            onDigit: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byType(InkWell).first),
      const Size(
        PinKeypad.compactKeySize,
        PinKeypad.compactKeySize,
      ),
    );
    expect(PinKeypad.compactKeySize, 72);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal (default): tombol lebih besar dari compact',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinKeypad(
            onDigit: (_) {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    final size = tester.getSize(find.byType(InkWell).first);
    expect(size.width, greaterThan(PinKeypad.compactKeySize));
    expect(size.width, size.height);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact: tap digit + Hapus memanggil callback',
      (tester) async {
    var digits = '';
    var backspaces = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinKeypad(
            compact: true,
            onDigit: (d) => digits += d,
            onBackspace: () => backspaces++,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('5'));
    await tester.tap(find.text('Hapus'));
    await tester.pump();
    expect(digits, '5');
    expect(backspaces, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled: tap digit tidak memanggil onDigit',
      (tester) async {
    var digits = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinKeypad(
            compact: true,
            enabled: false,
            onDigit: (d) => digits += d,
            onBackspace: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('7'));
    await tester.pump();
    expect(digits, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
