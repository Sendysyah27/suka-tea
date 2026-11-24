import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/cash.dart';
import 'package:suka_tea/data/expense_service.dart';
import 'package:suka_tea/data/models.dart';
import 'package:suka_tea/data/sale_history.dart';

SaleRecord _sale({
  required String id,
  required DateTime at,
  required PaymentMethod method,
  required int total,
  int qrisAmount = 0,
  bool isVoid = false,
  String outletId = 'outlet-1',
}) =>
    SaleRecord(
      id: id,
      createdAt: at,
      items: const [],
      total: total,
      method: method,
      paid: total,
      change: 0,
      outletId: outletId,
      qrisAmount: qrisAmount,
      isVoid: isVoid,
    );

Expense _expense({
  required String id,
  required DateTime at,
  required int amount,
  bool isCash = true,
  String outletId = 'outlet-1',
}) =>
    Expense(
      id: id,
      outletId: outletId,
      category: 'Operasional',
      amount: amount,
      isCash: isCash,
      createdAt: at,
    );

void main() {
  final from = DateTime(2026, 11, 24, 8, 0);
  final to = DateTime(2026, 11, 24, 10, 0);

  group('cashInWindow', () {
    test('tunai penuh + split hanya bagian tunai, QRIS 0', () {
      final sales = [
        _sale(
          id: 'a',
          at: DateTime(2026, 11, 24, 8, 30),
          method: PaymentMethod.tunai,
          total: 21000,
        ),
        _sale(
          id: 'b',
          at: DateTime(2026, 11, 24, 9, 0),
          method: PaymentMethod.split,
          total: 14000,
          qrisAmount: 10000,
        ),
        _sale(
          id: 'c',
          at: DateTime(2026, 11, 24, 9, 30),
          method: PaymentMethod.qris,
          total: 24000,
        ),
      ];
      expect(
        cashInWindow(sales, outletId: 'outlet-1', from: from, to: to),
        21000 + 4000 + 0,
      );
    });

    test('void dikecualikan', () {
      final sales = [
        _sale(
          id: 'a',
          at: DateTime(2026, 11, 24, 8, 30),
          method: PaymentMethod.tunai,
          total: 21000,
        ),
        _sale(
          id: 'b',
          at: DateTime(2026, 11, 24, 8, 45),
          method: PaymentMethod.tunai,
          total: 9000,
          isVoid: true,
        ),
      ];
      expect(
        cashInWindow(sales, outletId: 'outlet-1', from: from, to: to),
        21000,
      );
    });

    test('jendela [from, to): batas bawah masuk, batas atas tidak', () {
      final sales = [
        _sale(
          id: 'a',
          at: DateTime(2026, 11, 24, 8, 0),
          method: PaymentMethod.tunai,
          total: 5000,
        ),
        _sale(
          id: 'b',
          at: DateTime(2026, 11, 24, 10, 0),
          method: PaymentMethod.tunai,
          total: 7000,
        ),
        _sale(
          id: 'c',
          at: DateTime(2026, 11, 24, 7, 59),
          method: PaymentMethod.tunai,
          total: 3000,
        ),
      ];
      expect(
        cashInWindow(sales, outletId: 'outlet-1', from: from, to: to),
        5000,
      );
    });

    test('gerai lain dikecualikan', () {
      final sales = [
        _sale(
          id: 'a',
          at: DateTime(2026, 11, 24, 8, 30),
          method: PaymentMethod.tunai,
          total: 21000,
        ),
        _sale(
          id: 'b',
          at: DateTime(2026, 11, 24, 8, 30),
          method: PaymentMethod.tunai,
          total: 21000,
          outletId: 'outlet-2',
        ),
      ];
      expect(
        cashInWindow(sales, outletId: 'outlet-1', from: from, to: to),
        21000,
      );
    });
  });

  group('expectedCash / cashDifference', () {
    test('expected = modal + tunai masuk - pengeluaran tunai', () {
      expect(
        expectedCash(
          openingFloat: 50000,
          cashIn: 120000,
          cashExpenses: 15000,
        ),
        155000,
      );
    });

    test('selisih: pas 0, kurang negatif, lebih positif', () {
      expect(cashDifference(counted: 155000, expected: 155000), 0);
      expect(cashDifference(counted: 150000, expected: 155000), -5000);
      expect(cashDifference(counted: 160000, expected: 155000), 5000);
    });
  });

  group('pengeluaran', () {
    test('totalExpenses menjumlah semua', () {
      final list = [
        _expense(id: 'a', at: from, amount: 25000),
        _expense(id: 'b', at: from, amount: 10000, isCash: false),
      ];
      expect(totalExpenses(list), 35000);
    });

    test('expensesOnDay hanya hari + gerai itu', () {
      final list = [
        _expense(id: 'a', at: DateTime(2026, 11, 24, 9, 0), amount: 25000),
        _expense(
          id: 'b',
          at: DateTime(2026, 11, 23, 9, 0),
          amount: 10000,
        ),
        _expense(
          id: 'c',
          at: DateTime(2026, 11, 24, 9, 0),
          amount: 5000,
          outletId: 'outlet-2',
        ),
      ];
      expect(
        expensesOnDay(
          list,
          outletId: 'outlet-1',
          day: DateTime(2026, 11, 24),
        ),
        25000,
      );
    });

    test('cashExpensesInWindow hanya tunai dalam jendela', () {
      final list = [
        _expense(id: 'a', at: DateTime(2026, 11, 24, 8, 30), amount: 15000),
        _expense(
          id: 'b',
          at: DateTime(2026, 11, 24, 8, 45),
          amount: 20000,
          isCash: false,
        ),
        _expense(id: 'c', at: DateTime(2026, 11, 24, 10, 0), amount: 9000),
      ];
      expect(
        cashExpensesInWindow(list, outletId: 'outlet-1', from: from, to: to),
        15000,
      );
    });
  });
}
