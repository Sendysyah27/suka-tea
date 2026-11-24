import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/data/sale_history.dart';
import 'package:suka_tea/data/stock_service.dart';
import 'package:suka_tea/features/gerai/gerai_monitor_page.dart';

/// Pantau Gerai + sinkronisasi (Batch C6).
///
/// Catatan test env: Supabase TIDAK terkonfigurasi di test (init
/// tidak dipanggil, isConfigured false), jadi pull live gagal dan
/// halaman HARUS jatuh ke data lokal + label 'data lokal' — itulah
/// yang dites di sini. Jalur live (pull berhasil -> label
/// 'Live Supabase') butuh Supabase + Edge Function — diverifikasi
/// manual di HP, bukan di sini.
void main() {
  setUpAll(() async {
    // Pola yang sama dengan login_page_test: Drift butuh
    // path_provider yang TIDAK ada di test env — mock ke folder
    // temp sungguhan supaya SQLite benar-benar terbuka di CI.
    final dir = Directory.systemTemp.createTempSync('suka-tea-sync-test');
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
    await StockService.instance.init();
  });

  testWidgets('offline: tampil data lokal, tanpa crash', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GeraiMonitorPage(
          outlet: OutletService.instance.outlets.first,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Label sumber data = lokal (pull gagal karena Supabase
    // tidak terkonfigurasi di test).
    expect(find.textContaining('data lokal'), findsOneWidget);
    // Tidak ada label live.
    expect(find.textContaining('Live Supabase'), findsNothing);
    // Belum ada transaksi di test env.
    expect(find.text('Belum ada transaksi hari ini di gerai ini.'),
        findsOneWidget);
  });

  testWidgets('tombol refresh ada dan tidak crash saat ditekan',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GeraiMonitorPage(
          outlet: OutletService.instance.outlets.first,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Muat ulang data live'), findsOneWidget);
    await tester.tap(find.byTooltip('Muat ulang data live'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('data lokal'), findsOneWidget);
  });
}
