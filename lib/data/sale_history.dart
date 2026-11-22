import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'models.dart';
import 'recipe_logic.dart';

/// Satu item dalam satu transaksi yang sudah dibayar.
/// Disimpan sebagai JSON di tabel SaleHistory (itemsJson).
class SaleItem {
  const SaleItem({
    required this.productId,
    required this.productName,
    required this.variantId,
    required this.variantName,
    required this.qty,
    required this.unitPrice,
    this.modifiers = const [],
  });

  final String productId;
  final String productName;
  final String variantId;
  final String variantName;
  final int qty;

  /// Harga satuan SUDAH termasuk delta topping.
  final int unitPrice;

  /// Nama modifier saja, mis. ['Normal', 'Es Normal', 'Boba'].
  final List<String> modifiers;

  int get total => unitPrice * qty;

  factory SaleItem.fromCartItem(CartItem item) => SaleItem(
        productId: item.product.id,
        productName: item.product.name,
        variantId: item.variant.id,
        variantName: item.variant.name,
        qty: item.qty,
        unitPrice: item.unitPrice,
        modifiers: item.modifiers.map((m) => m.name).toList(),
      );

  factory SaleItem.fromJson(Map<String, dynamic> json) => SaleItem(
        productId: json['productId'] as String? ?? '',
        productName: json['productName'] as String? ?? '',
        variantId: json['variantId'] as String? ?? '',
        variantName: json['variantName'] as String? ?? '',
        qty: (json['qty'] as num? ?? 1).toInt(),
        unitPrice: (json['unitPrice'] as num? ?? 0).toInt(),
        modifiers: (json['modifiers'] as List<dynamic>? ?? const [])
            .map((m) => m.toString())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'productName': productName,
        'variantId': variantId,
        'variantName': variantName,
        'qty': qty,
        'unitPrice': unitPrice,
        'modifiers': modifiers,
      };
}

/// Satu transaksi selesai (sudah dibayar).
class SaleRecord {
  const SaleRecord({
    required this.id,
    required this.createdAt,
    required this.items,
    required this.total,
    required this.method,
    required this.paid,
    required this.change,
  });

  final String id;
  final DateTime createdAt;
  final List<SaleItem> items;
  final int total;
  final PaymentMethod method;
  final int paid;
  final int change;

  /// Jumlah cup terjual di transaksi ini.
  int get cups => items.fold(0, (s, i) => s + i.qty);

