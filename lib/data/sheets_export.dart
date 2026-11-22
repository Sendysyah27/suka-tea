import 'package:flutter/foundation.dart';

import 'supabase_client.dart';

/// Export laporan ke Google Sheets via Edge Function `export-sheets`.
/// Sheets HANYA untuk laporan/export — bukan database utama.
/// Hanya Owner yang boleh memanggil (dicek juga di RLS + Edge Function).
Future<bool> exportShiftToSheets({required String shiftId}) async {
  if (!SupabaseService.instance.isConfigured) {
    debugPrint('Export Sheets dilewati: Supabase belum dikonfigurasi.');
    return false;
  }
  try {
    await SupabaseService.instance.client.functions.invoke(
      'export-sheets',
      body: {'shift_id': shiftId},
    );
    return true;
  } catch (e) {
    debugPrint('Export Sheets gagal: $e');
    return false;
  }
}
