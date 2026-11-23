import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'models.dart';
import 'outlet_service.dart';
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

  /// Rekonstruksi CartItem dari item riwayat — dipakai void untuk
  /// mengembalikan stok. Modifier hanya menyimpan nama, jadi kind
  /// topping dikenali dari [toppingNames] (nama topping yang dikenal
  /// saat ini). priceDelta 0: deduksi stok tidak memakai harga.
  CartItem toCartItem(Set<String> toppingNames) {
    final variant = ProductVariant(
      id: variantId,
      name: variantName,
      price: unitPrice,
    );
    final product = Product(
      id: productId,
      name: productName,
      category: '',
      variants: [variant],
    );
    return CartItem(
      product: product,
      variant: variant,
      qty: qty,
      modifiers: modifiers
          .map(
            (name) => Modifier(
              name: name,
              kind: toppingNames.contains(name) ? 'topping' : 'other',
            ),
          )
          .toList(),
    );
  }
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
    this.discount = 0,
    this.isVoid = false,
    this.outletId = defaultOutletId,
    this.qrisAmount = 0,
    this.cashAmount = 0,
  });

  final String id;
  final DateTime createdAt;
  final List<SaleItem> items;

  /// Total yang dibayar = subtotal - diskon.
  final int total;
  final PaymentMethod method;
  final int paid;
  final int change;

  /// Diskon manual transaksi ini (0 bila tanpa diskon).
  final int discount;

  /// true = transaksi di-void Owner (stok dikembalikan, tidak
  /// dihitung di omzet/Keuangan/Laporan).
  final bool isVoid;

  /// Gerai tempat transaksi terjadi (Batch C4). Riwayat di HP ini
  /// hanya punya transaksi gerai yang login di HP ini.
  final String outletId;

  /// Bagian split payment (Batch C2): nominal yang dibayar via QRIS
  /// + tunai yang DITERIMA (bisa lebih dari sisa tunai — selisihnya
  /// kembalian). Transaksi non-split = 0; untuk split berlaku
  /// paid = qrisAmount + cashAmount.
  final int qrisAmount;
  final int cashAmount;

  /// Subtotal sebelum diskon (total + diskon).
  int get subtotal => total + discount;

  /// Jumlah cup terjual di transaksi ini.
  int get cups => items.fold(0, (s, i) => s + i.qty);

  /// Uang tunai yang TINGGAL di laci dari transaksi ini (untuk
  /// rekonsiliasi Tutup Kasir): Tunai = total; Split = total -
  /// bagian QRIS; selain itu 0. Kembalian sudah diperhitungkan —
  /// tunai yang diterima lebih dari sisa tunai kembali ke pelanggan,
  /// jadi tidak menambah isi laci.
  int get cashInDrawer {
    if (method == PaymentMethod.tunai) return total;
    if (method == PaymentMethod.split) {
      final cash = total - qrisAmount;
      return cash < 0 ? 0 : cash;
    }
    return 0;
  }

  SaleRecord copyWith({
    bool? isVoid,
    int? qrisAmount,
    int? cashAmount,
  }) =>
      SaleRecord(
        id: id,
        createdAt: createdAt,
        items: items,
        total: total,
        method: method,
        paid: paid,
        change: change,
        discount: discount,
        isVoid: isVoid ?? this.isVoid,
        outletId: outletId,
        qrisAmount: qrisAmount ?? this.qrisAmount,
        cashAmount: cashAmount ?? this.cashAmount,
      );

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
      discount: (json['discount'] as num? ?? 0).toInt(),
      isVoid: json['isVoid'] as bool? ?? false,
      outletId: json['outletId'] as String? ?? defaultOutletId,
      qrisAmount: (json['qrisAmount'] as num? ?? 0).toInt(),
      cashAmount: (json['cashAmount'] as num? ?? 0).toInt(),
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
        'discount': discount,
        'isVoid': isVoid,
        'outletId': outletId,
        'qrisAmount': qrisAmount,
        'cashAmount': cashAmount,
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
/// di [costs] dihitung Rp0 (bukan gagal). Topping juga menambah HPP:
/// tiap modifier topping = 1 porsi x biaya di [costs] (nama topping =
/// nama bahan stok; modifier gula/es tidak ada di costs, jadi lewati).
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
    for (final name in item.modifiers) {
      final cost = costs[name];
      if (cost != null) hpp += cost * 1 * item.qty;
    }
  }
  return hpp;
}

