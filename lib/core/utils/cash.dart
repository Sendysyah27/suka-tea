/// Matematika kas tunai murni (tanpa Flutter) — bisa di-unit-test.
///
/// Dipakai sheet "Uang diterima" di Kasir: nominal cepat, kembalian,
/// dan pembulatan QRIS ke Rp500.
///
/// Batch C7 (tutup kas + pengeluaran): hitung tunai masuk dalam
/// jendela shift, expected tutup kas, selisih, dan total pengeluaran.
library;

import '../../data/expense_service.dart';
import '../../data/sale_history.dart';

/// Bulatkan ke atas ke kelipatan Rp500 terdekat (bila sudah pas,
/// naik satu langkah Rp500 — supaya "Bulatkan" selalu berubah).
int roundUpTo500(int amount) {
  final rounded = ((amount + 499) ~/ 500) * 500;
  return rounded == amount ? rounded + 500 : rounded;
}

/// Kembalian = diterima - total. Negatif = kurang bayar.
int computeChange(int received, int total) => received - total;

/// Nominal cepat untuk bayar tunai: selalu diawali "Uang pas" (= total),
/// lalu pecahan 10K/20K/50K/100K yang >= total. Tanpa duplikat, urut naik.
List<int> quickCashAmounts(int total) {
  const pecahan = [10000, 20000, 50000, 100000];
  final out = <int>{total};
  for (final p in pecahan) {
    if (p >= total) out.add(p);
  }
  return out.toList()..sort();
}

/// Tunai masuk dari [sales] dalam jendela [from, to) untuk gerai
/// [outletId] — hanya transaksi AKTIF (void dikecualikan).
/// Tunai = total; Split = bagian tunai (total − QRIS); cara bayar
/// lain = 0 (lihat SaleRecord.cashInDrawer). Jendela setengah
/// terbuka: penjualan tepat di [from] masuk, tepat di [to] tidak
/// (supaya shift berturut-turut tidak menghitung dobel).
int cashInWindow(
  List<SaleRecord> sales, {
  required String outletId,
  required DateTime from,
  required DateTime to,
}) {
  var sum = 0;
  for (final s in sales) {
    if (s.isVoid) continue;
    if (s.outletId != outletId) continue;
    if (s.createdAt.isBefore(from) || !s.createdAt.isBefore(to)) continue;
    sum += s.cashInDrawer;
  }
  return sum;
}

/// Uang yang seharusnya ada di laci saat tutup kas:
/// modal awal + tunai masuk − pengeluaran TUNAI.
int expectedCash({
  required int openingFloat,
  required int cashIn,
  required int cashExpenses,
}) =>
    openingFloat + cashIn - cashExpenses;

/// Selisih tutup kas: positif = lebih, negatif = kurang, 0 = pas.
int cashDifference({required int counted, required int expected}) =>
    counted - expected;

/// Total pengeluaran [expenses] (semua jenis — tunai + non-tunai).
int totalExpenses(Iterable<Expense> expenses) =>
    expenses.fold(0, (sum, e) => sum + e.amount);

/// Total pengeluaran hari [day] di gerai [outletId].
int expensesOnDay(
  List<Expense> expenses, {
  required String outletId,
  required DateTime day,
}) {
  var sum = 0;
  for (final e in expenses) {
    if (e.outletId != outletId) continue;
    if (e.createdAt.year != day.year ||
        e.createdAt.month != day.month ||
        e.createdAt.day != day.day) {
      continue;
    }
    sum += e.amount;
  }
  return sum;
}

/// Pengeluaran TUNAI dalam jendela [from, to) di gerai [outletId] —
/// yang mengurangi expected tutup kas. Non-tunai tidak sentuh laci.
int cashExpensesInWindow(
  List<Expense> expenses, {
  required String outletId,
  required DateTime from,
  required DateTime to,
}) {
  var sum = 0;
  for (final e in expenses) {
    if (!e.isCash) continue;
    if (e.outletId != outletId) continue;
    if (e.createdAt.isBefore(from) || !e.createdAt.isBefore(to)) continue;
    sum += e.amount;
  }
  return sum;
}
