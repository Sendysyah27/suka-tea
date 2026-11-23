import 'package:flutter/material.dart';

import 'app/app.dart';
import 'data/held_order_service.dart';
import 'data/menu_service.dart';
import 'data/sale_history.dart';
import 'data/stock_service.dart';
import 'data/supabase_client.dart';
import 'data/topping_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Tanpa SUPABASE_URL/ANON_KEY app tetap jalan offline (menu seed).
  await SupabaseService.instance.init();
  // Stok + resep dari Drift (seed kalau tabel masih kosong). Kasir
  // memakai StockService saat cek shortage + potong stok.
  await StockService.instance.init();
  // Topping dari Drift (seed kalau tabel masih kosong). Sheet opsi
  // produk membaca dari sini; butuh StockService siap dulu (sinkron
  // topping -> bahan stok).
  await ToppingService.instance.init();
  // Menu dari LocalProducts (seed kalau tabel masih kosong). Kasir +
  // Kelola Menu membaca sumber yang sama (MenuService).
  await MenuService.instance.init();
  // Riwayat penjualan dari Drift (kosong bila belum ada transaksi).
  await SaleHistoryService.instance.init();
  // Order yang ditahan di Kasir dari Drift (kosong bila belum ada).
  await HeldOrderService.instance.init();
  runApp(const SukaTeaApp());
}
