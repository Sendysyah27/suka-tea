// Batch v39 — auto-close shift kemarin + badge + Scaffold B6.
// Pola setUpAll dari c10_stock_test.dart: path_provider di-mock ke
// folder temp supaya Drift/SQLite benar-benar terbuka.
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/theme/app_theme.dart';
import 'package:suka_tea/core/utils/cash.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/data/cash_shift_service.dart';
import 'package:suka_tea/data/expense_service.dart';
import 'package:suka_tea/data/local/app_database.dart' hide CashShift;
import 'package:suka_tea/data/menu_service.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/data/sale_history.dart';
import 'package:suka_tea/data/stock_service.dart';
import 'package:suka_tea/features/keuangan/keuangan_page.dart';
import 'package:suka_tea/features/laporan/laporan_page.dart';
import 'package:suka_tea/features/login/cashier_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gerai1 = '00000000-0000-0000-0000-000000000001';
  const gerai2 = '00000000-0000-0000-0000-000000000002';
  const gerai3 = '00000000-0000-0000-0000-000000000003';
  // "Hari ini" untuk tes (tetap — tidak pakai jam dinding).
  final now = DateTime(2026, 11, 25, 7, 0);

  group('isPreviousCalendarDay', () {
    test('kemarin malam -> true', () {
      expect(
        isPreviousCalendarDay(DateTime(2026, 11, 24, 23, 30), now),
        isTrue,
      );
    });

    test('hari ini (00:30 / 06:59) -> false', () {
      expect(
        isPreviousCalendarDay(DateTime(2026, 11, 25, 0, 30), now),
        isFalse,
      );
      expect(
        isPreviousCalendarDay(DateTime(2026, 11, 25, 6, 59), now),
        isFalse,
      );
    });

    test('besok -> false', () {
      expect(
        isPreviousCalendarDay(DateTime(2026, 11, 26, 8, 0), now),
        isFalse,
      );
    });

    test('ganti bulan -> true', () {
      expect(
        isPreviousCalendarDay(
          DateTime(2026, 10, 31, 23, 59),
          DateTime(2026, 11, 1, 0, 5),
        ),
        isTrue,
      );
    });
  });

  group('CashShift.isAutoClosed', () {
    CashShift shift({required String status, String note = ''}) => CashShift(
          id: 'x',
          outletId: gerai1,
          cashierName: 'Budi',
          openedAt: DateTime(2026, 11, 24, 15, 40),
          openingFloat: 100000,
          status: status,
          note: note,
        );

    test('tutup + note Auto close -> true', () {
      expect(
        shift(status: 'closed', note: autoCloseNote).isAutoClosed,
        isTrue,
      );
    });

    test('masih open -> false', () {
      expect(
        shift(status: 'open', note: autoCloseNote).isAutoClosed,
        isFalse,
      );
    });

    test('tutup manual (note lain) -> false', () {
      expect(
        shift(status: 'closed', note: 'Laci pas').isAutoClosed,
        isFalse,
      );
    });
  });

  group('autoCloseStaleShifts (service)', () {
    setUpAll(() async {
      final dir = Directory.systemTemp.createTempSync('suka-tea-v39-test');
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
      // Benih langsung di Drift SEBELUM service init (supaya
      // CashShiftService.init memuatnya ke memori — dan hook init
      // v39 langsung meng-auto-close yang kemarin).
      final db = AppDatabase();
      // Shift kemarin (gerai 1): buka 24 Nov 15:40, modal 100rb.
      await db.into(db.cashShifts).insert(CashShiftsCompanion.insert(
            id: 'v39-stale-gerai1',
            outletId: gerai1,
            cashierName: 'Kasir Tes',
            openedAt: DateTime(2026, 11, 24, 15, 40),
            openingFloat: 100000,
            status: const Value('open'),
            note: const Value(''),
          ));
      // Shift hari ini (gerai 2): buka 25 Nov 06:00, modal 50rb.
      await db.into(db.cashShifts).insert(CashShiftsCompanion.insert(
            id: 'v39-today-gerai2',
            outletId: gerai2,
            cashierName: 'Kasir Tes',
            openedAt: DateTime(2026, 11, 25, 6, 0),
            openingFloat: 50000,
            status: const Value('open'),
            note: const Value(''),
          ));
      // Penjualan tunai gerai 1 di jendela shift kemarin:
      // 24 Nov 18:00, Rp21.000 tunai.
      await db.into(db.saleHistory).insert(SaleHistoryCompanion.insert(
            id: 'v39-sale-1',
            createdAt: DateTime(2026, 11, 24, 18, 0),
            itemsJson: '[]',
            total: 21000,
            method: 'tunai',
            paid: 21000,
            change: 0,
            outletId: const Value(gerai1),
          ));
      await OutletService.instance.init();
      await StockService.instance.init();
      await MenuService.instance.init();
      await SaleHistoryService.instance.init();
      await ExpenseService.instance.init();
      await CashierSessionService.instance.init();
      await CashShiftService.instance.init();
    });

    test('init() auto-close shift kemarin (counted = expected, selisih 0)',
        () {
      final shifts = CashShiftService.instance.shifts;
      final stale =
          shifts.firstWhere((s) => s.id == 'v39-stale-gerai1');
      expect(stale.isClosed, isTrue);
      expect(stale.countedCash, 121000); // 100rb modal + 21rb tunai
      expect(stale.expectedCash, 121000);
      expect(stale.difference, 0);
      expect(stale.note, autoCloseNote);
      expect(stale.isAutoClosed, isTrue);
      expect(CashShiftService.instance.openShiftFor(gerai1), isNull);
      // Shift hari ini (gerai 2) tetap terbuka.
      expect(
        CashShiftService.instance.openShiftFor(gerai2)?.id,
        'v39-today-gerai2',
      );
    });

    test('panggilan eksplisit menutup shift kemarin dari pull server',
        () async {
      // Shift kemarin gerai 3 "datang" dari server (pull) — belum
      // ada shift lokal di gerai itu, jadi diadopsi sebagai open.
      await CashShiftService.instance.applyPulledShifts(
        outletId: gerai3,
        serverOpens: [
          (
            clientUuid: 'v39-stale-gerai3',
            outletId: gerai3,
            cashierId: '',
            cashierName: 'Kasir Tes',
            openedAt: DateTime(2026, 11, 24, 16, 0),
            openingFloat: 75000,
            status: 'open',
            closedAt: null,
            closedByCashierId: '',
            closedByCashierName: '',
            countedCash: null,
            expectedCash: null,
            difference: null,
          ),
        ],
      );
      expect(
        CashShiftService.instance.openShiftFor(gerai3)?.id,
        'v39-stale-gerai3',
      );
      final closed = await CashShiftService.instance
          .autoCloseStaleShifts(now: now);
      expect(closed.length, 1);
      expect(closed.first.id, 'v39-stale-gerai3');
      expect(closed.first.countedCash, 75000); // tanpa penjualan
      expect(closed.first.expectedCash, 75000);
      expect(closed.first.difference, 0);
      expect(closed.first.isAutoClosed, isTrue);
      expect(CashShiftService.instance.openShiftFor(gerai3), isNull);
    });

    test('panggilan kedua no-op (idempotent)', () async {
      final closed =
          await CashShiftService.instance.autoCloseStaleShifts(now: now);
      expect(closed, isEmpty);
    });
  });

  group('Scaffold B6 (widget)', () {
    testWidgets('KeuanganPage punya Scaffold sendiri', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SukaTeaTheme.light,
          home: const KeuanganPage(role: AppRole.owner),
        ),
      );
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('LaporanPage punya Scaffold sendiri', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SukaTeaTheme.light,
          home: LaporanPage(role: AppRole.owner, onExitGerai: () {}),
        ),
      );
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });
}
