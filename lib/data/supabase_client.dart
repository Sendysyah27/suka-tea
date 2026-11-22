import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Client Supabase (placeholder — tanpa kredensial asli di repo).
/// Isi via --dart-define SUPABASE_URL / SUPABASE_ANON_KEY atau file .env
/// (tidak di-commit). Tanpa keduanya app tetap jalan offline (menu seed).
class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();

  bool _initialized = false;

  bool get isConfigured => _initialized;

  Future<void> init() async {
    const url = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
    const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
    if (url.isEmpty || anonKey.isEmpty) {
      debugPrint('Supabase belum dikonfigurasi — mode offline (menu seed).');
      return;
    }
    await Supabase.initialize(url: url, publishableKey: anonKey);
    _initialized = true;
  }

  SupabaseClient get client {
    if (!_initialized) {
      throw StateError('Supabase belum dikonfigurasi.');
    }
    return Supabase.instance.client;
  }
}
