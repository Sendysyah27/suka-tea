import 'package:flutter/material.dart';

import 'app/app.dart';
import 'data/supabase_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Tanpa SUPABASE_URL/ANON_KEY app tetap jalan offline (menu seed).
  await SupabaseService.instance.init();
  runApp(const SruputApp());
}
