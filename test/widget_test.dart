import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/features/kasir/kasir_page.dart';

void main() {
  testWidgets('Kasir menampilkan menu seed', (tester) async {
    // Viewport tinggi supaya GridView membangun semua 8 item seed.
    // (scrollUntilVisible tidak bisa dipakai: ada 2 Scrollable di layar.)
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: KasirPage(role: AppRole.owner))),
    );
    await tester.pump();
    expect(find.text('Es Teh Manis'), findsOneWidget);
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
