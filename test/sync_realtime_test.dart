import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/cash_shift_service.dart';
import 'package:suka_tea/data/expense_service.dart';
import 'package:suka_tea/data/local/outbox_service.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/data/sale_history.dart';
import 'package:suka_tea/data/stock_service.dart';
import 'package:suka_tea/data/sync_payload.dart';
import 'package:suka_tea/data/sync_service.dart';

/// Sinkronisasi realtime (Batch C9) — MURNI + service dengan Drift
/// asli (pola gerai_monitor_sync_test: path_provider di-mock ke
/// folder temp supaya SQLite benar-benar terbuka di CI).
///
/// Catatan: service-service di sini singleton — tiap test memakai
/// outlet/id unik supaya tidak saling mengotori data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('suka-tea-c9-test');
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
    await CashShiftService.instance.init();
  });

  SaleRecord sale({
    required String id,
    String outletId = '00000000-0000-0000-0000-000000000001',
    bool isVoid = false,
    int total = 11000,
  }) =>
      SaleRecord(
        id: id,
        createdAt: DateTime(2026, 11, 24, 15, 40),
        items: const [],
        total: total,
        method: PaymentMethod.tunai,
        paid: total,
        change: 0,
        outletId: outletId,
        isVoid: isVoid,
      );

  Expense expense({
    required String id,
    String outletId = '00000000-0000-0000-0000-000000000001',
    DateTime? at,
    int amount = 50000,
  }) =>
      Expense(
        id: id,
        outletId: outletId,
        category: 'Operasional',
        amount: amount,
        createdAt: at ?? DateTime(2026, 11, 24, 10, 0),
      );

  StockItem stock({
    required String name,
    double qty = 100,
    double cost = 5000,
    double low = 10,
    String unit = 'gram',
    String outletId = '00000000-0000-0000-0000-000000000001',
  }) =>
      StockItem(
        name: name,
        unit: unit,
        qty: qty,
        lowThreshold: low,
        costPerUnit: cost,
        outletId: outletId,
      );

  Future<Map<String, dynamic>> emptyPullTransport(
    Map<String, dynamic> body,
  ) async {
    return {
      'ok': true,
      'transactions': [],
      'items': [],
      'stock': [],
      'shifts': [],
      'expenses': [],
      'closed_shifts': [],
      'movements': [],
    };
  }

  group('zona waktu (Batch C9)', () {
    test('toUtcIsoString: DateTime lokal -> string berakhiran Z', () {
      final local = DateTime(2026, 11, 24, 15, 40);
      final out = toUtcIsoString(local);
      expect(out, endsWith('Z'));
      expect(out, local.toUtc().toIso8601String());
    });

    test('normalizeCreatedAtToUtc: offset +07:00 -> 08:40 UTC', () {
      expect(
        normalizeCreatedAtToUtc(
          '2026-11-24T15:40:00+07:00',
          DateTime(2026),
        ),
        '2026-11-24T08:40:00.000Z',
      );
    });

    test('normalizeCreatedAtToUtc: tanpa offset diparse lokal lalu ke UTC',
        () {
      final out = normalizeCreatedAtToUtc(
        '2026-11-24T15:40:00.000',
        DateTime(2026),
      );
      expect(out, endsWith('Z'));
      expect(
        out,
        DateTime(2026, 11, 24, 15, 40).toUtc().toIso8601String(),
      );
    });

    test('normalizeCreatedAtToUtc: string rusak -> fallback', () {
      expect(
        normalizeCreatedAtToUtc('bukan-tanggal', DateTime(2026, 1, 2, 3, 4)),
        DateTime(2026, 1, 2, 3, 4).toUtc().toIso8601String(),
      );
    });

    test('normalizeSaleEvent mengirim created_at UTC (...Z)', () {
      final ev = normalizeSaleEvent(
        outboxId: 'ob-1',
        rawPayload: {
          'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
          'payment_method': 'tunai',
          'total': 11000,
          'created_at': '2026-11-24T15:40:00.000',
          'items': [
            {'name': 'Es Teh', 'qty': 1, 'price': 11000},
          ],
        },
        entryCreatedAt: DateTime(2026, 11, 24, 15, 40),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      expect(ev['created_at'] as String, endsWith('Z'));
    });

    test('normalizeShiftEvent mengirim opened_at/closed_at UTC', () {
      final ev = normalizeShiftEvent(
        outboxId: 'ob-2',
        rawPayload: {
          'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000002',
          'opened_at': '2026-11-24T08:00:00.000',
          'opening_float': 100000,
          'status': 'closed',
          'closed_at': '2026-11-24T15:40:00.000',
        },
        entryCreatedAt: DateTime(2026, 11, 24, 8, 0),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      final payload = ev['payload'] as Map<String, dynamic>;
      expect(ev['created_at'] as String, endsWith('Z'));
      expect(payload['opened_at'] as String, endsWith('Z'));
      expect(payload['closed_at'] as String, endsWith('Z'));
    });
  });

  group('normalizeLegacyClientUuid', () {
    test('UUID valid dipakai apa adanya (huruf kecil)', () {
      expect(
        normalizeLegacyClientUuid('AAAAAAAA-0000-4000-8000-000000000001'),
        'aaaaaaaa-0000-4000-8000-000000000001',
      );
    });

    test('angka mikROdetik -> UUID v5-style yang sama dengan server', () {
      // Vektor dihitung dari SHA-256 (sama persis dengan
      // normalizeClientUuid di Edge Function sync-sales).
      expect(
        normalizeLegacyClientUuid('1700000000000000'),
        'c44439a9-7780-5e22-8026-df9467e344fb',
      );
      expect(
        normalizeLegacyClientUuid('1730000000000000'),
        '2a6692a1-b5bf-5840-b069-893134bcd602',
      );
    });
  });

  group('planSaleMerge', () {
    const outlet = '00000000-0000-0000-0000-000000000001';

    test('dedupe: yang sudah ada lokal tidak disisipkan', () {
      final local = [sale(id: 'aaaaaaaa-0000-4000-8000-000000000001')];
      final server = [sale(id: 'aaaaaaaa-0000-4000-8000-000000000001')];
      final plan =
          planSaleMerge(local: local, server: server, outletId: outlet);
      expect(plan.toInsert, isEmpty);
      expect(plan.toVoid, isEmpty);
    });

    test('server baru -> sisipkan', () {
      final plan = planSaleMerge(
        local: const [],
        server: [sale(id: 'bbbbbbbb-0000-4000-8000-000000000002')],
        outletId: outlet,
      );
      expect(plan.toInsert.length, 1);
      expect(plan.toVoid, isEmpty);
    });

    test('server void + lokal aktif -> void-kan lokal', () {
      final plan = planSaleMerge(
        local: [sale(id: 'aaaaaaaa-0000-4000-8000-000000000001')],
        server: [
          sale(id: 'aaaaaaaa-0000-4000-8000-000000000001', isVoid: true),
        ],
        outletId: outlet,
      );
      expect(plan.toInsert, isEmpty);
      expect(plan.toVoid, ['aaaaaaaa-0000-4000-8000-000000000001']);
    });

    test('server completed + lokal SUDAH void -> TETAP void (sticky)', () {
      final plan = planSaleMerge(
        local: [
          sale(id: 'aaaaaaaa-0000-4000-8000-000000000001', isVoid: true),
        ],
        server: [sale(id: 'aaaaaaaa-0000-4000-8000-000000000001')],
        outletId: outlet,
      );
      expect(plan.toInsert, isEmpty);
      expect(plan.toVoid, isEmpty);
    });

    test('server void yang tidak ada lokal -> sisipkan apa adanya', () {
      final plan = planSaleMerge(
        local: const [],
        server: [
          sale(id: 'bbbbbbbb-0000-4000-8000-000000000002', isVoid: true),
        ],
        outletId: outlet,
      );
      expect(plan.toInsert.length, 1);
      expect(plan.toInsert.first.isVoid, isTrue);
    });

    test('gerai lain diabaikan', () {
      final plan = planSaleMerge(
        local: const [],
        server: [
          sale(
            id: 'bbbbbbbb-0000-4000-8000-000000000002',
            outletId: '00000000-0000-0000-0000-000000000002',
          ),
        ],
        outletId: outlet,
      );
      expect(plan.toInsert, isEmpty);
    });

    test('id legacy lokal (mikROdetik) cocok dengan UUID server', () {
      final plan = planSaleMerge(
        local: [sale(id: '1700000000000000')],
        server: [sale(id: 'c44439a9-7780-5e22-8026-df9467e344fb')],
        outletId: outlet,
      );
      expect(plan.toInsert, isEmpty);
      expect(plan.toVoid, isEmpty);
    });
  });

  group('mergePulledSales (service)', () {
    test('sisipkan penjualan server + void sticky dua arah', () async {
      const outlet = 'outlet-c9-sales-1';
      const id = 'cccccccc-0000-4000-8000-000000000001';
      await SaleHistoryService.instance.mergePulledSales(
        [sale(id: id, outletId: outlet)],
        outletId: outlet,
      );
      expect(
        SaleHistoryService.instance.sales.any((s) => s.id == id),
        isTrue,
      );
      // Server void -> lokal ikut void.
      await SaleHistoryService.instance.mergePulledSales(
        [sale(id: id, outletId: outlet, isVoid: true)],
        outletId: outlet,
      );
      expect(
        SaleHistoryService.instance.sales
            .firstWhere((s) => s.id == id)
            .isVoid,
        isTrue,
      );
      // Server completed lagi -> TETAP void.
      await SaleHistoryService.instance.mergePulledSales(
        [sale(id: id, outletId: outlet)],
        outletId: outlet,
      );
      expect(
        SaleHistoryService.instance.sales
            .firstWhere((s) => s.id == id)
            .isVoid,
        isTrue,
      );
    });
  });

  group('planExpenseMerge', () {
    const outlet = '00000000-0000-0000-0000-000000000001';
    final from = DateTime(2026, 10, 25);
    final to = DateTime(2026, 11, 25);

    test('server baru -> sisipkan', () {
      final plan = planExpenseMerge(
        local: const [],
        server: [expense(id: 'eeeeeeee-0000-4000-8000-000000000001')],
        outletId: outlet,
        from: from,
        to: to,
        pendingIds: const {},
      );
      expect(plan.toInsert.length, 1);
      expect(plan.toDelete, isEmpty);
    });

    test('lokal tidak ada di server + dalam jendela -> hapus', () {
      final plan = planExpenseMerge(
        local: [expense(id: 'eeeeeeee-0000-4000-8000-000000000001')],
        server: const [],
        outletId: outlet,
        from: from,
        to: to,
        pendingIds: const {},
      );
      expect(plan.toInsert, isEmpty);
      expect(plan.toDelete, ['eeeeeeee-0000-4000-8000-000000000001']);
    });

    test('lokal masih pending -> JANGAN hapus', () {
      final plan = planExpenseMerge(
        local: [expense(id: 'eeeeeeee-0000-4000-8000-000000000001')],
        server: const [],
        outletId: outlet,
        from: from,
        to: to,
        pendingIds: {'eeeeeeee-0000-4000-8000-000000000001'},
      );
      expect(plan.toDelete, isEmpty);
    });

    test('lokal di LUAR jendela -> JANGAN hapus', () {
      final plan = planExpenseMerge(
        local: [
          expense(
            id: 'eeeeeeee-0000-4000-8000-000000000001',
            at: DateTime(2026, 9, 1),
          ),
        ],
        server: const [],
        outletId: outlet,
        from: from,
        to: to,
        pendingIds: const {},
      );
      expect(plan.toDelete, isEmpty);
    });
  });

  group('mergePulledExpenses (service)', () {
    test('sisipkan pengeluaran server', () async {
      const outlet = 'outlet-c9-exp-1';
      const id = 'dddddddd-0000-4000-8000-000000000001';
      await ExpenseService.instance.mergePulledExpenses(
        [expense(id: id, outletId: outlet)],
        outletId: outlet,
        from: DateTime(2026, 10, 25),
        to: DateTime(2026, 11, 25),
      );
      expect(
        ExpenseService.instance.expenses.any((e) => e.id == id),
        isTrue,
      );
    });

    test('pending tidak terhapus; sesudah terkirim + tidak ada di server '
        '-> terhapus', () async {
      final created = await ExpenseService.instance.addExpense(
        category: 'Operasional',
        description: 'c9-test-delete',
        amount: 12345,
      );
      expect(created, isNotNull);
      final id = created!.id;
      final outlet = created.outletId;
      final now = DateTime.now();
      final from = now.subtract(const Duration(days: 30));
      final to = now.add(const Duration(days: 1));
      // Server tidak mengembalikan expense ini, tapi event-nya masih
      // pending -> JANGAN hapus.
      await ExpenseService.instance.mergePulledExpenses(
        const [],
        outletId: outlet,
        from: from,
        to: to,
      );
      expect(
        ExpenseService.instance.expenses.any((e) => e.id == id),
        isTrue,
      );
      // Tandai event-nya terkirim (simulasi server sudah tahu),
      // merge lagi dengan server yang tetap tidak punya baris ini ->
      // dianggap dihapus di server -> hapus lokal.
      final pending = await OutboxService.instance.pendingEntries();
      for (final entry in pending) {
        if (entry.kind != 'expense') continue;
        final raw = jsonDecode(entry.payload);
        if (raw is Map && raw['client_uuid'] == id) {
          await OutboxService.instance.markSent(entry.id);
        }
      }
      await ExpenseService.instance.mergePulledExpenses(
        const [],
        outletId: outlet,
        from: from,
        to: to,
      );
      expect(
        ExpenseService.instance.expenses.any((e) => e.id == id),
        isFalse,
      );
    });
  });

  group('planStockMerge', () {
    const outlet = '00000000-0000-0000-0000-000000000001';

    test('tidak ada level lokal -> sisipkan utuh', () {
      final plan = planStockMerge(
        local: const [],
        server: [stock(name: 'Teh', qty: 42, cost: 777)],
        outletId: outlet,
        touchedKeys: const {},
        pendingNames: const {},
      );
      expect(plan.toInsert.length, 1);
      expect(plan.toInsert.first.qty, 42);
      expect(plan.toInsert.first.costPerUnit, 777);
      expect(plan.toUpdate, isEmpty);
    });

    test('seed segar (belum disentuh) -> adopsi utuh dari server', () {
      final plan = planStockMerge(
        local: [stock(name: 'Teh', qty: 500, cost: 120000)],
        server: [stock(name: 'Teh', qty: 480, cost: 125000)],
        outletId: outlet,
        touchedKeys: const {},
        pendingNames: const {},
      );
      expect(plan.toInsert, isEmpty);
      expect(plan.toUpdate.length, 1);
      expect(plan.toUpdate.first.qty, 480);
      expect(plan.toUpdate.first.costPerUnit, 125000);
    });

    test('sudah disentuh + tidak pending -> qty dipertahankan, meta '
        'dari server', () {
      final plan = planStockMerge(
        local: [stock(name: 'Teh', qty: 500, cost: 120000, low: 100)],
        server: [stock(name: 'Teh', qty: 1, cost: 125000, low: 50)],
        outletId: outlet,
        touchedKeys: {stockTouchedKey(outlet, 'Teh')},
        pendingNames: const {},
      );
      expect(plan.toInsert, isEmpty);
      expect(plan.toUpdate.length, 1);
      expect(plan.toUpdate.first.qty, 500);
      expect(plan.toUpdate.first.costPerUnit, 125000);
      expect(plan.toUpdate.first.lowThreshold, 50);
    });

    test('sudah disentuh + pending -> semua dipertahankan', () {
      final plan = planStockMerge(
        local: [stock(name: 'Teh', qty: 500, cost: 120000)],
        server: [stock(name: 'Teh', qty: 1, cost: 125000)],
        outletId: outlet,
        touchedKeys: {stockTouchedKey(outlet, 'Teh')},
        pendingNames: {'Teh'},
      );
      expect(plan.toInsert, isEmpty);
      expect(plan.toUpdate, isEmpty);
    });

    test('nama kosong dari server dilewati', () {
      final plan = planStockMerge(
        local: const [],
        server: [stock(name: '')],
        outletId: outlet,
        touchedKeys: const {},
        pendingNames: const {},
      );
      expect(plan.toInsert, isEmpty);
    });
  });

  group('mergePulledStock (service)', () {
    test('server mengisi gerai baru yang belum punya level lokal',
        () async {
      const outlet = 'outlet-c9-stock-baru';
      await StockService.instance.mergePulledStock(outlet, [
        stock(name: 'Teh Baru', qty: 42, cost: 777, outletId: outlet),
      ]);
      final levels = StockService.instance.levelsFor(outlet);
      expect(levels.length, 1);
      expect(levels.first.qty, 42);
      expect(levels.first.costPerUnit, 777);
    });

    test('pending movement melindungi cost + qty lokal; sesudah '
        'terkirim cost server menang', () async {
      final outlet = OutletService.instance.currentOutletId;
      // Gerai aktif sudah di-seed; Teh Kering ada (qty 2.5 kg, cost
      // seed 120000). Ubah cost -> event 'koreksi' pending.
      // Batch C10 WS4: 'Teh' berganti nama jadi 'Teh Kering'.
      final before = StockService.instance.stockByName['Teh Kering'];
      expect(before, isNotNull);
      await StockService.instance.updateCost('Teh Kering', 999);
      await StockService.instance.mergePulledStock(outlet, [
        stock(name: 'Teh Kering', qty: 1, cost: 555, outletId: outlet),
      ]);
      var teh = StockService.instance.stockByName['Teh Kering']!;
      expect(teh.costPerUnit, 999);
      expect(teh.qty, before!.qty);
      // Tandai SEMUA event koreksi Teh Kering terkirim, merge lagi.
      final pending = await OutboxService.instance.pendingEntries();
      for (final entry in pending) {
        if (entry.kind != 'stock_movement') continue;
        final raw = jsonDecode(entry.payload);
        if (raw is! Map || raw['reason'] != 'koreksi') continue;
        final items = raw['items'];
        if (items is List &&
            items.any((it) => it is Map && it['name'] == 'Teh Kering')) {
          await OutboxService.instance.markSent(entry.id);
        }
      }
      await StockService.instance.mergePulledStock(outlet, [
        stock(name: 'Teh Kering', qty: 1, cost: 555, outletId: outlet),
      ]);
      teh = StockService.instance.stockByName['Teh Kering']!;
      expect(teh.costPerUnit, 555);
      expect(teh.qty, before.qty);
    });
  });

  group('parsePullResponse (Batch C9)', () {
    test('expenses + closed_shifts + movements ikut terparse', () {
      final parsed = parsePullResponse({
        'ok': true,
        'transactions': [],
        'items': [],
        'stock': [],
        'shifts': [],
        'expenses': [
          {
            'client_uuid': 'eeeeeeee-0000-4000-8000-000000000001',
            'category': 'Bahan Baku',
            'amount': 250000,
            'created_at': '2026-11-24T03:00:00+00:00',
          },
        ],
        'closed_shifts': [
          {
            'client_uuid': 'ffffffff-0000-4000-8000-000000000001',
            'opened_at': '2026-11-24T01:00:00+00:00',
            'closed_at': '2026-11-24T08:00:00+00:00',
            'status': 'closed',
            'counted_cash': 150000,
            'expected_cash': 148000,
            'difference': 2000,
          },
        ],
        'movements': [
          {
            'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
            'name': 'Teh',
            'qty_delta': -20,
            'reason': 'penjualan',
            'created_at': '2026-11-24T03:00:00+00:00',
          },
        ],
      });
      expect(parsed.expenses.length, 1);
      expect(parsed.closedShifts.length, 1);
      expect(parsed.closedShifts.first.countedCash, 150000);
      expect(parsed.closedShifts.first.difference, 2000);
      expect(parsed.movements.length, 1);
      expect(parsed.movements.first.name, 'Teh');
      expect(parsed.movements.first.qtyDelta, -20);
    });

    test('jawaban EF lama (tanpa kunci baru) -> list kosong, bukan error',
        () {
      final parsed = parsePullResponse({
        'ok': true,
        'transactions': [],
        'items': [],
      });
      expect(parsed.expenses, isEmpty);
      expect(parsed.closedShifts, isEmpty);
      expect(parsed.movements, isEmpty);
      expect(parsed.stock, isEmpty);
      expect(parsed.shifts, isEmpty);
    });
  });

  group('refreshSales + timer', () {
    test('refreshSales dobel bersamaan = satu pull', () async {
      var pulls = 0;
      final svc = SyncService.createForTest(
        configured: true,
        transport: (body) async {
          if (body['action'] == 'pull') pulls++;
          return emptyPullTransport(body);
        },
      );
      await Future.wait([svc.refreshSales(), svc.refreshSales()]);
      expect(pulls, 1);
    });

    test('start() dua kali = satu timer', () async {
      // Waktu nyata (bukan fakeAsync): merge refreshSales memakai
      // Drift asli yang butuh event loop nyata, jadi jam palsu tidak
      // bisa menyelesaikan pull pertama dan guard _pullingSales akan
      // memblokir semua tick berikutnya.
      var pulls = 0;
      final svc = SyncService.createForTest(
        configured: true,
        transport: (body) async {
          if (body['action'] == 'pull') pulls++;
          return emptyPullTransport(body);
        },
      );
      svc.start(period: const Duration(milliseconds: 50));
      svc.start(period: const Duration(milliseconds: 50));
      await Future.delayed(const Duration(milliseconds: 320));
      svc.stop();
      // Langsung 1x + tick ~50/100/150/200/250/300 = maks 7 pull.
      // Dua timer akan menggandakan angka ini; guard mungkin
      // menggugurkan sebagian tick bila pull sebelumnya belum selesai.
      expect(pulls, inInclusiveRange(3, 7));
    });
  });
}
