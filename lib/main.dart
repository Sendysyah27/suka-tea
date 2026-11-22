import 'package:flutter/material.dart';

import 'app/app.dart';
import 'data/stock_service.dart';
import 'data/supabase_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Tanpa SUPABASE_URL/ANON_KEY app tetap jalan offline (menu seed).
  await SupabaseService.instance.init();
  // Stok + resep dari Drift (seed kalau tabel masih kosong). Kasir
  // memakai StockService saat cek shortage + potong stok.
  await StockService.instance.init();
  runApp(const SukaTeaApp());
}