  factory SaleRecord.fromJson(Map<String, dynamic> json) {
    final methodName = json['method'] as String? ?? 'tunai';
    return SaleRecord(
      id: json['id'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => SaleItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: (json['total'] as num? ?? 0).toInt(),
      method: PaymentMethod.values.firstWhere(
        (m) => m.name == methodName,
        orElse: () => PaymentMethod.tunai,
      ),
      paid: (json['paid'] as num? ?? 0).toInt(),
      change: (json['change'] as num? ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'items': items.map((i) => i.toJson()).toList(),
        'total': total,
        'method': method.name,
        'paid': paid,
        'change': change,
      };
}

/// Ringkasan satu hari (pure — dari daftar transaksi yang sudah
/// difilter hari itu). HPP = estimasi dari resep x biaya bahan.
class DailyStats {
  const DailyStats({
    required this.omzet,
    required this.txnCount,
    required this.cups,
    required this.avgPerTxn,
    required this.hppEstimate,
    required this.labaEstimate,
    required this.byMethod,
  });

  final int omzet;
  final int txnCount;
  final int cups;
  final int avgPerTxn;

  /// HPP estimasi (rupiah, dibulatkan) — dari resep + biaya bahan.
  final int hppEstimate;

  /// Laba estimasi = omzet - HPP estimasi. Pengeluaran harian belum
  /// dicatat di app, jadi belum dikurangi di sini.
  final int labaEstimate;

  /// Total per cara bayar.
  final Map<PaymentMethod, int> byMethod;
}

/// Satu produk terlaris (nama + jumlah cup).
class TopProduct {
  const TopProduct({required this.name, required this.qty});

  final String name;
  final int qty;
}

/// HPP estimasi satu transaksi: untuk tiap cup, jumlahkan
/// (qty bahan di resep x biaya bahan per satuan). Bahan yang tidak ada
/// di [costs] dihitung Rp0 (bukan gagal). Topping tidak masuk resep,
/// jadi tidak menambah HPP di sini.
double estimateHppForItems(
  List<SaleItem> items,
  Map<String, List<RecipeLine>> recipes,
  Map<String, double> costs,
) {
  var hpp = 0.0;
  for (final item in items) {
    for (final line in recipes[item.variantId] ?? const <RecipeLine>[]) {
      hpp += line.qty * (costs[line.stockName] ?? 0) * item.qty;
    }
  }
  return hpp;
}

/// Ringkasan [sales] (sudah difilter satu hari oleh pemanggil).
DailyStats computeDailyStats(
  List<SaleRecord> sales,
  Map<String, List<RecipeLine>> recipes,
  Map<String, double> costs,
) {
  var omzet = 0;
  var cups = 0;
  var hpp = 0.0;
  final byMethod = <PaymentMethod, int>{};
  for (final s in sales) {
    omzet += s.total;
    cups += s.cups;
    hpp += estimateHppForItems(s.items, recipes, costs);
    byMethod[s.method] = (byMethod[s.method] ?? 0) + s.total;
  }
  final hppInt = hpp.round();
  return DailyStats(
    omzet: omzet,
    txnCount: sales.length,
    cups: cups,
    avgPerTxn: sales.isEmpty ? 0 : omzet ~/ sales.length,
    hppEstimate: hppInt,
    labaEstimate: omzet - hppInt,
    byMethod: byMethod,
  );
}

/// Produk terlaris dari [sales], urut jumlah cup menurun.
List<TopProduct> topProducts(List<SaleRecord> sales, {int limit = 3}) {
  final counts = <String, int>{};
  for (final s in sales) {
    for (final item in s.items) {
      counts[item.productName] = (counts[item.productName] ?? 0) + item.qty;
    }
  }
  final list = counts.entries
      .map((e) => TopProduct(name: e.key, qty: e.value))
      .toList()
    ..sort((a, b) => b.qty.compareTo(a.qty));
  return list.take(limit).toList();
}

/// Riwayat penjualan — di memori (ChangeNotifier) dan dicerminkan ke
/// Drift (tabel SaleHistory). Semua tulis ke DB dibungkus try/catch
/// (pola StockService): gagal simpan tidak boleh crash app.
class SaleHistoryService extends ChangeNotifier {
  SaleHistoryService._();

  static final SaleHistoryService instance = SaleHistoryService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<SaleRecord> _sales = [];
  bool _initialized = false;

  /// Semua transaksi, terbaru dulu (salinan).
  List<SaleRecord> get sales => List.unmodifiable(_sales);

  bool get isInitialized => _initialized;

  /// Transaksi pada tanggal [day] (banding tahun/bulan/tanggal saja).
  List<SaleRecord> salesOn(DateTime day) => _sales
      .where((s) =>
          s.createdAt.year == day.year &&
          s.createdAt.month == day.month &&
          s.createdAt.day == day.day)
      .toList();

  /// Baca Drift; tabel kosong = belum ada transaksi (bukan error).
  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.saleHistory).get();
      final list = rows
          .map(
            (r) => SaleRecord.fromJson({
              'id': r.id,
              'createdAt': r.createdAt.toIso8601String(),
              'items': jsonDecode(r.itemsJson) as List<dynamic>,
              'total': r.total,
              'method': r.method,
              'paid': r.paid,
              'change': r.change,
            }),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _sales = list;
    } catch (e) {
      debugPrint('SaleHistory init gagal, riwayat mulai kosong: $e');
      _sales = [];
    }
    _initialized = true;
    notifyListeners();
  }

  /// Catat satu penjualan selesai. Dipanggil di _selesaikanBayar()
  /// SESUDAH deductForSale. Mengembalikan record yang dicatat.
  Future<SaleRecord> recordSale({
    required List<CartItem> items,
    required int total,
    required PaymentMethod method,
    required int paid,
  }) async {
    final record = SaleRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      items: items.map(SaleItem.fromCartItem).toList(),
      total: total,
      method: method,
      paid: paid,
      change: paid - total,
    );
    _sales = [record, ..._sales];
    notifyListeners();
    try {
      await _database.into(_database.saleHistory).insert(
            SaleHistoryCompanion.insert(
              id: record.id,
              createdAt: record.createdAt,
              itemsJson: jsonEncode(
                record.items.map((i) => i.toJson()).toList(),
              ),
              total: record.total,
              method: record.method.name,
              paid: record.paid,
              change: record.change,
            ),
          );
    } catch (e) {
      debugPrint('SaleHistory simpan gagal (riwayat memori tetap ada): $e');
    }
    return record;
  }
}
