import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/features/kasir/kasir_page.dart';

void main() {
  testWidgets('Kasir menampilkan menu seed poster (20 produk)', (tester) async {
    // Viewport tinggi supaya GridView membangun semua 20 item seed.
    // (scrollUntilVisible tidak bisa dipakai: ada 2 Scrollable di layar.)
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: KasirPage(role: AppRole.owner))),
    );
    await tester.pump();
    expect(find.text('Manggo Milktea'), findsOneWidget);
    expect(find.text('Es Teh Green Tea'), findsOneWidget);
    expect(find.text('Es Teh Jumbo'), findsOneWidget);
  });

  testWidgets('Tap Reguler menambah keranjang dan total', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: KasirPage(role: AppRole.owner))),
    );
    await tester.pump();
    await tester.tap(find.text('Reguler').first);
    await tester.pump();
    // Total keranjang berubah dari Rp0 menjadi Rp8.000
    // (Reguler pertama = Manggo Milktea, harga poster 8K).
    expect(find.text('Rp8.000'), findsWidgets);
  });

  testWidgets('Kasir landscape pendek: panel keranjang tidak overflow',
      (tester) async {
    // Repro bug 22 Nov 22:19: POVA landscape, panel Keranjang kanan
    // overflow 61px (chip 2 baris + Total + Bayar 56 tidak muat di
    // tinggi konten ~280dp). Lebar 1000 = layout wide (>= 840),
    // tinggi 300 = mode pendek (< 430) di _CartPanel.
    tester.view.physicalSize = const Size(1000, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: KasirPage(role: AppRole.owner))),
    );
    await tester.pump();
    // Tidak ada error overflow (RenderFlex) saat pump.
    expect(tester.takeException(), isNull);
    // Tombol Bayar tetap ada (tidak kepotong di bawah layar).
    expect(find.text('Bayar • Rp0'), findsOneWidget);
  });
}