/// Ringkasan [sales] (sudah difilter satu hari oleh pemanggil).
/// Transaksi void DIKECUALIKAN (tidak masuk omzet, cup, HPP, laba,
/// maupun per cara bayar) — void = transaksi batal, bukan penjualan.
/// Transaksi split (Batch C2) dihitung SATU kali di omzet, di bawah
/// cara bayar `split` (bukan dobel ke QRIS + tunai).
DailyStats computeDailyStats(
  List<SaleRecord> sales,
  Map<String, List<RecipeLine>> recipes,
  Map<String, double> costs,
) {
  var omzet = 0;
  var cups = 0;
  var hpp = 0.0;
  final byMethod = <PaymentMethod, int>{};
  var txnCount = 0;
  for (final s in sales) {
    if (s.isVoid) continue;
    txnCount++;
    omzet += s.total;
    cups += s.cups;
    hpp += estimateHppForItems(s.items, recipes, costs);
    byMethod[s.method] = (byMethod[s.method] ?? 0) + s.total;
  }
  final hppInt = hpp.round();
  return DailyStats(
    omzet: omzet,
    txnCount: txnCount,
    cups: cups,
    avgPerTxn: txnCount == 0 ? 0 : omzet ~/ txnCount,
    hppEstimate: hppInt,
    labaEstimate: omzet - hppInt,
    byMethod: byMethod,
  );
}

/// Produk terlaris dari [sales], urut jumlah cup menurun.
/// Transaksi void DIKECUALIKAN.
List<TopProduct> topProducts(List<SaleRecord> sales, {int limit = 3}) {
  final counts = <String, int>{};
  for (final s in sales) {
    if (s.isVoid) continue;
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

  /// Transaksi pada tanggal [day] (banding tahun/bulan/tanggal saja)
  /// untuk satu gerai ([outletId] null = gerai aktif sesi ini).
  /// Termasuk yang void — Riwayat menampilkan semuanya (dengan label).
  List<SaleRecord> salesOn(DateTime day, {String? outletId}) {
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    return _sales
        .where((s) =>
            s.outletId == outlet &&
            s.createdAt.year == day.year &&
            s.createdAt.month == day.month &&
            s.createdAt.day == day.day)
        .toList();
  }

  /// Transaksi pada tanggal [day] yang BUKAN void — dipakai Keuangan
  /// + Laporan (omzet, tutup kasir, terlaris tidak menghitung void).
  List<SaleRecord> activeSalesOn(DateTime day, {String? outletId}) =>
      salesOn(day, outletId: outletId).where((s) => !s.isVoid).toList();

  /// Transaksi AKTIF (bukan void) dalam satu bulan — dipakai laporan
  /// Bulanan di Pantau Gerai. [month] cukup tahun + bulannya.
  List<SaleRecord> salesInMonth(DateTime month, {String? outletId}) {
    final outlet = outletId ?? OutletService.instance.currentOutletId;
    return _sales
        .where((s) =>
            !s.isVoid &&
            s.outletId == outlet &&
            s.createdAt.year == month.year &&
            s.createdAt.month == month.month)
        .toList();
  }

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
              'discount': r.discount,
              'isVoid': r.isVoid,
              'outletId': r.outletId,
              'qrisAmount': r.qrisAmount,
              'cashAmount': r.cashAmount,
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
  /// SESUDAH deductForSale. [total] = yang dibayar = subtotal -
  /// diskon; [discount] dicatat supaya bisa diaudit di Riwayat.
  /// [outletId] null = gerai aktif sesi ini. [qrisAmount]/[cashAmount]
  /// = bagian split (Batch C2); transaksi non-split = 0.
  /// Mengembalikan record yang dicatat.
  Future<SaleRecord> recordSale({
    required List<CartItem> items,
    required int total,
    required PaymentMethod method,
    required int paid,
    int discount = 0,
    String? outletId,
    int qrisAmount = 0,
    int cashAmount = 0,
  }) async {
    final record = SaleRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      items: items.map(SaleItem.fromCartItem).toList(),
      total: total,
      method: method,
      paid: paid,
      change: paid - total,
      discount: discount,
      outletId: outletId ?? OutletService.instance.currentOutletId,
      qrisAmount: qrisAmount,
      cashAmount: cashAmount,
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
              discount: Value(record.discount),
              isVoid: const Value(false),
              outletId: Value(record.outletId),
              qrisAmount: Value(record.qrisAmount),
              cashAmount: Value(record.cashAmount),
            ),
          );
    } catch (e) {
      debugPrint('SaleHistory simpan gagal (riwayat memori tetap ada): $e');
    }
    return record;
  }

  /// Tandai satu transaksi sebagai void (HANYA Owner — dicek di UI).
  /// Stok dikembalikan DULU oleh pemanggil (restoreForSale), baru
  /// record ini ditandai. false = id tidak ada / sudah void.
  /// Transaksi void tetap tampil di Riwayat (dengan label VOID) tapi
  /// tidak dihitung di statistik mana pun.
  Future<bool> voidSale(String id) async {
    final i = _sales.indexWhere((s) => s.id == id);
    if (i < 0 || _sales[i].isVoid) return false;
    _sales[i] = _sales[i].copyWith(isVoid: true);
    notifyListeners();
    try {
      await (_database.update(_database.saleHistory)
            ..where((t) => t.id.equals(id)))
          .write(const SaleHistoryCompanion(isVoid: Value(true)));
    } catch (e) {
      debugPrint('SaleHistory void gagal simpan (memori tetap void): $e');
    }
    return true;
  }
}
