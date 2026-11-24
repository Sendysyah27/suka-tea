import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/brew_service.dart';
import 'package:suka_tea/data/local/outbox_service.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/data/stock_service.dart';
import 'package:suka_tea/data/sync_payload.dart';

/// Batch C10.1 Bug 2b — sentinel biaya -1 ("belum diatur") harus
/// bertahan dari ujung ke ujung (payload -> normalizer -> EF -> pull
/// -> merge), supaya HPP tidak pernah lagi jadi Rp0 karena biaya
/// yang belum diatur ke-clamp jadi 0 di tengah jalan (laporan Sendy
/// 24 Nov 20:08: omzet Rp75.000 / 12 cup, HPP -Rp0).
///
/// Aturan yang ditegakkan di sini (server 0 = tidak ada info biaya):
/// - mutasi stok hanya membawa cost_per_unit bila > 0;
/// - merge hanya mengadopsi biaya server bila > 0;
/// - backfill seed mengisi bahan yang masih -1;
/// - brew memakai estimasi seed Teh Kering bila biayanya belum diatur.
void main() {
  group('planStockMerge — biaya server 0 = tidak ada info', () {
    const gerai1 = '00000000-0000-0000-0000-000000000001';
    StockItem item(String name, double cost, {double qty = 10}) => StockItem(
          name: name,
          unit: 'kg',
          qty: qty,
          lowThreshold: 1,
          costPerUnit: cost,
          outletId: gerai1,
        );

    test('server 0 TIDAK menimpa biaya lokal yang sudah diatur', () {
      final plan = planStockMerge(
        local: [item('Gula', 18000)],
        server: [item('Gula', 0)],
        outletId: gerai1,
        touchedKeys: {stockTouchedKey(gerai1, 'Gula')},
        pendingNames: {},
      );
      expect(plan.toUpdate.single.costPerUnit, 18000);
    });

    test('server 0 TIDAK menimpa -1 lokal (tetap "belum diatur")', () {
      final plan = planStockMerge(
        local: [item('Teh Masak', -1)],
        server: [item('Teh Masak', 0)],
        outletId: gerai1,
        touchedKeys: {stockTouchedKey(gerai1, 'Teh Masak')},
        pendingNames: {},
      );
      expect(plan.toUpdate.single.costPerUnit, -1);
    });

    test('server > 0 diadopsi (biaya asli tetap jalan)', () {
      final plan = planStockMerge(
        local: [item('Teh Masak', -1)],
        server: [item('Teh Masak', 25000)],
        outletId: gerai1,
        touchedKeys: {stockTouchedKey(gerai1, 'Teh Masak')},
        pendingNames: {},
      );
      expect(plan.toUpdate.single.costPerUnit, 25000);
    });

    test('bahan baru dari server dengan biaya 0 disisipkan sebagai -1', () {
      final plan = planStockMerge(
        local: [],
        server: [item('Kopi', 0)],
        outletId: gerai1,
        touchedKeys: {},
        pendingNames: {},
      );
      expect(plan.toInsert.single.costPerUnit, -1);
    });

    test('seed segar + server 0 -> -1 (lalu backfill yang mengisi)', () {
      final plan = planStockMerge(
        local: [item('Gula', -1)],
        server: [item('Gula', 0)],
        outletId: gerai1,
        touchedKeys: {}, // belum pernah disentuh -> adopsi server
        pendingNames: {},
      );
      expect(plan.toUpdate.single.costPerUnit, -1);
    });
  });

  group('normalizeStockEvent — cost_per_unit', () {
    Map<String, dynamic> normalizeItem(Map<String, dynamic> item) {
      final normalized = normalizeStockEvent(
        outboxId: 'o1',
        rawPayload: {
          'client_uuid': '00000000-0000-0000-0000-000000000002',
          'outlet_id': '00000000-0000-0000-0000-000000000001',
          'created_at': '2026-11-24T10:00:00.000Z',
          'items': [item],
        },
        entryCreatedAt: DateTime.utc(2026, 11, 24, 10),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      final payload = normalized['payload'] as Map<String, dynamic>;
      return (payload['items'] as List).single as Map<String, dynamic>;
    }

    Map<String, dynamic> baseItem() => {
          'name': 'Gula',
          'unit': 'kg',
          'qty_after': 5,
          'low_threshold': 1,
          'delta': -0.035,
        };

    test('cost_per_unit tidak ada -> kunci TIDAK ADA di hasil', () {
      final item = normalizeItem(baseItem());
      expect(item.containsKey('cost_per_unit'), isFalse);
    });

    test('cost_per_unit 0 -> kunci TIDAK ADA di hasil', () {
      final item = normalizeItem(baseItem()..['cost_per_unit'] = 0);
      expect(item.containsKey('cost_per_unit'), isFalse);
    });

    test('cost_per_unit 18000 -> ikut terkirim', () {
      final item = normalizeItem(baseItem()..['cost_per_unit'] = 18000);
      expect(item['cost_per_unit'], 18000);
    });
  });

  group('StockService (Drift) — hasUnsetCostsFor + merge + brew', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() async {
      final dir = Directory.systemTemp.createTempSync('suka-tea-c10-1-test');
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
      await StockService.instance.init();
      await BrewService.instance.init();
    });

    const gerai1 = '00000000-0000-0000-0000-000000000001';
    const gerai2 = '00000000-0000-0000-0000-000000000002';

    /// Tandai semua event outbox sebagai terkirim — supaya
    /// mergePulledStock tidak melewati bahan karena "pending"
    /// (aturan pending mendahului aturan biaya; tes ini mau
    /// menguji aturan biayanya).
    Future<void> drainOutbox() async {
      final pending = await OutboxService.instance.pendingEntries();
      for (final e in pending) {
        await OutboxService.instance.markSent(e.id);
      }
    }

    test('hasUnsetCostsFor: Teh Masak -1 -> true; setelah diisi -> false',
        () async {
      // Seed: Teh Masak biayanya -1 (seed 0) sampai Owner mengisi.
      expect(StockService.instance.hasUnsetCostsFor(gerai1), isTrue);
      await StockService.instance.updateCost('Teh Masak', 30000);
      expect(StockService.instance.hasUnsetCostsFor(gerai1), isFalse);
    });

    test('hasUnsetCostsFor: gerai tanpa level -> true', () {
      expect(StockService.instance.hasUnsetCostsFor(gerai2), isTrue);
    });

    test('mergePulledStock: server 0 tidak menimpa biaya lokal', () async {
      await StockService.instance.addStockItem('Kopi', 'pcs', 10, 0);
      await StockService.instance.updateCost('Kopi', 5000);
      await StockService.instance.addStockItem('Teh Hijau', 'kg', 1, 0);
      await drainOutbox();

      StockItem server(String name, double cost) => StockItem(
            name: name,
            unit: 'pcs',
            qty: 99,
            lowThreshold: 0,
            costPerUnit: cost,
            outletId: gerai1,
          );
      await StockService.instance.mergePulledStock(gerai1, [
        server('Kopi', 0),
        server('Teh Hijau', 0),
        server('Gula', 0),
      ]);
      final byName = StockService.instance.stockByNameFor(gerai1);
      expect(byName['Kopi']!.costPerUnit, 5000);
      expect(byName['Teh Hijau']!.costPerUnit, -1);
      // Gula: server 0 -> -1 -> backfill seed 18000.
      expect(byName['Gula']!.costPerUnit, 18000);

      // Biaya server > 0 tetap diadopsi.
      await StockService.instance.mergePulledStock(gerai1, [
        server('Teh Hijau', 25000),
      ]);
      expect(
        StockService.instance.stockByNameFor(gerai1)['Teh Hijau']!
            .costPerUnit,
        25000,
      );
    });

    test('brew: Teh Kering -1 -> Teh Masak pakai estimasi seed', () async {
      // Gerai 2: Teh Kering dibuat manual (biaya -1, qty 0) lalu
      // ditambah qty — tanpa pernah di-backfill, jadi biayanya
      // tetap -1 saat masak (jalur yang dulu bikin Teh Masak
      // tanpa biaya).
      await StockService.instance.ensureStockItem(gerai2, 'Teh Kering', 'kg');
      await StockService.instance.adjustLevels(
        gerai2,
        {'Teh Kering': 2.5},
        reason: 'koreksi',
      );
      expect(
        StockService.instance.stockByNameFor(gerai2)['Teh Kering']!
            .costPerUnit,
        -1,
      );
      final record = await BrewService.instance.brew(
        outletId: gerai2,
        kgUsed: 0.1,
        litersMade: 2.0,
      );
      expect(record, isNotNull);
      // Estimasi seed Teh Kering Rp120.000/kg:
      // (120000 x 0,1 kg) / 2,0 liter = Rp6.000/liter.
      expect(
        StockService.instance.stockByNameFor(gerai2)['Teh Masak']!
            .costPerUnit,
        6000,
      );
    });
  });
}
