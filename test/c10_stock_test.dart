import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/data/brew_service.dart';
import 'package:suka_tea/data/c10_models.dart';
import 'package:suka_tea/data/cash_shift_service.dart';
import 'package:suka_tea/data/expense_service.dart';
import 'package:suka_tea/data/local/app_database.dart';
import 'package:suka_tea/data/master_sync.dart';
import 'package:suka_tea/data/menu_service.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/data/package_service.dart';
import 'package:suka_tea/data/recipe_logic.dart';
import 'package:suka_tea/data/sale_history.dart';
import 'package:suka_tea/data/stock_service.dart';
import 'package:suka_tea/data/sync_payload.dart';
import 'package:suka_tea/data/topping_service.dart';
import 'package:suka_tea/features/gudang/dashboard_page.dart';

/// Batch C10 — Stok: Gudang, Paket Kiriman, Jatah Gerai, Dashboard.
///
/// Pola gerai_monitor_sync_test / sync_realtime_test: path_provider
/// di-mock ke folder temp supaya Drift/SQLite benar-benar terbuka.
/// Service-service di sini singleton — tiap test memakai nama/id
/// unik supaya tidak saling mengotori data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gerai1 = '00000000-0000-0000-0000-000000000001';
  const gerai2 = '00000000-0000-0000-0000-000000000002';

  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('suka-tea-c10-test');
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
    await ToppingService.instance.init();
    await MenuService.instance.init();
    await SaleHistoryService.instance.init();
    await ExpenseService.instance.init();
    await CashShiftService.instance.init();
    // Benih state WS4 untuk tes hangus: Teh Masak 4 L di gerai 1 +
    // baris BrewStates KEMARIN — disisipkan SEBELUM BrewService.init
    // supaya init membacanya sebagai state gerai 1.
    await StockService.instance.ensureStockItem(gerai1, 'Teh Masak', 'L');
    await StockService.instance.adjustLevels(
      gerai1,
      {'Teh Masak': 4.0},
      reason: 'tambah',
      enqueueMovement: false,
    );
    final seedDb = AppDatabase();
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final yday = DateTime(yesterday.year, yesterday.month, yesterday.day);
    await seedDb.into(seedDb.brewStates).insert(
          BrewStatesCompanion.insert(
            outletId: gerai1,
            brewedDate: Value(yday),
            litersMade: const Value(4.0),
          ),
          mode: InsertMode.insertOrReplace,
        );
    await seedDb.close();
    await PackageService.instance.init();
    await BrewService.instance.init();
  });

  StockItem stockItem(
    String name,
    double qty, {
    String unit = 'pcs',
    double cost = 0,
    String outletId = gerai1,
  }) =>
      StockItem(
        name: name,
        unit: unit,
        qty: qty,
        lowThreshold: 0,
        costPerUnit: cost,
        outletId: outletId,
      );

  group('WS0 merge master-data (murni)', () {
    MasterChange change({
      required String entity,
      required String id,
      required DateTime at,
      bool isDeleted = false,
    }) =>
        MasterChange(
          entity: entity,
          id: id,
          updatedAt: at,
          data: {'nama': 'x'},
          isDeleted: isDeleted,
        );

    test('server lebih baru menang; lebih lama kalah; seri = lokal', () {
      final now = DateTime.utc(2026, 11, 24, 10);
      final out = planMasterMerge(
        serverChanges: [
          change(entity: 'target', id: gerai1, at: now),
          change(
            entity: 'package',
            id: 'p-lama',
            at: now.subtract(const Duration(hours: 1)),
          ),
          change(entity: 'topping', id: 't-seri', at: now),
        ],
        localUpdatedAt: {
          'package|p-lama': now,
          'topping|t-seri': now,
        },
        pendingKeys: const {},
      );
      expect(out.map((c) => c.id), [gerai1]);
      // Hanya 'target' (baru lokal) yang diterapkan; 'package' kalah
      // (server lebih lama), 'topping' seri (lokal dipertahankan).
      expect(out.length, 1);
      expect(out.first.entity, 'target');
    });

    test('pending lokal TIDAK PERNAH ditimpa pull', () {
      final now = DateTime.utc(2026, 11, 24, 10);
      final out = planMasterMerge(
        serverChanges: [
          change(entity: 'recipe', id: 'v1|Gula', at: now),
        ],
        localUpdatedAt: {
          'recipe|v1|Gula': now.subtract(const Duration(days: 1)),
        },
        pendingKeys: {'recipe|v1|Gula'},
      );
      expect(out, isEmpty);
    });

    test('is_deleted server yang lebih baru diterapkan', () {
      final now = DateTime.utc(2026, 11, 24, 10);
      final out = planMasterMerge(
        serverChanges: [
          change(
            entity: 'topping',
            id: 't-hapus',
            at: now,
            isDeleted: true,
          ),
        ],
        localUpdatedAt: {
          'topping|t-hapus': now.subtract(const Duration(hours: 2)),
        },
        pendingKeys: const {},
      );
      expect(out.length, 1);
      expect(out.first.isDeleted, isTrue);
    });

    test('MasterChange toEventPayload/fromServer round-trip', () {
      final at = DateTime.utc(2026, 11, 24, 10, 30);
      final c = MasterChange(
        entity: 'target',
        id: gerai1,
        updatedAt: at,
        data: {'target_omzet': 500000},
      );
      final payload = c.toEventPayload();
      expect(payload['client_uuid'], gerai1);
      expect(payload['entity'], 'target');
      final back = MasterChange.fromServer({
        'entity': payload['entity'],
        'id': payload['entity_id'],
        'updated_at': payload['updated_at'],
        'data': payload['data'],
        'is_deleted': false,
      });
      expect(back.id, gerai1);
      expect(back.data['target_omzet'], 500000);
      expect(back.updatedAt, at);
    });
  });

  group('WS5 Bisa jual N cup (murni)', () {
    test('N = minimum floor(stok/takaran) semua baris resep', () {
      final recipe = [
        const RecipeLine(stockName: 'Teh Masak', qty: 0.4),
        const RecipeLine(stockName: 'Gula', qty: 0.035),
        const RecipeLine(stockName: 'Cup 22oz', qty: 1),
      ];
      final stock = {
        'Teh Masak': stockItem('Teh Masak', 4.0, unit: 'L'),
        'Gula': stockItem('Gula', 0.35, unit: 'kg'),
        'Cup 22oz': stockItem('Cup 22oz', 12),
      };
      // Teh Masak 4/0.4=10, Gula 0.35/0.035=10, Cup 12 -> N=10.
      final r = sellableCupsForProduct(recipe, stock);
      expect(r.cups, 10);
      expect(r.limitingStock, isNull);
    });

    test('bahan hilang / Teh Masak 0 -> 0 + limitingStock', () {
      final recipe = [
        const RecipeLine(stockName: 'Teh Masak', qty: 0.4),
        const RecipeLine(stockName: 'Cup 22oz', qty: 1),
      ];
      final noTea = {
        'Teh Masak': stockItem('Teh Masak', 0, unit: 'L'),
        'Cup 22oz': stockItem('Cup 22oz', 50),
      };
      final r1 = sellableCupsForProduct(recipe, noTea);
      expect(r1.cups, 0);
      expect(r1.limitingStock, 'Teh Masak');

      final missing = {'Cup 22oz': stockItem('Cup 22oz', 50)};
      final r2 = sellableCupsForProduct(recipe, missing);
      expect(r2.cups, 0);
      expect(r2.limitingStock, 'Teh Masak');
    });

    test('totalCapacityCups = jumlah per menu, produk nonaktif dilewati',
        () {
      final products = [
        const Product(
          id: 'es-teh-jumbo',
          name: 'Es Teh Jumbo',
          category: 'Best Seller',
          variants: [
            ProductVariant(
              id: 'es-teh-jumbo_22oz',
              name: '22oz',
              price: 3000,
            ),
          ],
        ),
        const Product(
          id: 'es-teh-susu',
          name: 'Es Teh Susu',
          category: 'Best Seller',
          isActive: false,
          variants: [
            ProductVariant(
              id: 'es-teh-susu_22oz',
              name: '22oz',
              price: 5000,
            ),
          ],
        ),
      ];
      final recipes = {
        'es-teh-jumbo_22oz': [
          const RecipeLine(stockName: 'Teh Masak', qty: 0.4),
          const RecipeLine(stockName: 'Cup 22oz', qty: 1),
        ],
        'es-teh-susu_22oz': [
          const RecipeLine(stockName: 'Teh Masak', qty: 0.4),
        ],
      };
      final stock = {
        'Teh Masak': stockItem('Teh Masak', 2.0, unit: 'L'),
        'Cup 22oz': stockItem('Cup 22oz', 100),
      };
      // Jumbo: min(2/0.4=5, 100) = 5; Susu nonaktif = 0.
      expect(totalCapacityCups(products, recipes, stock), 5);
    });
  });

  group('WS4 Teh Masak (murni + service)', () {
    test('isBrewExpired: kemarin true, hari ini false, null false', () {
      final now = DateTime(2026, 11, 24, 9, 0);
      expect(isBrewExpired(DateTime(2026, 11, 23), now), isTrue);
      expect(isBrewExpired(DateTime(2026, 11, 24), now), isFalse);
      expect(isBrewExpired(null, now), isFalse);
    });

    test('expiredTehMasakLiters = seluruh sisa bila lewat hari', () {
      final now = DateTime(2026, 11, 24, 9, 0);
      expect(
        expiredTehMasakLiters(
          brewedDate: DateTime(2026, 11, 23),
          currentLiters: 3.5,
          now: now,
        ),
        3.5,
      );
      expect(
        expiredTehMasakLiters(
          brewedDate: DateTime(2026, 11, 24),
          currentLiters: 3.5,
          now: now,
        ),
        0,
      );
    });

    test('expireCheck: masak HP lain (pull) ikut hangus', () async {
      // Gerai 2 belum pernah masak di HP ini: riwayat masak kemarin
      // datang dari pull HP lain + Teh Masak 3 L di gerai 2.
      await StockService.instance.ensureStockItem(gerai2, 'Teh Masak', 'L');
      await StockService.instance.adjustLevels(
        gerai2,
        {'Teh Masak': 3.0},
        reason: 'tambah',
        enqueueMovement: false,
      );
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await BrewService.instance.mergePulledBrews([
        {
          'id': 'brew-hp-lain-1',
          'outlet_id': gerai2,
          'kg_used': 1.0,
          'liters_made': 3.0,
          'brewed_at': yesterday.toUtc().toIso8601String(),
          'brewed_by': 'Kasir',
          'expired_liters': 0,
        },
      ]);
      // State diturunkan dari riwayat pull (bukan BrewStates lokal):
      // kemarin -> tidak segar, hangus 3 L.
      expect(BrewService.instance.hasFreshTehMasak(gerai2), isFalse);
      expect(await BrewService.instance.expireTehMasak(gerai2), 3.0);
      expect(BrewService.instance.tehMasakToday(gerai2), 0);
    });

    test('brew: kg kurang -> null; masak 2x sehari menumpuk', () async {
      // Siapkan Teh Kering 2 kg di gerai 2 (gerai khusus tes ini).
      await StockService.instance.ensureStockItem(gerai2, 'Teh Kering', 'kg');
      await StockService.instance.adjustLevels(
        gerai2,
        {'Teh Kering': 2.0},
        reason: 'tambah',
        enqueueMovement: false,
      );
      final kurang = await BrewService.instance.brew(
        outletId: gerai2,
        kgUsed: 3.0,
        litersMade: 10,
      );
      expect(kurang, isNull);

      final r1 = await BrewService.instance.brew(
        outletId: gerai2,
        kgUsed: 1.0,
        litersMade: 6,
      );
      expect(r1, isNotNull);
      expect(BrewService.instance.tehMasakToday(gerai2), 6);

      final r2 = await BrewService.instance.brew(
        outletId: gerai2,
        kgUsed: 0.5,
        litersMade: 3,
      );
      expect(r2, isNotNull);
      expect(BrewService.instance.tehMasakToday(gerai2), 9);
      final kering = StockService.instance
          .stockByNameFor(gerai2)['Teh Kering']?.qty;
      expect(kering, 0.5);
    });

    test('expireCheck: sisa kemarin hangus jadi 0', () async {
      // State gerai 1 dibenihi di setUpAll: Teh Masak 4 L + tanggal
      // masak kemarin. expireCheck harus menghanguskan semuanya.
      expect(BrewService.instance.tehMasakToday(gerai1), 4);
      expect(BrewService.instance.hasFreshTehMasak(gerai1), isFalse);
      final count = await BrewService.instance.expireCheck();
      expect(count, 1);
      expect(BrewService.instance.tehMasakToday(gerai1), 0);
      expect(BrewService.instance.hasFreshTehMasak(gerai1), isFalse);
      // Kedua kali: sudah hangus, tidak ada lagi yang dihitung.
      expect(await BrewService.instance.expireCheck(), 0);
    });
  });

  group('WS6 Opname selisih (murni)', () {
    test('difference = fisik - sistem; Rp perkiraan dari cost', () {
      final o = StockOpname(
        id: 'op-1',
        outletId: gerai1,
        stockName: 'Teh Kering',
        systemQty: 1.7,
        physicalQty: 1.2,
        countedAt: DateTime.utc(2026, 11, 24, 10),
        updatedAt: DateTime.utc(2026, 11, 24, 10),
      );
      expect(o.difference, closeTo(-0.5, 0.0001));
      expect(o.differenceRupiah(50000), -25000);
      final adjusted = o.copyWith(adjusted: true);
      expect(adjusted.adjusted, isTrue);
      expect(adjusted.difference, closeTo(-0.5, 0.0001));
    });
  });

  group('WS1 stok masuk + WS3 kirim atomik + reverse (service)', () {
    test('stok masuk: tanggal masa depan / >30 hari / qty 0 ditolak',
        () async {
      final now = DateTime.now();
      expect(
        await PackageService.instance.recordStockIn(
          stockName: 'Gula Tes',
          unit: 'kg',
          qty: 1,
          date: now.add(const Duration(days: 1)),
        ),
        isNull,
      );
      expect(
        await PackageService.instance.recordStockIn(
          stockName: 'Gula Tes',
          unit: 'kg',
          qty: 1,
          date: now.subtract(const Duration(days: 31)),
        ),
        isNull,
      );
      expect(
        await PackageService.instance.recordStockIn(
          stockName: 'Gula Tes',
          unit: 'kg',
          qty: 0,
          date: now,
        ),
        isNull,
      );
    });

    test('kirim atomik lalu reverse gudang_kurang', () async {
      final now = DateTime.now();
      // Gudang: Cup 22oz 100 pcs, Gula 10 kg.
      await PackageService.instance.recordStockIn(
        stockName: 'Cup 22oz Tes',
        unit: 'pcs',
        qty: 100,
        date: now,
      );
      await PackageService.instance.recordStockIn(
        stockName: 'Gula Tes',
        unit: 'kg',
        qty: 10,
        date: now,
      );
      final pkg = await PackageService.instance.createPackage(
        name: 'Paket Tes Atomik',
        items: [
          const SendItem(stockName: 'Cup 22oz Tes', qty: 10, unit: 'pcs'),
          const SendItem(stockName: 'Gula Tes', qty: 2, unit: 'kg'),
        ],
      );
      expect(pkg, isNotNull);

      final results = await PackageService.instance.sendToOutlets(
        outletIds: [gerai1],
        packageId: pkg!.id,
      );
      expect(results.length, 1);
      expect(results.first.ok, isTrue);
      final sendId = results.first.sendId!;
      // Atomik: gudang berkurang DAN gerai bertambah bersamaan.
      final gudang = StockService.instance.stockByNameFor(gudangOutletId);
      expect(gudang['Cup 22oz Tes']?.qty, 90);
      expect(gudang['Gula Tes']?.qty, 8);
      final gerai = StockService.instance.stockByNameFor(gerai1);
      expect(gerai['Cup 22oz Tes']?.qty, 10);
      expect(gerai['Gula Tes']?.qty, 2);

      // Server menolak (gudang_kurang) -> reverse lokal penuh.
      await PackageService.instance.reverseFailedSend(
        sendId: sendId,
        message: 'Kiriman GAGAL — gudang kurang (server).',
      );
      final gudang2 = StockService.instance.stockByNameFor(gudangOutletId);
      expect(gudang2['Cup 22oz Tes']?.qty, 100);
      expect(gudang2['Gula Tes']?.qty, 10);
      final gerai2 = StockService.instance.stockByNameFor(gerai1);
      expect(gerai2['Cup 22oz Tes']?.qty ?? 0, 0);
      expect(gerai2['Gula Tes']?.qty ?? 0, 0);
      final send =
          PackageService.instance.sends.firstWhere((s) => s.id == sendId);
      expect(send.status, 'gagal');
      expect(PackageService.instance.failedNotices, isNotEmpty);
      expect(
        PackageService.instance.failedNotices.first.sendId,
        sendId,
      );
    });

    test('gudang kurang -> kirim gagal lokal, stok tidak berubah', () async {
      final gudangBefore =
          StockService.instance.stockByNameFor(gudangOutletId);
      final cupBefore = gudangBefore['Cup 22oz Tes']?.qty ?? 0;
      final results = await PackageService.instance.sendToOutlets(
        outletIds: [gerai1],
        customItems: const [
          SendItem(stockName: 'Cup 22oz Tes', qty: 9999, unit: 'pcs'),
        ],
      );
      expect(results.first.ok, isFalse);
      expect(results.first.shortages, isNotEmpty);
      expect(results.first.shortages.first.missing, 9999 - cupBefore);
      final gudangAfter =
          StockService.instance.stockByNameFor(gudangOutletId);
      expect(gudangAfter['Cup 22oz Tes']?.qty ?? 0, cupBefore);
    });
  });

  group('WS0/WS3 normalizer payload + failedErrors (murni)', () {
    test('normalizeMasterEvent: happy path + entity kosong lempar', () {
      final at = DateTime.utc(2026, 11, 24, 10);
      final ev = normalizeMasterEvent(
        outboxId: 'ob-1',
        rawPayload: {
          'client_uuid': gerai1,
          'entity': 'target',
          'entity_id': gerai1,
          'updated_at': '2026-11-24T10:00:00Z',
          'is_deleted': false,
          'data': {'target_omzet': 500000},
        },
        entryCreatedAt: at,
      );
      expect(ev['kind'], 'master');
      expect((ev['payload'] as Map)['entity'], 'target');
      expect(
        () => normalizeMasterEvent(
          outboxId: 'ob-2',
          rawPayload: {'client_uuid': 'x', 'entity_id': gerai1},
          entryCreatedAt: at,
        ),
        throwsFormatException,
      );
    });

    test('normalizeStockInEvent / Brew / StockSend / Opname', () {
      final at = DateTime.utc(2026, 11, 24, 10);
      final stockIn = normalizeStockInEvent(
        outboxId: 'ob-si',
        rawPayload: {
          'client_uuid': 'si-1',
          'stock_name': 'Gula',
          'unit': 'kg',
          'qty': 5,
          'total_price': 60000,
          'date': '2026-11-24T00:00:00Z',
        },
        entryCreatedAt: at,
      );
      expect(stockIn['kind'], 'stock_in');

      final brew = normalizeBrewEvent(
        outboxId: 'ob-br',
        rawPayload: {
          'client_uuid': 'b-1',
          'outlet_id': gerai1,
          'kg_used': 1.0,
          'liters_made': 6.0,
          'brewed_at': '2026-11-24T02:00:00Z',
          'brewed_by': 'Kasir',
        },
        entryCreatedAt: at,
      );
      expect(brew['kind'], 'brew');

      final send = normalizeStockSendEvent(
        outboxId: 'ob-ss',
        rawPayload: {
          'client_uuid': 's-1',
          'outlet_id': gerai1,
          'package_id': 'p-1',
          'sent_at': '2026-11-24T03:00:00Z',
          'items': [
            {'stock_name': 'Cup 22oz', 'qty': 10, 'unit': 'pcs'},
          ],
        },
        entryCreatedAt: at,
      );
      expect(send['kind'], 'stock_send');

      final opname = normalizeOpnameEvent(
        outboxId: 'ob-op',
        rawPayload: {
          'client_uuid': 'op-1',
          'outlet_id': gerai1,
          'stock_name': 'Teh Kering',
          'system_qty': 1.7,
          'physical_qty': 1.2,
          'counted_at': '2026-11-24T10:00:00Z',
          'adjusted': false,
        },
        entryCreatedAt: at,
      );
      expect(opname['kind'], 'opname');
      expect(
        (opname['payload'] as Map)['difference'],
        closeTo(-0.5, 0.0001),
      );
    });

    test('applyPushResults: error gudang_kurang masuk failedErrors', () {
      final events = [
        {'outbox_id': 'ob-ok', 'kind': 'stock_send'},
        {'outbox_id': 'ob-gagal', 'kind': 'stock_send'},
      ];
      final out = applyPushResults(events, {
        'ok': true,
        'results': [
          {'outbox_id': 'ob-ok', 'ok': true},
          {
            'outbox_id': 'ob-gagal',
            'ok': false,
            'error': 'gudang_kurang',
          },
        ],
      });
      expect(out.sentIds, ['ob-ok']);
      expect(out.failedIds, ['ob-gagal']);
      expect(out.failedErrors['ob-gagal'], 'gudang_kurang');
    });
  });

  group('WS8 ledger rekonsiliasi (murni)', () {
    test('masuk - keluar - terbuang + opname = stok sistem (cocok)', () {
      final opening = {'Gula': 5.0};
      final system = {
        'Gula': stockItem('Gula', 5.0 + 10 - 2, unit: 'kg'),
      };
      final result = buildLedger(
        outletId: gerai1,
        sends: [
          StockSend(
            id: 's-1',
            outletId: gerai1,
            packageId: null,
            packageName: 'Top-up',
            sentAt: DateTime.utc(2026, 11, 24, 8),
            sentBy: 'Owner',
            items: const [
              SendItem(stockName: 'Gula', qty: 10, unit: 'kg'),
            ],
          ),
        ],
        movements: [
          (
            clientUuid: 'mov-1',
            name: 'Gula',
            qtyDelta: -2.0,
            reason: 'penjualan',
            createdAt: DateTime.utc(2026, 11, 24, 9),
          ),
        ],
        opnames: const [],
        brews: const [],
        openingQty: opening,
        systemStock: system,
      );
      expect(result.entries, isNotEmpty);
      final summary =
          result.summary.firstWhere((s) => s.stockName == 'Gula');
      expect(summary.matches, isTrue);
      expect(summary.gap, closeTo(0, 0.001));
    });

    test('gerakan hilang -> gap tampil (bukan disembunyikan)', () {
      final opening = {'Gula': 5.0};
      final system = {
        'Gula': stockItem('Gula', 5.0 + 10 - 2 - 1, unit: 'kg'),
      };
      final result = buildLedger(
        outletId: gerai1,
        sends: [
          StockSend(
            id: 's-1',
            outletId: gerai1,
            packageId: null,
            packageName: 'Top-up',
            sentAt: DateTime.utc(2026, 11, 24, 8),
            sentBy: 'Owner',
            items: const [
              SendItem(stockName: 'Gula', qty: 10, unit: 'kg'),
            ],
          ),
        ],
        movements: [
          (
            clientUuid: 'mov-1',
            name: 'Gula',
            qtyDelta: -2.0,
            reason: 'penjualan',
            createdAt: DateTime.utc(2026, 11, 24, 9),
          ),
        ],
        opnames: const [],
        brews: const [],
        openingQty: opening,
        systemStock: system,
      );
      final summary =
          result.summary.firstWhere((s) => s.stockName == 'Gula');
      expect(summary.matches, isFalse);
      expect(summary.gap, closeTo(-1, 0.0001));
      expect(result.summary.any((s) => !s.matches), isTrue);
    });
  });

  group('WS7 dashboard tanpa data sync (widget)', () {
    testWidgets('gerai tampil "Belum ada data tersinkron"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DashboardPage(
            role: AppRole.owner,
            onExitGerai: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Belum ada data tersinkron'), findsWidgets);
      expect(find.text('Dashboard Owner'), findsOneWidget);
    });
  });
}
