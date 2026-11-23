import 'qris_service.dart';

/// Hasil pemrosesan satu nilai hasil scan kamera (pure — bisa di-test
/// tanpa kamera, lihat test/qris_scan_test.dart). Nilai mentah hasil
/// scan TIDAK PERNAH di-log / ditampilkan di tempat lain: hanya
/// diteruskan ke field Pengaturan QRIS, lalu divalidasi seperti
/// tempelan manual.
class ScannedPayloadResult {
  const ScannedPayloadResult({required this.payload, required this.error});

  /// Payload ter-trim, siap diisi ke field (atau '' bila kosong).
  final String payload;

  /// null = payload QRIS valid, siap disimpan. Bila tidak null, ini
  /// pesan error validasi yang ditampilkan ke Owner (jangan simpan).
  final String? error;
}

/// Proses satu nilai hasil scan: trim, lalu jalankan validasi QRIS
/// yang sama dengan tempelan manual (QrisService.validationError).
/// - null/kosong -> error "tidak terbaca" (kamera sempat membaca
///   barcode kosong / bukan teks).
/// - bukan QRIS / CRC salah / mata uang bukan IDR -> error validasi.
/// - valid -> error null.
ScannedPayloadResult processScannedPayload(String? rawValue) {
  final payload = (rawValue ?? '').trim();
  if (payload.isEmpty) {
    return const ScannedPayloadResult(
      payload: '',
      error: 'Kode QR tidak terbaca — arahkan lagi ke kode QRIS.',
    );
  }
  final error = QrisService.validationError(payload);
  return ScannedPayloadResult(payload: payload, error: error);
}
