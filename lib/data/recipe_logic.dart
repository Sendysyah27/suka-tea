import 'models.dart';

/// Satu baris resep: tiap 1 cup varian memakai [qty] [stockName].
/// Satuan mengikuti StockItem (kg untuk Teh/Gula/Es batu, pcs untuk
/// Cup/Sedotan/dll). Kunci resep = variant id (mis. 'manggo-milktea_r').
class RecipeLine {
  const RecipeLine({required this.stockName, required this.qty});

  final String stockName;
  final double qty;

  RecipeLine copyWith({String? stockName, double? qty}) => RecipeLine(
        stockName: stockName ?? this.stockName,
        qty: qty ?? this.qty,
      );

  factory RecipeLine.fromJson(Map<String, dynamic> json) => RecipeLine(
        stockName: json['stockName'] as String,
        qty: (json['qty'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'stockName': stockName, 'qty': qty};
}

/// Satu bahan yang tidak cukup untuk keranjang saat ini.
class Shortage {
  const Shortage({
    required this.stockName,
    required this.unit,
    required this.needed,
    required this.available,
  });

  final String stockName;
  final String unit;
  final double needed;
  final double available;

  /// Selisih yang kurang (selalu > 0 untuk hasil findShortages).
  double get missing => needed - available;
}

/// Total pemakaian per bahan untuk seluruh keranjang:
/// qty resep per cup * qty item. Bahan yang tidak ada di [stockByName]
/// (mis. resep menunjuk bahan yang sudah dihapus Owner) dilewati —
/// pemakaian tidak boleh gagal hanya karena satu baris resep basi.
Map<String, double> computeDeductions(
  List<CartItem> cart,
  Map<String, List<RecipeLine>> recipes,
  Map<String, StockItem> stockByName,
) {
  final out = <String, double>{};
  for (final item in cart) {
    for (final line in recipes[item.variant.id] ?? const <RecipeLine>[]) {
      if (!stockByName.containsKey(line.stockName)) continue;
      out[line.stockName] =
          (out[line.stockName] ?? 0) + line.qty * item.qty;
    }
  }
  return out;
}

/// Bahan yang pemakaiannya melebihi stok saat ini (needed > available).
/// Urutan mengikuti urutan pemakaian pertama di keranjang.
List<Shortage> findShortages(
  List<CartItem> cart,
  Map<String, List<RecipeLine>> recipes,
  Map<String, StockItem> stockByName,
) {
  final needs = computeDeductions(cart, recipes, stockByName);
  final out = <Shortage>[];
  for (final entry in needs.entries) {
    final stock = stockByName[entry.key]!;
    if (entry.value > stock.qty) {
      out.add(Shortage(
        stockName: entry.key,
        unit: stock.unit,
        needed: entry.value,
        available: stock.qty,
      ));
    }
  }
  return out;
}
