import 'package:flutter/foundation.dart';

import '../../data/supabase_client.dart';
import 'qris_service.dart';

/// Penyimpanan kode QRIS statis merchant (Owner saja).
///
/// Nilai asli TIDAK PERNAH di-hardcode di repo: Owner menempelkannya di
/// layar Pengaturan QRIS, lalu disimpan ke Supabase (`app_settings`,
/// key `qris_static_payload`, RLS Owner-only) bila outlet + Supabase
/// sudah dikonfigurasi. Sebelum itu, nilai hanya hidup di memori aplikasi.
/// Di M5, nilai dienkripsi di aplikasi sebelum disimpan.
class QrisSettingsService {
  QrisSettingsService._();

  static final QrisSettingsService instance = QrisSettingsService._();

  /// Diisi app saat outlet aktif dipilih (M0). Null = belum ada outlet.
  String? currentOutletId;

  String? _staticPayload;
  bool _loaded = false;

  String? get staticPayload => _staticPayload;

  bool get isConfigured =>
      _staticPayload != null && _staticPayload!.isNotEmpty;

  String? get merchantName =>
      _staticPayload == null ? null : QrisService.merchantName(_staticPayload!);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return;
    }
    try {
      final row = await SupabaseService.instance.client
          .from('app_settings')
          .select('value')
          .eq('outlet_id', currentOutletId!)
          .eq('key', 'qris_static_payload')
          .maybeSingle();
      final value = (row as Map?)?['value'] as String?;
      if (value != null && QrisService.isValidStaticPayload(value)) {
        _staticPayload = value;
      }
    } catch (e) {
      debugPrint('Muat pengaturan QRIS gagal (pakai memori): $e');
    }
  }

  /// Simpan payload statis (sudah divalidasi pemanggil). Mengembalikan
  /// true bila tersimpan (di Supabase bila memungkinkan, jika tidak di
  /// memori saja — nilai tetap harus dimasukkan ulang setelah restart
  /// sampai outlet + Supabase aktif).
  Future<bool> save(String payload) async {
    if (!QrisService.isValidStaticPayload(payload)) return false;
    _staticPayload = payload;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return true;
    }
    try {
      await SupabaseService.instance.client.from('app_settings').upsert({
        'outlet_id': currentOutletId,
        'key': 'qris_static_payload',
        'value': payload,
      });
      return true;
    } catch (e) {
      debugPrint('Simpan pengaturan QRIS ke Supabase gagal: $e');
      return true; // nilai tetap ada di memori untuk sesi ini
    }
  }

  Future<void> clear() async {
    _staticPayload = null;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return;
    }
    try {
      await SupabaseService.instance.client
          .from('app_settings')
          .delete()
          .eq('outlet_id', currentOutletId!)
          .eq('key', 'qris_static_payload');
    } catch (e) {
      debugPrint('Hapus pengaturan QRIS gagal: $e');
    }
  }
}
