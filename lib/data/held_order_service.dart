import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local/app_database.dart';
import 'models.dart';

/// Satu order yang ditahan di Kasir.
class HeldOrder {
  const HeldOrder({
    required this.id,
    required this.label,
    required this.items,
    required this.createdAt,
  });

  final String id;

  /// Label otomatis: "Tahan 1 • 14:05" (nomor urut + jam tahan).
  final String label;
  final List<CartItem> items;
  final DateTime createdAt;

  int get subtotal => items.fold(0, (s, i) => s + i.total);
  int get count => items.fold(0, (s, i) => s + i.qty);

  String get summary =>
      items.map((i) => '${i.qty}x ${i.product.name}').join(', ');
}

/// Order tertahan — di memori (ChangeNotifier) dan dicerminkan ke
/// Drift (tabel HeldOrders). Dipakai Kasir: tahan keranjang saat ini,
/// pulihkan nanti (hanya bila keranjang kosong — bila berisi, kasir
/// memilih "Tahan & Buka" dulu). Diskon TIDAK ikut tertahan (diskon
/// itu per keranjang aktif; saat pulih, diskon mulai dari 0).
///
/// Semua tulis ke DB dibungkus try/catch (pola StockService): gagal
/// simpan tidak boleh crash app — state memori tetap yang dipakai.
class HeldOrderService extends ChangeNotifier {
  HeldOrderService._();

  static final HeldOrderService instance = HeldOrderService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<HeldOrder> _orders = [];
  bool _initialized = false;

  /// Order tertahan, urutan tahan (paling lama dulu).
  List<HeldOrder> get orders => List.unmodifiable(_orders);

  bool get isInitialized => _initialized;

  /// Baca Drift. Dipanggil di main() sebelum runApp.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.heldOrders).get();
      final list = <HeldOrder>[];
      for (final r in rows) {
        try {
          final items = (jsonDecode(r.itemsJson) as List<dynamic>)
              .map((e) => CartItem.fromJson(e as Map<String, dynamic>))
              .toList();
          list.add(
            HeldOrder(
              id: r.id,
              label: r.label,
              items: items,
              createdAt: r.createdAt,
            ),
          );
        } catch (e) {
          // Baris rusak (JSON tidak bisa dibaca) -> lewati, jangan
          // gagalkan seluruh daftar.
          debugPrint('HeldOrder baris rusak, dilewati: $e');
        }
      }
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _orders = list;
    } catch (e) {
      debugPrint('HeldOrder init gagal, mulai kosong: $e');
      _orders = [];
    }
    _initialized = true;
    notifyListeners();
  }

  /// Tahan keranjang saat ini. Label otomatis "Tahan N • HH:mm"
  /// (N = jumlah order tertahan + 1). Mengembalikan order yang dibuat.
  Future<HeldOrder> hold(List<CartItem> items) async {
    final now = DateTime.now();
    final label = 'Tahan ${_orders.length + 1} • '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final order = HeldOrder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      label: label,
      items: List<CartItem>.from(items),
      createdAt: now,
    );
    _orders = [..._orders, order];
    notifyListeners();
    try {
      await _database.into(_database.heldOrders).insert(
            HeldOrdersCompanion.insert(
              id: order.id,
              label: order.label,
              itemsJson: jsonEncode(
                order.items.map((i) => i.toJson()).toList(),
              ),
              createdAt: order.createdAt,
            ),
          );
    } catch (e) {
      debugPrint('HeldOrder simpan gagal (memori tetap ada): $e');
    }
    return order;
  }

  /// Pulihkan satu order ke keranjang: hapus dari daftar + DB,
  /// kembalikan item-itemnya. null = id tidak ada.
  Future<List<CartItem>?> restore(String id) async {
    final i = _orders.indexWhere((o) => o.id == id);
    if (i < 0) return null;
    final items = _orders[i].items;
    _orders = List<HeldOrder>.of(_orders)..removeAt(i);
    notifyListeners();
    try {
      await (_database.delete(_database.heldOrders)
            ..where((t) => t.id.equals(id)))
          .go();
    } catch (e) {
      debugPrint('HeldOrder pulih gagal hapus DB: $e');
    }
    return items;
  }

  /// Hapus order tertahan tanpa memulihkan (dengan konfirmasi di UI).
  Future<void> remove(String id) async {
    _orders = _orders.where((o) => o.id != id).toList();
    notifyListeners();
    try {
      await (_database.delete(_database.heldOrders)
            ..where((t) => t.id.equals(id)))
          .go();
    } catch (e) {
      debugPrint('HeldOrder hapus gagal simpan: $e');
    }
  }
}
