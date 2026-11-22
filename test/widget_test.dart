import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/features/kasir/kasir_page.dart';

void main() {
  testWidgets('Kasir menampilkan menu seed', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: KasirPage(role: AppRole.owner))),
    );
    await tester.pump();
    expect(find.text('Es Teh Manis'), findsOneWidget);
    // GridView membangun item secara malas — scroll dulu ke item terakhir.
    await tester.scrollUntilVisible(find.text('Es Teh Boba'), 200);
    await tester.pump();
    expect(find.text('Es Teh Boba'), findsOneWidget);
  });

  testWidgets('Tap Reguler menambah keranjang dan total', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: KasirPage(role: AppRole.owner))),
    );
    await tester.pump();
    await tester.tap(find.text('Reguler').first);
    await tester.pump();
    // Total keranjang berubah dari Rp0 menjadi Rp3.000.
    expect(find.text('Rp3.000'), findsWidgets);
  });
}
