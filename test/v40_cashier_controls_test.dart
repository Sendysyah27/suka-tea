import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/sale_history.dart';
import 'package:suka_tea/features/kasir/cashier_performance_page.dart';
import 'package:suka_tea/features/kasir/cashier_service.dart';
import 'package:suka_tea/features/login/cashier_session.dart';

/// Kontrol kasir v40: LIVE, arsip resign, parser field baru +
/// default perilaku lama, riwayat login, agregat performa, izin sesi.
///
/// Logika murni (tanpa widget) — kecuali tes 7 yang memakai
/// CashierSessionService singleton (memori + Drift untuk clear()).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Pola c10_stock_test.dart: path_provider di-mock ke folder temp
  // supaya Drift/SQLite benar-benar terbuka (tanpa ini clear()
  // gagal MissingPluginException / menggantung).
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('suka-tea-v40-test');
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
  });

  group('isCashierLive (LIVE = sync ≤ 5 menit)', () {
    test('null = tidak live', () {
      expect(
        isCashierLive(null, DateTime(2026, 11, 25, 11, 0)),
        isFalse,
      );
    });

    test('4 menit lalu = live', () {
      final now = DateTime(2026, 11, 25, 11, 0);
      expect(
        isCashierLive(now.subtract(const Duration(minutes: 4)), now),
        isTrue,
      );
    });

    test('tepat 5 menit = live', () {
      final now = DateTime(2026, 11, 25, 11, 0);
      expect(
        isCashierLive(now.subtract(const Duration(minutes: 5)), now),
        isTrue,
      );
    });

    test('6 menit lalu = tidak live', () {
      final now = DateTime(2026, 11, 25, 11, 0);
      expect(
        isCashierLive(now.subtract(const Duration(minutes: 6)), now),
        isFalse,
      );
    });
  });

  group('splitCashierArchive', () {
    test('arsip HANYA yang resigned', () {
      final list = [
        const Cashier(id: '1', name: 'Budi'),
        const Cashier(id: '2', name: 'Sinta', active: false),
        Cashier(
          id: '3',
          name: 'Dedi',
          active: false,
          resignedAt: DateTime(2026, 11, 12, 8, 5),
        ),
      ];
      final split = splitCashierArchive(list);
      expect(split.main.map((c) => c.name).toList(), ['Budi', 'Sinta']);
      expect(split.resigned.map((c) => c.name).toList(), ['Dedi']);
      expect(isCashierResigned(list[2]), isTrue);
      expect(isCashierResigned(list[1]), isFalse);
    });
  });

  group('parseCashierListResponse', () {
    test('jawaban baru lengkap → semua field terisi', () {
      final parsed = parseCashierListResponse({
        'ok': true,
        'cashiers': [
          {
            'id': 'c1',
            'name': 'Budi',
            'active': true,
            'can_void': true,
            'can_discount': false,
            'can_close_shift': true,
            'force_pin_change': true,
            'last_seen_at': '2026-11-25T04:58:00.000Z',
            'last_outlet_id': '00000000-0000-0000-0000-000000000001',
            'resigned_at': null,
            'allowed_outlets': [
              '00000000-0000-0000-0000-000000000001',
              '00000000-0000-0000-0000-000000000002',
            ],
          },
        ],
      });
      expect(parsed.ok, isTrue);
      final c = parsed.cashiers.single;
      expect(c.canDiscount, isFalse);
      expect(c.forcePinChange, isTrue);
      expect(c.lastSeenAt, isNotNull);
      expect(c.lastOutletId,
          '00000000-0000-0000-0000-000000000001');
      expect(c.allowedOutletIds.length, 2);
    });

    test('jawaban LAMA tanpa field baru → default perilaku lama', () {
      final parsed = parseCashierListResponse({
        'ok': true,
        'cashiers': [
          {'id': 'c1', 'name': 'Budi', 'active': true},
        ],
      });
      expect(parsed.ok, isTrue);
      final c = parsed.cashiers.single;
      expect(c.canVoid, isTrue);
      expect(c.canDiscount, isTrue);
      expect(c.canCloseShift, isTrue);
      expect(c.forcePinChange, isFalse);
      expect(c.lastSeenAt, isNull);
      expect(c.resignedAt, isNull);
      expect(c.allowedOutletIds, isEmpty);
    });
  });

  group('parseVerifyCashierResponse', () {
    test('ok + izin + gerai + force_pin_change', () {
      final parsed = parseVerifyCashierResponse({
        'ok': true,
        'cashier_id': 'c1',
        'name': 'Budi',
        'can_void': true,
        'can_discount': false,
        'can_close_shift': true,
        'force_pin_change': true,
        'allowed_outlets': ['00000000-0000-0000-0000-000000000001'],
      });
      expect(parsed.result, CashierVerifyResult.ok);
      expect(parsed.cashierId, 'c1');
      expect(parsed.permissions.canDiscount, isFalse);
      expect(parsed.permissions.forcePinChange, isTrue);
      expect(parsed.permissions.allowedOutletIds.length, 1);
    });

    test('alasan outlet_not_allowed', () {
      final parsed = parseVerifyCashierResponse({
        'ok': false,
        'reason': 'outlet_not_allowed',
      });
      expect(parsed.result, CashierVerifyResult.outletNotAllowed);
    });
  });

  group('parseLoginEventsResponse', () {
    test('2 valid + 1 rusak → 2 event', () {
      final parsed = parseLoginEventsResponse({
        'ok': true,
        'events': [
          {
            'id': 'e1',
            'cashier_id': 'c1',
            'cashier_name': 'Budi',
            'outlet_id': '00000000-0000-0000-0000-000000000001',
            'login_at': '2026-11-22T00:58:00.000Z',
          },
          {
            'id': 'e2',
            'cashier_id': 'c2',
            'cashier_name': 'Sinta',
            'outlet_id': '00000000-0000-0000-0000-000000000002',
            'login_at': '2026-11-22T00:41:00.000Z',
          },
          // Rusak: tanpa login_at → dilewati.
          {
            'id': 'e3',
            'cashier_id': 'c3',
            'cashier_name': 'Andi',
            'outlet_id': '00000000-0000-0000-0000-000000000001',
          },
        ],
      });
      expect(parsed.ok, isTrue);
      expect(parsed.events.length, 2);
      expect(parsed.events.first.cashierName, 'Budi');
    });
  });

  group('aggregateCashierPerformance (angka demo frame 32)', () {
    SaleRecord sale({
      required String id,
      required String cashier,
      required int total,
      required int cups,
      required DateTime at,
      int discount = 0,
      bool isVoid = false,
    }) {
      return SaleRecord(
        id: id,
        createdAt: at,
        items: [
          SaleItem(
            productId: 'teh',
            productName: 'Es Teh',
            variantId: 'teh_22oz',
            variantName: '22oz',
            qty: cups,
            unitPrice: total,
          ),
        ],
        total: total,
        method: PaymentMethod.tunai,
        paid: total,
        change: 0,
        discount: discount,
        isVoid: isVoid,
        cashierName: cashier,
      );
    }

    test('7 hari: 73 jualan / Rp911.000 / void 3 / diskon 4', () {
      final day = DateTime(2026, 11, 22, 10, 0);
      final sales = <SaleRecord>[];
      // Budi: 37 x 13000 (1 cup) + 1 x 5000 (17 cup) = 486000 / 54 cup.
      for (var i = 0; i < 37; i++) {
        sales.add(sale(
          id: 'b$i',
          cashier: 'Budi',
          total: 13000,
          cups: 1,
          at: day,
          discount: i < 3 ? 1000 : 0,
        ));
      }
      sales.add(sale(id: 'b37', cashier: 'Budi', total: 5000, cups: 17, at: day));
      sales.add(sale(id: 'bv1', cashier: 'Budi', total: 10000, cups: 1, at: day, isVoid: true));
      sales.add(sale(id: 'bv2', cashier: 'Budi', total: 8000, cups: 1, at: day, isVoid: true));
      // Sinta: 28 x 12000 + 1 x 15000 (13 cup) = 351000 / 41 cup.
      for (var i = 0; i < 28; i++) {
        sales.add(sale(
          id: 's$i',
          cashier: 'Sinta',
          total: 12000,
          cups: 1,
          at: day,
          discount: i == 0 ? 500 : 0,
        ));
      }
      sales.add(sale(id: 's28', cashier: 'Sinta', total: 15000, cups: 13, at: day));
      // Andi: 5 x 12000 + 1 x 14000 (4 cup) = 74000 / 9 cup.
      for (var i = 0; i < 5; i++) {
        sales.add(sale(id: 'a$i', cashier: 'Andi', total: 12000, cups: 1, at: day));
      }
      sales.add(sale(id: 'a5', cashier: 'Andi', total: 14000, cups: 4, at: day));
      sales.add(sale(id: 'av1', cashier: 'Andi', total: 9000, cups: 1, at: day, isVoid: true));
      // Di luar jendela (10 Nov) — harus TIDAK terhitung.
      sales.add(sale(
        id: 'old',
        cashier: 'Budi',
        total: 999999,
        cups: 99,
        at: DateTime(2026, 11, 10, 10, 0),
      ));

      final agg = aggregateCashierPerformance(
        sales,
        DateTime(2026, 11, 16),
        DateTime(2026, 11, 22),
      );
      expect(agg.totalSales, 73);
      expect(agg.totalOmzet, 911000);
      expect(agg.totalVoid, 3);
      expect(agg.totalDiscount, 4);
      expect(agg.rows.length, 3);
      final budi = agg.rows.firstWhere((r) => r.name == 'Budi');
      expect((budi.sales, budi.omzet, budi.cups), (38, 486000, 54));
      expect((budi.voidCount, budi.discountCount), (2, 3));
      final sinta = agg.rows.firstWhere((r) => r.name == 'Sinta');
      expect((sinta.sales, sinta.omzet, sinta.cups), (29, 351000, 41));
      expect((sinta.voidCount, sinta.discountCount), (0, 1));
      final andi = agg.rows.firstWhere((r) => r.name == 'Andi');
      expect((andi.sales, andi.omzet, andi.cups), (6, 74000, 9));
      expect((andi.voidCount, andi.discountCount), (1, 0));
    });
  });

  group('CashierSessionService izin (v40)', () {
    test('default = belum diketahui → fail closed', () {
      final session = CashierSessionService.instance;
      // File tes ini belum pernah applyPermissions sebelumnya.
      expect(session.permissionsKnown, isFalse);
      expect(session.canVoid, isFalse);
      expect(session.canDiscount, isFalse);
      expect(session.canCloseShift, isFalse);
    });

    test('applyPermissions → nilai server', () {
      final session = CashierSessionService.instance;
      session.applyPermissions((
        canVoid: true,
        canDiscount: false,
        canCloseShift: true,
        forcePinChange: true,
        allowedOutletIds: ['00000000-0000-0000-0000-000000000001'],
      ));
      expect(session.permissionsKnown, isTrue);
      expect(session.canVoid, isTrue);
      expect(session.canDiscount, isFalse);
      expect(session.canCloseShift, isTrue);
      expect(session.forcePinChange, isTrue);
      expect(
        session.isOutletAllowed('00000000-0000-0000-0000-000000000001'),
        isTrue,
      );
      expect(
        session.isOutletAllowed('00000000-0000-0000-0000-000000000002'),
        isFalse,
      );
    });

    // clear() menyentuh Drift (path_provider) — HARUS test() BIASA
    // (pola v39_auto_close_test.dart), BUKAN testWidgets: Drift
    // membuka DB di background isolate dan await-nya tidak pernah
    // kembali di dalam zona fake-async testWidgets (hang 10 mnt di
    // CI run 45553939722). Mock path_provider di setUpAll di atas
    // yang bikin open DB-nya jalan.
    test('clear() → kembali belum diketahui', () async {
      final session = CashierSessionService.instance;
      await session.clear();
      expect(session.permissionsKnown, isFalse);
      expect(session.canVoid, isFalse);
      expect(session.canDiscount, isFalse);
      expect(session.canCloseShift, isFalse);
    });
  });
}
