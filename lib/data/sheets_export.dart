import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_client.dart';
import '../features/login/cashier_session.dart';

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
  // SEC-1 R-03: EF sekarang mewajibkan bukti PIN Owner di memori.
  final proof = CashierSessionService.instance.sessionProof;
  if (proof['owner_pin'] == null) {
    return (
      ok: false,
      message: 'Export Sheets butuh bukti PIN Owner — buka mode Owner dulu.',
    );
  }
  try {
    final res = await SupabaseService.instance.client.functions.invoke(
      'export-sheets',
      body: {'shift_id': shiftId, 'outlet_id': outletId, ...proof},
    );
    return parseExportResponse(res.data);
  } on FunctionException catch (e) {
    // Edge Function mengembalikan 4xx/5xx dengan body JSON {ok, error}:
    // details membawa body itu — tampilkan pesannya apa adanya.
    // NAMA KELAS: `FunctionException` (tunggal) — inilah nama di
    // supabase_flutter 2.x (functions_client 2.x: status + details +
    // reasonPhrase). `FunctionsException`/`FunctionsApiException`
    // baru ada di supabase_functions 3.x — JANGAN "diperbaiki" ke
    // nama itu selama pubspec masih supabase_flutter ^2.9.0
    // (ketangkep CI v28: non_type_in_catch_clause + unused_import).
    final result = parseExportResponse(e.details);
    debugPrint('Export Sheets gagal (${e.status}): ${e.details}');
    return result;
  } catch (e) {
    debugPrint('Export Sheets gagal: $e');
    return (
      ok: false,
      message: 'Export Sheets gagal — periksa koneksi / Edge Function belum di-deploy.',
    );
  }
}
