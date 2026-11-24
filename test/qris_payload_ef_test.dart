import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/qris/qris_crypto.dart';
import 'package:suka_tea/features/qris/qris_service.dart';
import 'package:suka_tea/features/qris/qris_settings_service.dart';

/// Parse jawaban Edge Function QRIS (Batch C8) — level fungsi saja.
/// Jaringan asli TIDAK BISA di-test di CI (butuh Supabase + PIN
/// Owner), jadi yang di-test di sini: bentuk jawaban yang diterima /
/// ditolak parser. Semua payload pakai QrisService.sampleStaticPayload()
/// ("TOKO CONTOH", fiktif) — JANGAN pernah tulis payload asli di tes.
void main() {
  group('parseGetQrisResponse', () {
    test('ok + value enc:v1: -> (ok:true, value utuh)', () {
      final result = parseGetQrisResponse({
        'ok': true,
        'set': true,
        'value': 'enc:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      });
      expect(result.ok, isTrue);
      expect(result.value, 'enc:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAA=');
    });

    test('ok + set:false + value null -> (ok:true, value null)', () {
      final result = parseGetQrisResponse({
        'ok': true,
        'set': false,
        'value': null,
      });
      expect(result.ok, isTrue);
      expect(result.value, isNull);
    });

    test('ok:true tanpa field value -> (ok:true, value null)', () {
      final result = parseGetQrisResponse({'ok': true, 'set': false});
      expect(result.ok, isTrue);
      expect(result.value, isNull);
    });

    test('ok:false -> (ok:false, value null)', () {
      final result = parseGetQrisResponse({
        'ok': false,
        'error': 'outlet_id (UUID) wajib',
      });
      expect(result.ok, isFalse);
      expect(result.value, isNull);
    });

    test('bukan Map -> (ok:false, value null)', () {
      expect(parseGetQrisResponse(null).ok, isFalse);
      expect(parseGetQrisResponse('ok').ok, isFalse);
      expect(parseGetQrisResponse(42).ok, isFalse);
      expect(parseGetQrisResponse([true]).ok, isFalse);
    });

    test('ok:true tapi value PLAINTEXT -> ditolak (fail closed)', () {
      final sample = QrisService.sampleStaticPayload();
      final result = parseGetQrisResponse({
        'ok': true,
        'set': true,
        'value': sample,
      });
      expect(result.ok, isFalse);
      expect(result.value, isNull);
    });

    test('ok:true tapi value bukan string -> ditolak', () {
      final result = parseGetQrisResponse({
        'ok': true,
        'value': 123,
      });
      expect(result.ok, isFalse);
      expect(result.value, isNull);
    });
  });

  group('parseSetQrisResponse', () {
    test('ok:true -> true', () {
      expect(parseSetQrisResponse({'ok': true}), isTrue);
    });

    test('ok:false + reason/error -> false', () {
      expect(parseSetQrisResponse({'ok': false, 'reason': 'wrong'}), isFalse);
      expect(parseSetQrisResponse({'ok': false, 'error': 'boom'}), isFalse);
    });

    test('bukan Map / peta kosong -> false', () {
      expect(parseSetQrisResponse(null), isFalse);
      expect(parseSetQrisResponse('ok'), isFalse);
      expect(parseSetQrisResponse(42), isFalse);
      expect(parseSetQrisResponse({}), isFalse);
    });
  });

  group('round-trip enkripsi -> parse jawaban EF', () {
    test('ciphertext sample lolos parser + bisa dibuka kunci sendiri', () {
      final sample = QrisService.sampleStaticPayload();
      final key = QrisCrypto.generateKey();
      final encrypted = QrisCrypto.encrypt(sample, key);
      expect(encrypted.startsWith('enc:v1:'), isTrue);

      final parsed = parseGetQrisResponse({
        'ok': true,
        'set': true,
        'value': encrypted,
      });
      expect(parsed.ok, isTrue);
      expect(parsed.value, encrypted);
      expect(QrisCrypto.decrypt(parsed.value!, key), sample);
    });

    test('ciphertext tidak bisa dibuka kunci lain (kunci per-perangkat)', () {
      final sample = QrisService.sampleStaticPayload();
      final key = QrisCrypto.generateKey();
      final otherKey = QrisCrypto.generateKey();
      final encrypted = QrisCrypto.encrypt(sample, key);
      expect(QrisCrypto.decrypt(encrypted, otherKey), isNull);
    });
  });
}
