import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_client.dart';

/// Export laporan ke Google Sheets via Edge Function `export-sheets`.
/// Sheets HANYA untuk laporan/export — bukan database utama.
/// Hanya Owner yang boleh memanggil (tombol di Laporan hanya tampil
/// untuk Owner — lihat roles.canExportSheets).
///
/// [shiftId] = TANGGAL 'YYYY-MM-DD' hari yang diekspor (tutup kasir =
/// harian; app tidak punya konsep shift). [outletId] = gerai aktif.
/// Mengembalikan record sukses/pesan untuk SnackBar pemanggil.
typedef ExportResult = ({bool ok, String message});

/// Tanggal hari ini sebagai shiftId export ('YYYY-MM-DD', zona lokal).
/// [now] hanya untuk test (default = sekarang).
String shiftIdForToday([DateTime? now]) {
  final d = now ?? DateTime.now();
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}

/// Terjemahkan jawaban mentah Edge Function ke pesan untuk pengguna.
/// Murni (tanpa Supabase) supaya bisa di-test.
ExportResult parseExportResponse(dynamic data) {
  if (data is! Map) {
    return (ok: false, message: 'Export Sheets gagal — jawaban server tidak dikenal.');
  }
  if (data['ok'] != true) {
    final err = data['error'];
    if (err is String && err.isNotEmpty) return (ok: false, message: err);
    final reason = data['reason'];
    if (reason is String && reason.isNotEmpty) {
      return (ok: false, message: 'Export Sheets gagal: $reason.');
    }
    return (ok: false, message: 'Export Sheets gagal.');
  }
  final counts = data['counts'];
  final txnCount = counts is Map ? (counts['transactions'] as num? ?? 0).toInt() : 0;
  final note = data['note'];
  var message = 'Export Sheets selesai: $txnCount transaksi hari ini.';
  if (note is String && note.isNotEmpty) {
    message += ' $note';
  }
  return (ok: true, message: message);
}

Future<ExportResult> exportShiftToSheets({
  required String outletId,
  required String shiftId,
}) async {
  if (!SupabaseService.instance.isConfigured) {
    return (
      ok: false,
      message: 'Export Sheets dilewati: Supabase belum dikonfigurasi.',
    );
  }
  try {
    final res = await SupabaseService.instance.client.functions.invoke(
      'export-sheets',
      body: {'shift_id': shiftId, 'outlet_id': outletId},
    );
    return parseExportResponse(res.data);
  } on FunctionsException catch (e) {
    // Edge Function mengembalikan 4xx/5xx dengan body JSON {ok, error}:
    // details membawa body itu — tampilkan pesannya apa adanya.
    final result = parseExportResponse(e.details);
    debugPrint('Export Sheets gagal (${e.statusCode}): ${e.details}');
    return result;
  } catch (e) {
    debugPrint('Export Sheets gagal: $e');
    return (
      ok: false,
      message: 'Export Sheets gagal — periksa koneksi / Edge Function belum di-deploy.',
    );
  }
}
