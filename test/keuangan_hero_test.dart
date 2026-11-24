import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/money.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/data/expense_service.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/data/sale_history.dart';
import 'package:suka_tea/data/seed_menu.dart';
import 'package:suka_tea/data/stock_service.dart';
import 'package:suka_tea/features/keuangan/keuangan_page.dart';

/// Batch C10.1 — hero Keuangan (Bug 2a + 2b):
/// (2a) label "Laba (estimasi)" + nilai TIDAK BOLEH kepotong di
/// layar sempit (360dp) + text scale besar (screenshot Sendy
/// 24 Nov 20:08: "Laba (estimasi" terpotong di tepi kanan kartu
/// hijau). Nilai yang mengecil/ellipsis, bukan label yang hilang.
/// (2b) bila biaya bahan belum diatur, HPP tampil "belum diatur"
/// dan laba tampil "—", bukan Rp0.
///
/// CATATAN: semua tulis Drift (updateCost + recordSale) dilakukan
/// di setUpAll — BUKAN di dalam testWidgets. `driftDatabase`
/// (drift_flutter) menjalankan SQLite di background isolate, dan
/// await Drift di dalam zona fake-async testWidgets TIDAK PERNAH
/// kembali (terbukti hang 24 Nov: updateCost tidak selesai dalam
/// 30 detik). Body testWidgets hanya pump + tap + assert.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SaleRecord recordGerai1;

  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('suka-tea-c10-1-hero-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        switch (call.method) {
          case 'getTemporaryDirectory':
          case 'getApplicationDocumentsDirectory':
          case 'getApplicationSupportDirectory':
            return dir.path;
          default:
            return null;
        }
      },
    );
    await OutletService.instance.init();
    await SaleHistoryService.instance.init();
    await ExpenseService.instance.init();
    await StockService.instance.init();

    // Data tes (zona async asli — lihat catatan di atas):
    // Gerai 1: 1 cup Manggo Rp999.999.999 + biaya Teh Masak diisi
    // (HPP/laba tampil sebagai angka). Gerai 2: 1 cup Manggo
    // Rp75.000, biaya TIDAK diisi (HPP "belum diatur").
    await StockService.instance.updateCost('Teh Masak', 30000);
    final manggo = seedMenu().firstWhere((p) => p.id == 'manggo-milktea');
    Future<SaleRecord> sellManggo({
      required int total,
      required String outletId,
    }) =>
        SaleHistoryService.instance.recordSale(
          items: [
            CartItem(product: manggo, variant: manggo.variants.first, qty: 1),
          ],
          total: total,
          method: PaymentMethod.tunai,
          paid: total,
          outletId: outletId,
        );
    recordGerai1 = await sellManggo(
      total: 999999999,
      outletId: '00000000-0000-0000-0000-000000000001',
    );
    await sellManggo(
      total: 75000,
      outletId: '00000000-0000-0000-0000-000000000002',
    );
  });

  const gerai1 = '00000000-0000-0000-0000-000000000001';

  Future<void> pumpKeuangan(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.5),
              ),
              child: const KeuanganPage(role: AppRole.owner),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectGerai(WidgetTester tester, String geraiName) async {
    await tester.tap(find.text('Semua gerai'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(geraiName));
    await tester.pumpAndSettle();
  }

  testWidgets('2a: omzet besar + text scale 1.5 -> hero TIDAK overflow',
      (tester) async {
    await pumpKeuangan(tester);
    await selectGerai(tester, 'Gerai 1 — Stand Utama');

    // Hero: label utuh + omzet + laba terhitung tampil.
    expect(find.text('Omzet hari ini'), findsOneWidget);
    // Omzet muncul 2x (hero + baris Tunai) bila baris Tunai ikut
    // ter-build — yang penting nilainya ada.
    expect(find.text('Rp999.999.999'), findsWidgets);
    expect(find.text('Laba (estimasi)'), findsOneWidget);
    final stats = computeDailyStats(
      [recordGerai1],
      StockService.instance.recipes,
      StockService.instance.costsByNameFor(gerai1),
    );
    expect(find.text(formatRupiah(stats.labaEstimate)), findsOneWidget);
    // TIDAK ADA RenderFlex overflow (atau error render lain).
    expect(tester.takeException(), isNull);
  });

  testWidgets('2b: biaya belum diatur -> HPP "belum diatur", laba "—"',
      (tester) async {
    await pumpKeuangan(tester);
    await selectGerai(tester, 'Gerai 2');

    // Hero: laba BUKAN angka (tidak boleh Rp0 yang menyesatkan).
    expect(find.text('Laba (estimasi)'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Rp75.000'), findsWidgets);

    // Scroll ke seksi Biaya — HPP + penjelasan tampil jujur.
    await tester.scrollUntilVisible(
      find.text('belum diatur'),
      500,
    );
    await tester.pumpAndSettle();
    expect(find.text('belum diatur'), findsOneWidget);
    expect(
      find.textContaining('Harga bahan belum diatur'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
