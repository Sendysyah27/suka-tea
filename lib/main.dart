import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/splash_screen.dart';
import 'data/held_order_service.dart';
import 'data/menu_service.dart';
import 'data/outlet_service.dart';
import 'data/sale_history.dart';
import 'data/stock_service.dart';
import 'data/supabase_client.dart';
import 'data/sync_service.dart';
import 'data/topping_service.dart';
import 'features/login/cashier_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Splash tampil DULU (frame pertama langsung foto gerai, bukan
  // layar putih) — init service jalan di belakangnya, lalu runApp
  // kedua mengganti splash dengan app begitu semua init selesai.
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SplashScreen(),
    ),
  );
  // Tanpa SUPABASE_URL/ANON_KEY app tetap jalan offline (menu seed).
  await SupabaseService.instance.init();
  // Daftar gerai dari Drift (seed 4 gerai placeholder kalau tabel
  // masih kosong). Halaman Login membaca dari sini.
  await OutletService.instance.init();
  // Sesi kasir terakhir dari Drift (Batch C5) — _LoginGate membaca
  // dari sini untuk langsung masuk gerai tanpa login ulang. Harus
  // sesudah OutletService (sesi menunjuk ke outletId yang ada).
  await CashierSessionService.instance.init();
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
  // Order Pending di Kasir dari Drift (kosong bila belum ada).
  await HeldOrderService.instance.init();
  // Sinkronisasi Supabase (Batch C6): flush antrean outbox yang
  // masih pending + retry berkala 60 dtk selama ada pending.
  // Fire-and-forget — TIDAK PERNAH memblokir jualan: gagal sync =
  // tetap pending, coba lagi nanti. Tanpa Supabase terkonfigurasi
  // sync dilewati diam-diam (mode offline).
  SyncService.instance.start();
  runApp(const SukaTeaApp());
}
