import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/qris/qris_scan_logic.dart';
import 'package:suka_tea/features/qris/qris_service.dart';

/// Logika hasil scan QRIS — level fungsi saja. Kamera asli TIDAK BISA
/// di-test di CI (butuh kamera + izin perangkat), jadi yang di-test di
/// sini: hasil scan valid -> terisi + validasi lolos; hasil scan bukan
/// QRIS -> error; hasil kosong -> error "tidak terbaca".
void main() {
  group('processScannedPayload', () {
    test('hasil scan QRIS valid -> payload terisi, error null', () {
      final sample = QrisService.sampleStaticPayload();
      final result = processScannedPayload(sample);
      expect(result.payload, sample);
      expect(result.error, isNull);
    });

    test('hasil scan dengan spasi di ujung -> di-trim, tetap valid', () {
      final sample = QrisService.sampleStaticPayload();
      final result = processScannedPayload('  $sample\n');
      expect(result.payload, sample);
      expect(result.error, isNull);
    });

    test('hasil scan bukan QRIS -> error validasi', () {
      final result = processScannedPayload('HELLO');
      expect(result.payload, 'HELLO');
      expect(result.error, isNotNull);
    });

    test('hasil scan QRIS dengan CRC rusak -> error validasi', () {
      final sample = QrisService.sampleStaticPayload();
      // Rusak 1 karakter di tengah payload (bukan CRC-nya) supaya CRC
      // tidak cocok lagi.
      final broken = sample.replaceRange(10, 11, '9');
      final result = processScannedPayload(broken);
      expect(result.error, isNotNull);
    });

    test('hasil scan null -> error tidak terbaca', () {
      final result = processScannedPayload(null);
      expect(result.payload, isEmpty);
      expect(result.error, isNotNull);
    });

    test('hasil scan kosong / hanya spasi -> error tidak terbaca', () {
      expect(processScannedPayload('').error, isNotNull);
      expect(processScannedPayload('   ').error, isNotNull);
    });
  });
}
