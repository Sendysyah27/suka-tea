import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/qris/qris_service.dart';
import 'package:suka_tea/features/qris/qris_settings_service.dart';

/// Parse jawaban Edge Function QRIS (Batch C8.2 — QRIS GLOBAL,
/// plaintext) — level fungsi saja.
/// Jaringan asli TIDAK BISA di-test di CI (butuh Supabase + PIN
/// Owner), jadi yang di-test di sini: bentuk jawaban yang diterima /
/// ditolak parser. Semua payload pakai QrisService.sampleStaticPayload()
/// ("TOKO CONTOH", fiktif) — JANGAN pernah tulis payload asli di tes.
void main() {
  group('parseGetQrisResponse', () {
    test('ok + value plaintext 000201 -> (ok:true, value utuh, legacy:false)',
        () {
      final sample = QrisService.sampleStaticPayload();
      final result = parseGetQrisResponse({
        'ok': true,
        'set': true,
        'value': sample,
      });
      expect(result.ok, isTrue);
      expect(result.value, sample);
      expect(result.legacy, isFalse);
    });

    test('ok + set:false + value null -> (ok:true, value null)', () {
      final result = parseGetQrisResponse({
        'ok': true,
        'set': false,
        'value': null,
      });
      expect(result.ok, isTrue);
      expect(result.value, isNull);
      expect(result.legacy, isFalse);
    });

    test('ok:true tanpa field value -> (ok:true, value null)', () {
      final result = parseGetQrisResponse({'ok': true, 'set': false});
      expect(result.ok, isTrue);
      expect(result.value, isNull);
      expect(result.legacy, isFalse);
    });

    test('ok:false -> (ok:false, value null)', () {
      final result = parseGetQrisResponse({
        'ok': false,
        'error': 'Edge Function belum dikonfigurasi',
      });
      expect(result.ok, isFalse);
      expect(result.value, isNull);
      expect(result.legacy, isFalse);
    });

    test('bukan Map -> (ok:false, value null)', () {
      expect(parseGetQrisResponse(null).ok, isFalse);
      expect(parseGetQrisResponse('ok').ok, isFalse);
      expect(parseGetQrisResponse(42).ok, isFalse);
      expect(parseGetQrisResponse([true]).ok, isFalse);
    });

    test('ok:true tapi value ciphertext lama enc:v1: -> legacy:true', () {
      final result = parseGetQrisResponse({
        'ok': true,
        'set': true,
        'value': 'enc:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      });
      expect(result.ok, isTrue);
      expect(result.value, isNull);
      expect(result.legacy, isTrue);
    });

    test('ok:true tapi value string bukan 000201 -> ditolak', () {
      final result = parseGetQrisResponse({
        'ok': true,
        'set': true,
        'value': 'bukan-payload-qris',
      });
      expect(result.ok, isFalse);
      expect(result.value, isNull);
      expect(result.legacy, isFalse);
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
}
